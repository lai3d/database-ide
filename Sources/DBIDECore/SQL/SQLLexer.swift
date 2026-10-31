import Foundation

public enum SQLTokenKind: Sendable, Equatable {
    case keyword, identifier, quotedIdentifier, string, number, comment, op, semicolon, parameter
}

public struct SQLToken: Sendable, Equatable {
    public var kind: SQLTokenKind
    /// UTF-16 range in the source text (NSRange-compatible).
    public var location: Int
    public var length: Int
    public var range: NSRange { NSRange(location: location, length: length) }
}

/// A forgiving SQL tokenizer working on UTF-16 code units so ranges map
/// directly onto NSTextView / NSString offsets.
public enum SQLLexer {
    public static func tokenize(_ text: String, dialect: SQLDialect = .postgres) -> [SQLToken] {
        tokenize(Array(text.utf16), dialect: dialect)
    }

    public static func tokenize(_ s: [UInt16], dialect: SQLDialect) -> [SQLToken] {
        var tokens: [SQLToken] = []
        var i = 0
        let n = s.count
        while i < n {
            let c = s[i]
            if isSpace(c) {
                i += 1
                continue
            }
            let start = i
            if let end = skipNonCode(s, i, dialect: dialect) {
                let kind: SQLTokenKind =
                    switch c {
                    case ch("'"), ch("$"), ch("E"), ch("e"), ch("N"), ch("X"), ch("x"), ch("B"), ch("b"): .string
                    case ch("\""), ch("`"), ch("["): .quotedIdentifier
                    default: .comment
                    }
                tokens.append(SQLToken(kind: kind, location: start, length: end - start))
                i = end
                continue
            }
            if isDigit(c) || (c == ch(".") && i + 1 < n && isDigit(s[i + 1])) {
                i += 1
                if c == ch("0"), i < n, s[i] == ch("x") || s[i] == ch("X") {
                    i += 1
                    while i < n, isHex(s[i]) { i += 1 }
                } else {
                    while i < n, isDigit(s[i]) || s[i] == ch(".") { i += 1 }
                    if i < n, s[i] == ch("e") || s[i] == ch("E") {
                        var j = i + 1
                        if j < n, s[j] == ch("+") || s[j] == ch("-") { j += 1 }
                        if j < n, isDigit(s[j]) {
                            i = j
                            while i < n, isDigit(s[i]) { i += 1 }
                        }
                    }
                }
                tokens.append(SQLToken(kind: .number, location: start, length: i - start))
                continue
            }
            if isIdentStart(c) {
                while i < n, isIdentPart(s[i]) { i += 1 }
                let raw = String(utf16CodeUnits: Array(s[start..<i]), count: i - start)
                let isKeyword = dialect == .mongodb ? SQLKeywords.mongo.contains(raw) : SQLKeywords.all.contains(raw.uppercased())
                let kind: SQLTokenKind = isKeyword ? .keyword : .identifier
                tokens.append(SQLToken(kind: kind, location: start, length: i - start))
                continue
            }
            if c == ch(";") {
                tokens.append(SQLToken(kind: .semicolon, location: i, length: 1))
                i += 1
                continue
            }
            // Bind parameters: ?, :name, @var, $1 (but not the `::` cast operator).
            let next: UInt16 = i + 1 < n ? s[i + 1] : 0
            let afterColon = i > 0 && s[i - 1] == ch(":")
            let isParam = dialect != .mongodb && (
                c == ch("?")
                || (c == ch(":") && !afterColon && isIdentStart(next))
                || (c == ch("@") && isIdentPart(next))
                || (c == ch("$") && isDigit(next)))
            if isParam {
                i += 1
                while i < n, isIdentPart(s[i]) { i += 1 }
                tokens.append(SQLToken(kind: .parameter, location: start, length: i - start))
                continue
            }
            i += 1
            tokens.append(SQLToken(kind: .op, location: start, length: 1))
        }
        return tokens
    }

