import Foundation

/// Rough read/write classification used to guard data sources marked
/// "confirm before modifying data". Errs on the side of "write".
public enum SQLClassifier {
    private static let readOnlyStarts: Set<String> = [
        "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "VALUES", "TABLE", "USE", "SET", "BEGIN", "START",
        "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "PRAGMA", "WITH", "FETCH", "LISTEN",
    ]
    private static let writeKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "TRUNCATE", "DROP", "ALTER", "CREATE", "GRANT", "REVOKE",
        "COPY", "CALL", "DO", "VACUUM", "REINDEX", "CLUSTER", "LOCK", "RENAME", "COMMENT", "LOAD", "IMPORT",
    ]

    public static func isReadOnly(_ sql: String, dialect: SQLDialect = .postgres) -> Bool {
        let ns = sql as NSString
        let words = SQLLexer.tokenize(sql, dialect: dialect)
            .filter { $0.kind == .keyword || $0.kind == .identifier }
            .map { ns.substring(with: $0.range).uppercased() }
        guard let first = words.first else { return true }
        guard readOnlyStarts.contains(first) else { return false }
        // `FOR UPDATE` / `FOR NO KEY UPDATE` are row locks, not writes.
        let writes = words.indices.contains { i in
            writeKeywords.contains(words[i]) && !(words[i] == "UPDATE" && i > 0 && ["FOR", "KEY"].contains(words[i - 1]))
        }
        switch first {
        case "EXPLAIN":
            // Plain EXPLAIN never executes; EXPLAIN ANALYZE does.
            let analyze = words.contains("ANALYZE") || words.contains("ANALYSE")
            return !(analyze && writes)
        case "WITH", "SELECT":
            // Data-modifying CTEs and SELECT … INTO new_table are writes.
            if writes { return false }
            if first == "SELECT", words.contains("INTO"), !(dialect == .mysql && words.contains("OUTFILE")) { return false }
            return true
        default:
            return true
        }
    }
}
