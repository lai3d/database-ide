import Foundation

/// Pending changes made in the table data editor, turned into DML and applied
/// in one transaction (DataGrip's "Submit").
public struct TableEdits: Sendable, Equatable {
    /// Changed cells of existing rows: row → column → new value.
    public var updates: [Int: [Int: SQLValue]] = [:]
    public var deletedRows: Set<Int> = []
    public var insertedRows: [[SQLValue]] = []

    public init() {}

    public var isEmpty: Bool { updates.isEmpty && deletedRows.isEmpty && insertedRows.isEmpty }

    public mutating func set(_ value: SQLValue, row: Int, column: Int, original: SQLValue) {
        if value == original {
            updates[row]?[column] = nil
            if updates[row]?.isEmpty == true { updates[row] = nil }
        } else {
            updates[row, default: [:]][column] = value
        }
    }

    /// DML for the pending changes, in execution order: deletes, updates, inserts.
    /// Existing rows are identified by `primaryKey` using their original values.
    public func statements(
        table: TableInfo, dialect: SQLDialect, columns: [ResultColumn], rows: [[SQLValue]], primaryKey: [String],
        documents: [BSONDocument]? = nil
    ) throws -> [String] {
        if dialect == .mongodb { return try mongoStatements(table: table, columns: columns, documents: documents ?? []) }
        let qt = dialect.qualified(schema: table.schema, name: table.name)
        let names = columns.map(\.name)
        func lit(_ v: SQLValue) -> String { ResultExport.sqlLiteral(v, dialect: dialect) }
        func whereClause(_ row: Int) throws -> String {
            guard !primaryKey.isEmpty else { throw DatabaseError("Table \(table.name) has no primary key") }
            return try primaryKey.map { pk in
                guard let i = names.firstIndex(of: pk) else {
                    throw DatabaseError("Primary key column \(pk) is not in the result")
                }
                let v = rows[row][i]
                return v.isNull ? "\(dialect.quote(pk)) IS NULL" : "\(dialect.quote(pk)) = \(lit(v))"
            }.joined(separator: " AND ")
        }
        var out: [String] = []
        for row in deletedRows.sorted() {
            out.append("DELETE FROM \(qt) WHERE \(try whereClause(row))")
        }
        for (row, cols) in updates.sorted(by: { $0.key < $1.key }) where !deletedRows.contains(row) {
            let sets = cols.sorted { $0.key < $1.key }.map { "\(dialect.quote(names[$0.key])) = \(lit($0.value))" }
            out.append("UPDATE \(qt) SET \(sets.joined(separator: ", ")) WHERE \(try whereClause(row))")
        }
        for row in insertedRows {
            let pairs = zip(names, row).filter { !$0.1.isNull }
            if pairs.isEmpty {
                out.append(dialect == .mysql ? "INSERT INTO \(qt) () VALUES ()" : "INSERT INTO \(qt) DEFAULT VALUES")
            } else {
                let cols = pairs.map { dialect.quote($0.0) }.joined(separator: ", ")
                let vals = pairs.map { lit($0.1) }.joined(separator: ", ")
                out.append("INSERT INTO \(qt) (\(cols)) VALUES (\(vals))")
            }
        }
        return out
    }

    /// MongoDB: updateOne / deleteOne by _id (with its original BSON value), insertOne for new rows.
    func mongoStatements(table: TableInfo, columns: [ResultColumn], documents: [BSONDocument]) throws -> [String] {
        let coll = "db.getCollection(\(BSONFormatter.quote(table.name)))"
        let names = columns.map(\.name)
        func idFilter(_ row: Int) throws -> String {
            guard row < documents.count, let id = documents[row]["_id"] else { throw DatabaseError("Document has no _id") }
            return BSONValue.document(["_id": id]).shellString
        }
        var out: [String] = []
        for row in deletedRows.sorted() { out.append("\(coll).deleteOne(\(try idFilter(row)))") }
        for (row, cols) in updates.sorted(by: { $0.key < $1.key }) where !deletedRows.contains(row) {
            var set = BSONDocument()
            for (c, v) in cols.sorted(by: { $0.key < $1.key }) where names[c] != "_id" {
                let original = row < documents.count ? documents[row][names[c]] : nil
                if v.isNull && original == nil { continue }
                set[names[c]] = MongoResults.bson(v, like: original)
            }
            if set.isEmpty { continue }
            out.append("\(coll).updateOne(\(try idFilter(row)), { $set: \(BSONValue.document(set).shellString) })")
        }
        for row in insertedRows {
            let doc = BSONDocument(zip(names, row).filter { !$0.1.isNull }.map { ($0.0, MongoResults.bson($0.1, like: nil)) })
            out.append("\(coll).insertOne(\(BSONValue.document(doc).shellString))")
        }
        return out
    }

    /// Runs `statements` in a transaction; every statement must change exactly one row,
    /// otherwise everything is rolled back.
    public static func apply(_ statements: [String], on connection: any DatabaseConnection) async throws {
        guard !statements.isEmpty else { return }
        if !connection.dialect.supportsTransactions {  // MongoDB standalone, ClickHouse, Redis
            for sql in statements {
                let r = try await connection.execute(sql)
                if let n = r.affectedRows, n != 1 { throw DatabaseError("Expected to change 1 document but changed \(n).\n\(sql)") }
            }
            return
        }
        _ = try await connection.execute(connection.dialect.beginTransaction)
        do {
            for sql in statements {
                let r = try await connection.execute(sql)
                if let n = r.affectedRows, n != 1 {
                    throw DatabaseError("Expected to change 1 row but changed \(n) — rolled back.\n\(sql)")
                }
            }
            _ = try await connection.execute("COMMIT")
        } catch {
            _ = try? await connection.execute("ROLLBACK")
            throw error
        }
    }
}
