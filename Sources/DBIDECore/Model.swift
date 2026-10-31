import Foundation

/// A single cell value as returned by a driver.
public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var isNull: Bool { if case .null = self { true } else { false } }

    /// Text shown in the result grid (NULL is rendered separately by the UI).
    public var displayString: String {
        switch self {
        case .null: "<null>"
        case .integer(let v): String(v)
        case .real(let v): v.rounded() == v && abs(v) < 1e15 ? String(format: "%.1f", v) : String(v)
        case .text(let s): s
        case .blob(let d):
            d.count <= 64 ? "0x" + d.map { String(format: "%02X", $0) }.joined() : "<blob \(d.count) bytes>"
        }
    }

    /// Value used for copy / CSV export (full blob hex, empty string for NULL).
    public var exportString: String {
        switch self {
        case .null: ""
        case .blob(let d): "0x" + d.map { String(format: "%02X", $0) }.joined()
        default: displayString
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .integer, .real: true
        default: false
        }
    }

    /// Ordering used when sorting the result grid client-side. NULLs sort first.
    public static func sortsBefore(_ a: SQLValue, _ b: SQLValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return false
        case (.null, _): return true
        case (_, .null): return false
        case (.integer(let x), .integer(let y)): return x < y
        case (.integer(let x), .real(let y)): return Double(x) < y
        case (.real(let x), .integer(let y)): return x < Double(y)
        case (.real(let x), .real(let y)): return x < y
        default:
            return a.displayString.localizedStandardCompare(b.displayString) == .orderedAscending
        }
    }
}

public struct ResultColumn: Sendable, Hashable {
    public var name: String
    public var typeName: String
    public init(name: String, typeName: String) {
        self.name = name
        self.typeName = typeName
    }
}

/// The outcome of one executed statement.
public struct QueryResult: Sendable {
    public var statement: String
    public var columns: [ResultColumn]
    public var rows: [[SQLValue]]
    /// Rows changed by DML, when the server reports it.
    public var affectedRows: Int?
    /// Command tag / status text (e.g. "CREATE TABLE").
    public var message: String?
    /// True when more rows existed than were kept (see `maxRows`).
    public var truncated: Bool
    public var duration: TimeInterval
    /// Raw documents for MongoDB results (the grid shows them flattened).
    public var documents: [BSONDocument]?

    public var hasResultSet: Bool { !columns.isEmpty }

    public init(
        statement: String = "", columns: [ResultColumn] = [], rows: [[SQLValue]] = [],
        affectedRows: Int? = nil, message: String? = nil, truncated: Bool = false,
        duration: TimeInterval = 0, documents: [BSONDocument]? = nil
    ) {
        self.statement = statement
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.message = message
        self.truncated = truncated
        self.duration = duration
        self.documents = documents
    }

    /// One-line summary for the console log.
    public var summary: String {
        let ms = String(format: "%.0f ms", duration * 1000)
        if hasResultSet {
            let n = rows.count
            return "\(n)\(truncated ? "+" : "") row\(n == 1 ? "" : "s") retrieved in \(ms)"
        }
        if let a = affectedRows, a > 0 || message == nil {
            return "\(a) row\(a == 1 ? "" : "s") affected in \(ms)"
        }
        return "\(message ?? "completed") in \(ms)"
    }
}

public struct DatabaseError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var code: String?
    public var detail: String?
    /// UTF-16 offset into the statement, when the server reports one (PostgreSQL).
    public var position: Int?

    public init(_ message: String, code: String? = nil, detail: String? = nil, position: Int? = nil) {
        self.message = message
        self.code = code
        self.detail = detail
        self.position = position
    }

    public var errorDescription: String? {
        var s = code.map { "[\($0)] " } ?? ""
        s += message
        if let detail { s += "\n" + detail }
        return s
    }
}

public enum SQLDialect: String, Codable, Sendable, CaseIterable {
    case sqlite, postgres, mysql, mongodb, clickhouse, sqlserver, redis

    /// SQL databases (MongoDB and Redis use their own command syntax).
    public var isSQL: Bool { self != .mongodb && self != .redis }

    /// Whether multi-statement transactions are available (BEGIN / COMMIT / ROLLBACK).
    public var supportsTransactions: Bool { [.postgres, .mysql, .sqlite, .sqlserver].contains(self) }

    public var beginTransaction: String {
        switch self {
        case .mysql: "START TRANSACTION"
        case .sqlserver: "BEGIN TRANSACTION"
        default: "BEGIN"
        }
    }

    public var displayName: String {
        switch self {
        case .sqlite: "SQLite"
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .mongodb: "MongoDB"
        case .clickhouse: "ClickHouse"
        case .sqlserver: "SQL Server"
        case .redis: "Redis"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sqlite: 0
        case .postgres: 5432
        case .mysql: 3306
        case .mongodb: 27017
        case .clickhouse: 8123
        case .sqlserver: 1433
        case .redis: 6379
        }
    }

    /// Quotes an identifier for this dialect.
    public func quote(_ identifier: String) -> String {
        switch self {
        case .mongodb, .redis: identifier
        case .mysql, .clickhouse: "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        case .sqlserver: "[" + identifier.replacingOccurrences(of: "]", with: "]]") + "]"
        default: "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// Quotes a string literal for this dialect.
    public func literal(_ value: String) -> String {
        if self == .mongodb { return BSONFormatter.quote(value) }
        if self == .redis {
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var v = value.replacingOccurrences(of: "'", with: "''")
        if self == .mysql || self == .clickhouse { v = v.replacingOccurrences(of: "\\", with: "\\\\") }
        return (self == .sqlserver ? "N'" : "'") + v + "'"
    }

    public func qualified(schema: String?, name: String) -> String {
        if self == .mongodb || self == .redis { return name }
        guard let schema, !schema.isEmpty, !(self == .sqlite && schema == "main") else { return quote(name) }
        return quote(schema) + "." + quote(name)
    }
}

/// A live session against one data source. Implementations serialize work on
/// their own queue, so calls may come from any thread.
public protocol DatabaseConnection: AnyObject, Sendable {
    var dialect: SQLDialect { get }
    /// Server product/version string, for display.
    var serverVersion: String { get }
    /// TLS details when the session is encrypted, nil for plaintext / local files.
    var securityDescription: String? { get }
    /// Whether the session is inside an open transaction (as reported by the server after the last statement).
    var inTransaction: Bool { get }
    /// Executes a single statement. Result sets beyond `maxRows` are drained and dropped.
    func execute(_ sql: String, maxRows: Int) async throws -> QueryResult
    /// Best-effort cancel of the statement currently running. Safe from any thread.
    func cancel()
    func close() async
}

extension DatabaseConnection {
    public func execute(_ sql: String) async throws -> QueryResult {
        try await execute(sql, maxRows: Int.max)
    }

    /// Runs `sql` and returns the first column of every row as text.
    public func strings(_ sql: String) async throws -> [String] {
        try await execute(sql).rows.compactMap { $0.first.flatMap { $0.isNull ? nil : $0.displayString } }
    }
}

/// Runs blocking driver work on a private serial queue and bridges it to async.
final class SerialWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label) }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