    /// If position `i` starts a string literal, quoted identifier or comment,
    /// returns the index just past it (or the end of input if unterminated).
    static func skipNonCode(_ s: [UInt16], _ i: Int, dialect: SQLDialect) -> Int? {
        let n = s.count
        let c = s[i]
        let next: UInt16 = i + 1 < n ? s[i + 1] : 0
        if dialect == .mongodb {
            if c == ch("/") && next == ch("/") {
                var j = i
                while j < n, s[j] != 10 { j += 1 }
                return j
            }
            if c == ch("/") && next == ch("*") {
                var j = i + 2
                while j + 1 < n, !(s[j] == ch("*") && s[j + 1] == ch("/")) { j += 1 }
                return min(n, j + 2)
            }
            if c == ch("'") || c == ch("\"") || c == ch("`") { return quoted(s, i, quote: c, backslash: true) }
            return nil
        }

        // -- line comment, and # in MySQL
        if (c == ch("-") && next == ch("-")) || (c == ch("#") && dialect == .mysql) {
            var j = i
            while j < n, s[j] != 10 { j += 1 }
            return j
        }
        // /* block comment */ (nested in PostgreSQL)
        if c == ch("/") && next == ch("*") {
            var depth = 1
            var j = i + 2
            while j < n {
                if s[j] == ch("*"), j + 1 < n, s[j + 1] == ch("/") {
                    depth -= 1
                    j += 2
                    if depth == 0 { return j }
                } else if dialect == .postgres, s[j] == ch("/"), j + 1 < n, s[j + 1] == ch("*") {
                    depth += 1
                    j += 2
                } else {
                    j += 1
                }
            }
            return n
        }
        // Prefixed strings: E'..', N'..', X'..', B'..'
        if next == ch("'"), [ch("E"), ch("e"), ch("N"), ch("X"), ch("x"), ch("B"), ch("b")].contains(c),
            i == 0 || !isIdentPart(s[i - 1])
        {
            let backslash = dialect == .mysql || c == ch("E") || c == ch("e")
            return quoted(s, i + 1, quote: ch("'"), backslash: backslash)
        }
        if c == ch("'") { return quoted(s, i, quote: c, backslash: dialect == .mysql) }
        if c == ch("\"") { return quoted(s, i, quote: c, backslash: dialect == .mysql) }
        if c == ch("`"), dialect == .mysql || dialect == .sqlite { return quoted(s, i, quote: c, backslash: false) }
        if c == ch("["), dialect == .sqlite {
            var j = i + 1
            while j < n, s[j] != ch("]") { j += 1 }
            return min(n, j + 1)
        }
        // $tag$ ... $tag$ in PostgreSQL
        if c == ch("$"), dialect == .postgres, i == 0 || !isIdentPart(s[i - 1]) {
            var j = i + 1
            while j < n, s[j] != ch("$") {
                guard isIdentPart(s[j]), !isDigit(s[j]) || j > i + 1 else { return nil }
                j += 1
            }
            guard j < n else { return nil }
            let tag = Array(s[i...j])
            var k = j + 1
            while k + tag.count <= n {
                if s[k] == ch("$"), Array(s[k..<k + tag.count]) == tag { return k + tag.count }
                k += 1
            }
            return n
        }
        return nil
    }

    private static func quoted(_ s: [UInt16], _ i: Int, quote: UInt16, backslash: Bool) -> Int {
        var j = i + 1
        let n = s.count
        while j < n {
            if backslash, s[j] == ch("\\") {
                j += 2
                continue
            }
            if s[j] == quote {
                if j + 1 < n, s[j + 1] == quote {
                    j += 2
                    continue
                }
                return j + 1
            }
            j += 1
        }
        return n
    }

    /// First `count` keywords/identifiers of a statement, skipping comments ("CREATE TABLE").
    public static func leadingKeywords(_ sql: String, count: Int) -> String {
        let s = Array(sql.utf16)
        return tokenize(s, dialect: .postgres)
            .filter { $0.kind == .keyword || $0.kind == .identifier }
            .prefix(count)
            .map { String(utf16CodeUnits: Array(s[$0.location..<$0.location + $0.length]), count: $0.length) }
            .joined(separator: " ")
    }

    @inline(__always) static func ch(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }
    @inline(__always) static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) static func isHex(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
    }
    @inline(__always) static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
    }
    @inline(__always) static func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) || c == 36 }
}
