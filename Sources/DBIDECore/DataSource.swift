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
    public var ssh: SSHConfig
    /// Ask before running statements that modify data or schema (for production data sources).
    public var confirmWrites: Bool
    /// MongoDB: database holding the user's credentials (default "admin").
    public var authSource: String
    /// MongoDB: resolve `host` as a `mongodb+srv://` cluster name via DNS SRV.
    public var srv: Bool
    /// Explorer group ("" = top level).
    public var folder: String

    public var tlsOptions: TLSOptions {
        TLSOptions(mode: sslMode, rootCertificatePath: sslRootCert.isEmpty ? nil : sslRootCert)
    }

    public init(
        id: UUID = UUID(), name: String = "", dialect: SQLDialect = .postgres, host: String = "localhost",
        port: Int? = nil, user: String = "", database: String = "", filePath: String = "",
        readOnly: Bool = false, color: String? = nil, sslMode: SSLMode = .prefer, sslRootCert: String = "",
        ssh: SSHConfig = SSHConfig(), confirmWrites: Bool = false, authSource: String = "", srv: Bool = false, folder: String = ""
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
        self.ssh = ssh
        self.confirmWrites = confirmWrites
        self.authSource = authSource
        self.srv = srv
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, dialect, host, port, user, database, filePath, readOnly, color, sslMode, sslRootCert, ssh, confirmWrites, authSource, srv, folder
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
        ssh = try c.decodeIfPresent(SSHConfig.self, forKey: .ssh) ?? SSHConfig()
        confirmWrites = try c.decodeIfPresent(Bool.self, forKey: .confirmWrites) ?? false
        authSource = try c.decodeIfPresent(String.self, forKey: .authSource) ?? ""
        srv = try c.decodeIfPresent(Bool.self, forKey: .srv) ?? false
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
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
        default:
            let via = ssh.enabled ? " via ssh \(ssh.destination)" : ""
            return "\(dialect.displayName) · \(user)@\(host):\(port)/\(database)\(via)"
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
            let (h, p, tls) = try await endpoint()
            let conn = try await PostgresConnection.connect(
                host: h, port: p, user: user, password: password, database: database, tls: tls)
            if readOnly { _ = try await conn.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY") }
            return conn
        case .mysql:
            let (h, p, tls) = try await endpoint()
            let conn = try await MySQLConnection.connect(
                host: h, port: p, user: user, password: password, database: database, tls: tls)
            if readOnly { _ = try await conn.execute("SET SESSION TRANSACTION READ ONLY") }
            return conn
        case .mongodb:
            return try await MongoConnection.connect(config: self, password: password)
        case .clickhouse:
            let (h, p, tls) = try await endpoint()
            return try await ClickHouseConnection.connect(host: h, port: p, user: user, password: password, database: database, tls: tls)
        case .sqlserver:
            let (h, p, tls) = try await endpoint()
            return try await SQLServerConnection.connect(host: h, port: p, user: user, password: password, database: database, tls: tls)
        case .redis:
            let (h, p, tls) = try await endpoint()
            return try await RedisConnection.connect(
                host: h, port: p, user: user, password: password, database: Int(database.replacingOccurrences(of: "db", with: "")) ?? 0, tls: tls)
        }
    }

    /// Where to open the socket: the server itself, or the local end of an SSH tunnel.
    /// Through a tunnel, TLS still checks the certificate against the real host name.
    func endpoint() async throws -> (String, Int, TLSOptions) {
        guard ssh.enabled else { return (host, port, tlsOptions) }
        guard !ssh.host.isEmpty else { throw DatabaseError("SSH host is empty") }
        let ssh = ssh, host = host, port = port
        let local = try await SerialWorker(label: "dbide.ssh").run {
            try SSHTunnels.shared.localPort(ssh: ssh, remoteHost: host, remotePort: port)
        }
        var tls = tlsOptions
        tls.serverName = host
        return ("127.0.0.1", local, tls)
    }
}
