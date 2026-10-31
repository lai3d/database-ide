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
    public var sslMode: SSLMode
    /// Root CA (PEM) used for verify-ca / verify-full; empty = system trust store.
    public var sslRootCert: String

    public var tlsOptions: TLSOptions {
        TLSOptions(mode: sslMode, rootCertificatePath: sslRootCert.isEmpty ? nil : sslRootCert)
    }

    public init(
        id: UUID = UUID(), name: String = "", dialect: SQLDialect = .postgres, host: String = "localhost",
        port: Int? = nil, user: String = "", database: String = "", filePath: String = "",
        readOnly: Bool = false, color: String? = nil, sslMode: SSLMode = .prefer, sslRootCert: String = ""
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
        self.sslMode = sslMode
        self.sslRootCert = sslRootCert
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, dialect, host, port, user, database, filePath, readOnly, color, sslMode, sslRootCert
    }

    /// Tolerates fields added in later versions being absent from saved state.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        dialect = try c.decode(SQLDialect.self, forKey: .dialect)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? dialect.defaultPort
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color)
        sslMode = try c.decodeIfPresent(SSLMode.self, forKey: .sslMode) ?? .prefer
        sslRootCert = try c.decodeIfPresent(String.self, forKey: .sslRootCert) ?? ""
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
                host: host, port: port, user: user, password: password, database: database, tls: tlsOptions)
            if readOnly { _ = try await conn.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY") }
            return conn
        case .mysql:
            let conn = try await MySQLConnection.connect(
                host: host, port: port, user: user, password: password, database: database, tls: tlsOptions)
            if readOnly { _ = try await conn.execute("SET SESSION TRANSACTION READ ONLY") }
            return conn
        }
    }
}
