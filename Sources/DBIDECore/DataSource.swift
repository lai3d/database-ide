import Foundation

/// A saved connection definition ("data source" in DataGrip terms).
/// The password is not stored here; the app keeps it in the Keychain.
public struct DataSourceConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var dialect: SQLDialect
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    /// SQLite database file.
    public var filePath: String
    public var readOnly: Bool
    /// Hex color tag for the data source (optional).
    public var color: String?

    public init(
        id: UUID = UUID(), name: String = "", dialect: SQLDialect = .postgres, host: String = "localhost",
        port: Int? = nil, user: String = "", database: String = "", filePath: String = "",
        readOnly: Bool = false, color: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dialect = dialect
        self.host = host
        self.port = port ?? dialect.defaultPort
        self.user = user
        self.database = database
        self.filePath = filePath
        self.readOnly = readOnly
        self.color = color
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        switch dialect {
        case .sqlite: return (filePath as NSString).lastPathComponent
        default: return "\(database.isEmpty ? user : database)@\(host)"
        }
    }

    /// Short description shown under the name.
    public var subtitle: String {
        switch dialect {
        case .sqlite: return (filePath as NSString).abbreviatingWithTildeInPath
        default: return "\(dialect.displayName) · \(user)@\(host):\(port)/\(database)"
        }
    }

    /// Opens a new session for this data source.
    public func connect(password: String) async throws -> any DatabaseConnection {
        switch dialect {
        case .sqlite:
            let path = (filePath as NSString).expandingTildeInPath
            guard !path.isEmpty else { throw DatabaseError("No database file chosen") }
            return try await SQLiteConnection.open(path: path, readOnly: readOnly)
        case .postgres:
            let conn = try await PostgresConnection.connect(
                host: host, port: port, user: user, password: password, database: database)
            if readOnly { _ = try await conn.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY") }
            return conn
        case .mysql:
            let conn = try await MySQLConnection.connect(
                host: host, port: port, user: user, password: password, database: database)
            if readOnly { _ = try await conn.execute("SET SESSION TRANSACTION READ ONLY") }
            return conn
        }
    }
}
