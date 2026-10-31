import Foundation

/// Client-side bind parameters in console statements: `:name`, `$1` (PostgreSQL),
/// and `?` (MySQL / SQLite; in PostgreSQL `?` is a jsonb operator). MySQL `@vars` are
/// real session variables and are left alone. Values are inserted as typed SQL
/// (write `'text'` with quotes), like DataGrip's parameter dialog.
public enum SQLParameters {
    public struct Occurrence: Sendable, Equatable {
        public var name: String
        public var range: NSRange
    }

    public static func occurrences(in sql: String, dialect: SQLDialect) -> [Occurrence] {
        let ns = sql as NSString
        var positional = 0
        return SQLLexer.tokenize(sql, dialect: dialect).compactMap { t -> Occurrence? in
            guard t.kind == .parameter else { return nil }
            let text = ns.substring(with: t.range)
            switch text.first {
            case "@": return nil
            case "?":
                guard dialect != .postgres else { return nil }
                positional += 1
                return Occurrence(name: "?\(positional)", range: t.range)
            default:
                return Occurrence(name: text, range: t.range)
            }
        }
    }

    /// Distinct parameter names in order of first appearance.
    public static func names(in sql: String, dialect: SQLDialect) -> [String] {
        var seen = Set<String>()
        return occurrences(in: sql, dialect: dialect).map(\.name).filter { seen.insert($0).inserted }
    }

    public static func substitute(_ sql: String, values: [String: String], dialect: SQLDialect) -> String {
        let ns = NSMutableString(string: sql)
        for occ in occurrences(in: sql, dialect: dialect).reversed() {
            if let v = values[occ.name] { ns.replaceCharacters(in: occ.range, with: v) }
        }
        return ns as String
    }
}
