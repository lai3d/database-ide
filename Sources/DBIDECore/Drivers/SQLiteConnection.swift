import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite via the system libsqlite3.
public final class SQLiteConnection: DatabaseConnection, CursorCapable, @unchecked Sendable {
    public let dialect = SQLDialect.sqlite
    public let serverVersion: String
    public let securityDescription: String? = nil
    public private(set) var inTransaction = false
    private var db: OpaquePointer?
    private let worker = SerialWorker(label: "dbide.sqlite")
    public let path: String

    /// Opens (creating if needed) the database file at `path`; use ":memory:" for in-memory.
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(rc)"
            sqlite3_close(handle)
            throw DatabaseError("Cannot open \(path): \(msg)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        sqlite3_extended_result_codes(handle, 1)
        serverVersion = "SQLite " + String(cString: sqlite3_libversion())
    }

    public static func open(path: String, readOnly: Bool = false) async throws -> SQLiteConnection {
        try SQLiteConnection(path: path, readOnly: readOnly)
    }

    // MARK: Cursor

    private var cursorStmt: OpaquePointer?
    private var cursorColumns = 0
    private var pendingRow: [SQLValue]?

    private func finalizeCursor() {
        if let c = cursorStmt { sqlite3_finalize(c) }
        cursorStmt = nil
        pendingRow = nil
    }

    /// Steps up to `n` rows, then peeks one more to know whether the cursor has more.
    private func stepRows(_ n: Int) throws -> (rows: [[SQLValue]], hasMore: Bool) {
        guard let stmt = cursorStmt else { return ([], false) }
        var rows: [[SQLValue]] = []
        if let p = pendingRow {
            rows.append(p)
            pendingRow = nil
        }
        while rows.count <= n {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE {
                finalizeCursor()
                return (rows, false)
            }
            guard rc == SQLITE_ROW else {
                let e = error(rc)
                finalizeCursor()
                throw e
            }
            let row = (0..<cursorColumns).map { value(stmt, Int32($0)) }
            if rows.count == n {
                pendingRow = row
                return (rows, true)
            }
            rows.append(row)
        }
        return (rows, true)
    }

    public func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        try await worker.run { [self] in
            finalizeCursor()
            defer { if let db { inTransaction = sqlite3_get_autocommit(db) == 0 } }
            return try executeSync(sql, maxRows: maxRows)
        }
    }

    private func error(_ rc: Int32, sql: String? = nil) -> DatabaseError {
        guard let db else { return DatabaseError("Connection closed") }
        let msg = String(cString: sqlite3_errmsg(db))
        var position: Int?
        if #available(macOS 13.0, *) {
            let off = sqlite3_error_offset(db)
            if off >= 0, let sql {
                // Byte offset → UTF-16 offset.
                let bytes = Array(sql.utf8.prefix(Int(off)))
                position = String(decoding: bytes, as: UTF8.self).utf16.count
            }
        }
        if rc == SQLITE_INTERRUPT { return DatabaseError("Query cancelled") }
        return DatabaseError(msg, code: "SQLITE_\(rc & 0xFF)", position: position)
    }

    private func executeSync(_ sql: String, maxRows: Int) throws -> QueryResult {
        guard let db else { throw DatabaseError("Connection closed") }
        let start = Date()
        var result = QueryResult(statement: sql)
        let totalBefore = sqlite3_total_changes64(db)

        // Run every statement in the text; the last one with a result set wins.
        try sql.withCString { base in
            var tail: UnsafePointer<CChar>? = base
            while let current = tail, current.pointee != 0 {
                var stmt: OpaquePointer?
                let rc = sqlite3_prepare_v2(db, current, -1, &stmt, &tail)
                guard rc == SQLITE_OK else { throw error(rc, sql: sql) }
                guard let stmt else { continue }  // whitespace / comment only
                defer { sqlite3_finalize(stmt) }

                let columnCount = Int(sqlite3_column_count(stmt))
                var columns: [ResultColumn] = []
                for i in 0..<columnCount {
                    let name = sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "?"
                    let type = sqlite3_column_decltype(stmt, Int32(i)).map { String(cString: $0) } ?? ""
                    columns.append(ResultColumn(name: name, typeName: type))
                }
                var rows: [[SQLValue]] = []
                var truncated = false
                while true {
                    let step = sqlite3_step(stmt)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW else { throw error(step, sql: sql) }
                    if rows.count >= maxRows {
                        truncated = true
                        break
                    }
                    rows.append((0..<columnCount).map { value(stmt, Int32($0)) })
                }
                if columnCount > 0 {
                    result.columns = columns
                    result.rows = rows
                    result.truncated = truncated
                }
                let text = sqlite3_sql(stmt).map { String(cString: $0) } ?? ""
                result.message = SQLLexer.leadingKeywords(text, count: 2).uppercased()
            }
        }
        if !result.hasResultSet {
            result.affectedRows = Int(sqlite3_total_changes64(db) - totalBefore)
        }
        inTransaction = sqlite3_get_autocommit(db) == 0
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    private func value(_ stmt: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
            return .blob(Data(bytes: p, count: n))
        default:
            guard let p = sqlite3_column_text(stmt, i) else { return .null }
            return .text(String(cString: p))
        }
    }

    public func cancel() {
        if let db { sqlite3_interrupt(db) }
    }

    public var hasOpenCursor: Bool { cursorStmt != nil }

    public func openCursor(_ sql: String, pageSize: Int) async throws -> QueryResult {
        try await worker.run { [self] in
            finalizeCursor()
            guard let db else { throw DatabaseError("Connection closed") }
            let start = Date()
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else { throw error(rc, sql: sql) }
            cursorStmt = stmt
            cursorColumns = Int(sqlite3_column_count(stmt))
            var result = QueryResult(statement: sql)
            result.columns = (0..<cursorColumns).map { i in
                ResultColumn(
                    name: sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "?",
                    typeName: sqlite3_column_decltype(stmt, Int32(i)).map { String(cString: $0) } ?? "")
            }
            let (rows, more) = try stepRows(pageSize)
            result.rows = rows
            result.truncated = more
            result.duration = Date().timeIntervalSince(start)
            return result
        }
    }

    public func fetchMore(_ count: Int) async throws -> (rows: [[SQLValue]], hasMore: Bool) {
        try await worker.run { [self] in try stepRows(count) }
    }

    public func closeCursor() async {
        _ = try? await worker.run { [self] in finalizeCursor() }
    }

    public func close() async {
        _ = try? await worker.run { [self] in
            finalizeCursor()
            sqlite3_close_v2(db)
            db = nil
        }
    }
}
