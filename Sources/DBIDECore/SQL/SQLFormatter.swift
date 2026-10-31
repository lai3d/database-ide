import Foundation

/// Reformats SQL by re-flowing whitespace between tokens and upper-casing keywords.
/// Token text is never changed otherwise, so the result is semantically identical.
///
///     SELECT a,
///            b
///     FROM t
///     JOIN u ON u.id = t.u_id
///     WHERE x = 1
///       AND y IN (
///         SELECT ...
///     )
public enum SQLFormatter {
    public struct Options: Sendable {
        public var uppercaseKeywords = true
        public var indent = "    "
        public init(uppercaseKeywords: Bool = true, indent: String = "    ") {
            self.uppercaseKeywords = uppercaseKeywords
            self.indent = indent
        }
    }

    private static let clauseStarts: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT",
        "SET", "VALUES", "RETURNING", "INSERT", "UPDATE", "DELETE", "WITH", "WINDOW", "JOIN",
    ]
    private static let joinPrefixes: Set<String> = ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "OUTER"]

    public static func format(_ sql: String, dialect: SQLDialect, options: Options = Options()) -> String {
        // Scripts using client-side delimiters are left alone.
        if dialect == .mysql, sql.range(of: #"(?im)^\s*DELIMITER\s"#, options: .regularExpression) != nil { return sql }
        let ns = sql as NSString
        let tokens = SQLLexer.tokenize(sql, dialect: dialect)
        guard !tokens.isEmpty else { return sql }

        func raw(_ i: Int) -> String { ns.substring(with: tokens[i].range) }
        func upper(_ i: Int) -> String { i < tokens.count ? raw(i).uppercased() : "" }
        func isKeyword(_ i: Int, _ words: Set<String>) -> Bool {
            i < tokens.count && (tokens[i].kind == .keyword || tokens[i].kind == .identifier) && words.contains(upper(i))
        }
        func adjacent(_ a: Int, _ b: Int) -> Bool { NSMaxRange(tokens[a].range) == tokens[b].location }

        var out = ""
        var depth = 0  // subquery nesting
        /// For each open paren: does it hold a subquery (indented block)?
        var parens: [Bool] = []
        var clause = ""  // current clause keyword at this depth
        var clauseStack: [String] = []
        var betweenPending = false
        var lineStart = true

        func pad(_ extra: String = "") -> String { String(repeating: options.indent, count: depth) + extra }
        func newline(_ extra: String = "") {
            while out.hasSuffix(" ") { out.removeLast() }
            if !out.isEmpty { out += "\n" }
            out += pad(extra)
            lineStart = true
        }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            var text = raw(i)
            let u = text.uppercased()
            if t.kind == .keyword && options.uppercaseKeywords { text = u }

            // Statement separator.
            if t.kind == .semicolon {
                while out.hasSuffix(" ") || out.hasSuffix("\n") { out.removeLast() }
                out += ";\n\n"
                depth = 0
                parens = []
                clause = ""
                clauseStack = []
                lineStart = true
                i += 1
                continue
            }

            // Line breaks before clauses (only for real keywords at this nesting level).
            var breakBefore = false
            var extra = ""
            let inCall = parens.last == false  // inside f(...), not a subquery
            let prevUpper = i > 0 ? upper(i - 1) : ""
            if t.kind == .keyword && !inCall {
                if clauseStarts.contains(u) && !(u == "JOIN" && isKeyword(i - 1, joinPrefixes)) {
                    switch u {
                    case "WITH":
                        breakBefore = false  // statement start, or WITH TIME ZONE / WITH (...)
                    case "INSERT", "UPDATE", "DELETE":
                        breakBefore = prevUpper == ")"  // WITH cte AS (...) INSERT …; not FOR UPDATE / AFTER INSERT
                    case "SET":
                        breakBefore = clause == "UPDATE"
                    case "SELECT":
                        breakBefore = !["UNION", "ALL", "DISTINCT"].contains(prevUpper) || clause == "UNION"
                    default:
                        breakBefore = true
                    }
                    if breakBefore || clause.isEmpty { clause = u }
                } else if (u == "GROUP" || u == "ORDER") && upper(i + 1) == "BY" {
                    breakBefore = true
                    clause = u + " BY"
                } else if joinPrefixes.contains(u) && u != "OUTER"
                    && (isKeyword(i + 1, ["JOIN", "OUTER"]) || isKeyword(i + 2, ["JOIN"]))
                {
                    breakBefore = true
                    clause = "JOIN"
                } else if u == "AND" || u == "OR" {
                    if betweenPending && u == "AND" {
                        betweenPending = false
                    } else if ["WHERE", "HAVING", "ON"].contains(clause) {
                        breakBefore = true
                        extra = "  "
                    }
                } else if u == "BETWEEN" {
                    betweenPending = true
                } else if u == "ON" && clause == "JOIN" {
                    clause = "ON"
                }
            }
            if breakBefore && !(lineStart && out.hasSuffix(pad(extra))) {
                newline(extra)
            }

            // Spacing before this token.
            if !lineStart && i > 0 {
                let prev = raw(i - 1)
                let noSpace =
                    text == "," || text == ")" || text == "." || prev == "." || prev == "("
                    || (text == "(" && adjacent(i - 1, i) && tokens[i - 1].kind != .op)
                    || (adjacent(i - 1, i) && (tokens[i].kind == .op || tokens[i - 1].kind == .op) && prev != "," && text != "(")
                    || (text == "[" || prev == "[")
                if !noSpace && !out.hasSuffix(" ") && !out.hasSuffix("\n") { out += " " }
            }

            // Parentheses: subqueries become indented blocks.
            if text == "(" {
                let sub = isKeyword(i + 1, ["SELECT", "WITH", "VALUES"]) && tokens[i + 1].kind == .keyword
                parens.append(sub)
                out += "("
                lineStart = false
                if sub {
                    clauseStack.append(clause)
                    depth += 1
                    clause = ""
                    newline()
                }
                i += 1
                continue
            }
            if text == ")" {
                let sub = parens.popLast() ?? false
                if sub {
                    depth = max(0, depth - 1)
                    clause = clauseStack.popLast() ?? ""
                    newline()
                    out += ")"
                } else {
                    out += ")"
                }
                lineStart = false
                i += 1
                continue
            }

            out += text
            lineStart = false

            if text == "," && clause == "SELECT" && parens.last != false {
                newline(String(repeating: " ", count: 7))
            }
            if t.kind == .comment && text.hasPrefix("--") || (t.kind == .comment && text.hasPrefix("#")) {
                newline()
            }
            i += 1
        }
        while out.hasSuffix(" ") || out.hasSuffix("\n") { out.removeLast() }
        // Keep a trailing semicolon tidy and end with a newline like the input did.
        return out + (sql.hasSuffix("\n") ? "\n" : "")
    }
}
