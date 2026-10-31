import Foundation

public struct SQLStatement: Sendable, Equatable {
    /// Statement text without the trailing delimiter, trimmed.
    public var text: String
    /// UTF-16 range of `text` within the script.
    public var range: NSRange
}

/// Splits a script into statements the way a console does: on `;` outside of
/// strings / comments / dollar quotes, honoring BEGIN…END bodies of triggers
/// and MySQL `DELIMITER` lines.
public enum SQLSplitter {
    public static func split(_ script: String, dialect: SQLDialect) -> [SQLStatement] {
        let s = Array(script.utf16)
        let n = s.count
        var statements: [SQLStatement] = []
        var delimiter: [UInt16] = [SQLLexer.ch(";")]
        var stmtStart = 0
        var i = 0
        var lineStart = true

        // Block tracking for CREATE TRIGGER / PROCEDURE / FUNCTION bodies.
        var depth = 0
        var wordsInStatement: [String] = []
        var inBodyStatement = false

        func emit(_ end: Int) {
            if let st = makeStatement(s, stmtStart, end) { statements.append(st) }
            wordsInStatement = []
            inBodyStatement = false
            depth = 0
        }

        while i < n {
            let c = s[i]
            // MySQL DELIMITER directive (must start a line).
            if lineStart, dialect == .mysql {
                var j = i
                while j < n, s[j] == 32 || s[j] == 9 { j += 1 }
                if matchesWord(s, j, "DELIMITER") {
                    var k = j + 9
                    while k < n, s[k] == 32 || s[k] == 9 { k += 1 }
                    let delimStart = k
                    while k < n, !SQLLexer.isSpace(s[k]) { k += 1 }
                    if k > delimStart {
                        emit(j)
                        delimiter = Array(s[delimStart..<k])
                        while k < n, s[k] != 10 { k += 1 }
                        i = k
                        stmtStart = k
                        continue
                    }
                }
            }
            lineStart = c == 10
            if SQLLexer.isSpace(c) {
                i += 1
                continue
            }
            if let end = SQLLexer.skipNonCode(s, i, dialect: dialect) {
                i = end
                continue
            }
            if SQLLexer.isIdentStart(c) {
                let start = i
                while i < n, SQLLexer.isIdentPart(s[i]) {
                    // A custom delimiter such as `$$` may follow a word directly (`END$$`).
                    if s[i] == delimiter[0], i + delimiter.count <= n, Array(s[i..<i + delimiter.count]) == delimiter {
                        break
                    }
                    i += 1
                }
                let word = String(utf16CodeUnits: Array(s[start..<i]), count: i - start).uppercased()
                if wordsInStatement.count < 6 {
                    wordsInStatement.append(word)
                    if wordsInStatement.first == "CREATE",
                        ["TRIGGER", "PROCEDURE", "FUNCTION", "EVENT"].contains(word),
                        dialect != .postgres
                    {
                        inBodyStatement = true
                    }
                }
                if inBodyStatement {
                    if word == "BEGIN" || word == "CASE" { depth += 1 }
                    if word == "END", depth > 0 { depth -= 1 }
                }
                continue
            }
            if depth == 0, c == delimiter[0], i + delimiter.count <= n,
                Array(s[i..<i + delimiter.count]) == delimiter
            {
                emit(i)
                i += delimiter.count
                stmtStart = i
                continue
            }
            i += 1
        }
        emit(n)
        return statements
    }

    /// The statement to run for a caret at UTF-16 `offset`: the one containing it,
    /// otherwise the closest one ending before it on the same or previous lines.
    public static func statement(at offset: Int, in script: String, dialect: SQLDialect) -> SQLStatement? {
        let all = split(script, dialect: dialect)
        if let hit = all.first(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }) {
            return hit
        }
        if let before = all.last(where: { NSMaxRange($0.range) <= offset }) {
            // Only if nothing but whitespace/`;` separates the caret from it.
            let ns = script as NSString
            let gap = ns.substring(with: NSRange(location: NSMaxRange(before.range), length: offset - NSMaxRange(before.range)))
            if gap.trimmingCharacters(in: CharacterSet(charactersIn: "; \t\r")).isEmpty { return before }
        }
        return all.first(where: { $0.range.location >= offset }).flatMap { st in
            let ns = script as NSString
            let gap = ns.substring(with: NSRange(location: offset, length: st.range.location - offset))
            return gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? st : nil
        }
    }

    private static func makeStatement(_ s: [UInt16], _ start: Int, _ end: Int) -> SQLStatement? {
        var a = start
        var b = end
        while a < b, SQLLexer.isSpace(s[a]) { a += 1 }
        while b > a, SQLLexer.isSpace(s[b - 1]) { b -= 1 }
        guard a < b else { return nil }
        let text = String(utf16CodeUnits: Array(s[a..<b]), count: b - a)
        // Skip pieces that are only comments.
        let hasCode = SQLLexer.tokenize(text).contains { $0.kind != .comment }
        guard hasCode else { return nil }
        return SQLStatement(text: text, range: NSRange(location: a, length: b - a))
    }

    private static func matchesWord(_ s: [UInt16], _ i: Int, _ word: String) -> Bool {
        let w = Array(word.utf16)
        guard i + w.count <= s.count else { return false }
        for (k, c) in w.enumerated() where s[i + k] | 0x20 != c | 0x20 { return false }
        return i + w.count == s.count || !SQLLexer.isIdentPart(s[i + w.count])
    }
}
