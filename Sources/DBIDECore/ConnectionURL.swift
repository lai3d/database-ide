import Foundation

/// Parses connection strings people paste from elsewhere:
/// `postgres://user:pw@host:5432/db?sslmode=require`, `postgresql://…`, `mysql://…`,
/// `jdbc:postgresql://host/db?user=u&password=p`, `jdbc:mysql://…`, `sqlite:///path/to.db`,
/// or a plain path to a `.db` / `.sqlite` / `.sqlite3` file.
public enum ConnectionURL {
    public struct Parsed: Equatable, Sendable {
        public var config: DataSourceConfig
        public var password: String?
    }

    public static func parse(_ input: String) -> Parsed? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("/") || text.hasPrefix("~") {
            let ext = (text as NSString).pathExtension.lowercased()
            guard ["db", "sqlite", "sqlite3", "db3"].contains(ext) else { return nil }
            return sqlite(path: text)
        }
        if text.lowercased().hasPrefix("jdbc:") { text = String(text.dropFirst(5)) }
        guard let schemeEnd = text.range(of: "://") else { return nil }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()

        let dialect: SQLDialect
        switch scheme {
        case "postgres", "postgresql", "pgsql": dialect = .postgres
        case "mysql", "mariadb", "mysqlx": dialect = .mysql
        case "sqlite", "sqlite3", "file":
            let path = String(text[schemeEnd.upperBound...])
            return path.isEmpty ? nil : sqlite(path: path.removingPercentEncoding ?? path)
        default: return nil
        }

        // URLComponents can't handle unescaped special characters in passwords, so split by hand.
        var rest = String(text[schemeEnd.upperBound...])
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                query[key.lowercased()] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            }
            rest = String(rest[..<q])
        }
        var userInfo: String?
        if let at = rest.lastIndex(of: "@") {
            userInfo = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var database = ""
        if let slash = rest.firstIndex(of: "/") {
            database = String(rest[rest.index(after: slash)...]).removingPercentEncoding ?? ""
            rest = String(rest[..<slash])
        }
        // Host and port, with [ipv6] support; multi-host lists keep the first host.
        var hostPort = rest.split(separator: ",").first.map(String.init) ?? ""
        var port: Int?
        if hostPort.hasPrefix("[") , let close = hostPort.firstIndex(of: "]") {
            let after = hostPort[hostPort.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
            hostPort = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
        } else if let colon = hostPort.lastIndex(of: ":") {
            port = Int(hostPort[hostPort.index(after: colon)...])
            hostPort = String(hostPort[..<colon])
        }

        var user = ""
        var password: String?
        if let info = userInfo {
            if let colon = info.firstIndex(of: ":") {
                user = String(info[..<colon])
                password = String(info[info.index(after: colon)...])
            } else {
                user = info
            }
            user = user.removingPercentEncoding ?? user
            password = password.map { $0.removingPercentEncoding ?? $0 }
        }
        if let u = query["user"] ?? query["username"] { user = u }
        if let p = query["password"] { password = p }
        if let db = query["dbname"] ?? query["database"] { database = db }

        var config = DataSourceConfig(
            dialect: dialect, host: hostPort.isEmpty ? "localhost" : hostPort, port: port ?? dialect.defaultPort,
            user: user, database: database)
        if let mode = query["sslmode"] ?? query["ssl-mode"] {
            config.sslMode = sslMode(mode) ?? config.sslMode
        } else if let ssl = query["ssl"] ?? query["usessl"] ?? query["tls"] {
            config.sslMode = ["true", "1", "require", "required"].contains(ssl.lowercased()) ? .require : .disable
        }
        if let root = query["sslrootcert"] ?? query["ssl-ca"] { config.sslRootCert = root }
        return Parsed(config: config, password: password)
    }

    private static func sslMode(_ value: String) -> SSLMode? {
        switch value.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "disable", "disabled", "allow": .disable
        case "prefer", "preferred": .prefer
        case "require", "required": .require
        case "verify-ca": .verifyCA
        case "verify-full", "verify-identity": .verifyFull
        default: nil
        }
    }

    private static func sqlite(path: String) -> Parsed {
        var c = DataSourceConfig(dialect: .sqlite, host: "", port: 0, filePath: path)
        c.name = (path as NSString).lastPathComponent
        return Parsed(config: c, password: nil)
    }
}
