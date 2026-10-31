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
        if dialect == .mongodb { return isMongoReadOnly(sql) }
        if dialect == .redis {
            return sql.split(whereSeparator: \.isNewline).allSatisfy { line in
                let word = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
                return word.isEmpty || word.hasPrefix("#") || SQLKeywords.redisReadOnly.contains(word)
            }
        }
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

    static let mongoReads: Set<String> = [
        "find", "findOne", "countDocuments", "estimatedDocumentCount", "count", "distinct", "getIndexes", "stats",
        "getCollectionNames", "getCollectionInfos", "serverStatus", "hostInfo", "currentOp", "getUsers", "version", "getName",
    ]

    static func isMongoReadOnly(_ text: String) -> Bool {
        guard let st = try? MongoShellParser.parse(text) else { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch st {
        case .show, .use: return true
        case .database(let method, let args):
            if method == "runCommand" || method == "adminCommand" {
                let name = args.first?.document?.keys.first ?? args.first?.string ?? ""
                return ["ping", "buildInfo", "hello", "isMaster", "listDatabases", "listCollections", "dbStats", "collStats",
                        "serverStatus", "connectionStatus", "count", "find", "aggregate", "explain", "usersInfo"].contains(name)
                    && !(args.first?.document?["pipeline"]?.array?.contains { $0.document?["$out"] != nil || $0.document?["$merge"] != nil } ?? false)
            }
            return mongoReads.contains(method)
        case .collection(_, let method, let args, _):
            if method == "aggregate" {
                return !(args.first?.array?.contains { $0.document?["$out"] != nil || $0.document?["$merge"] != nil } ?? false)
            }
            return mongoReads.contains(method)
        }
    }
}
