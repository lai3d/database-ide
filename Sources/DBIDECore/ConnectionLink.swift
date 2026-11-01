import Foundation

/// `dbide://connect?url=<connection URL>&name=<display name>` — how other apps (PHPIDE, launchers)
/// hand DBIDE a connection. `url` is anything `ConnectionURL` understands, percent-encoded.
public enum ConnectionLink {
    public struct Request: Equatable, Sendable {
        public var parsed: ConnectionURL.Parsed
        /// Suggested name for a new data source.
        public var name: String?
    }

    public static let scheme = "dbide"

    public static func parse(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (components.host ?? "").lowercased() == "connect" || components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "connect"
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name.lowercased() == key }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let raw = value("url"), let parsed = ConnectionURL.parse(raw) else { return nil }
        var request = Request(parsed: parsed, name: value("name"))
        if let name = request.name { request.parsed.config.name = name }
        return request
    }

    /// Builds a link (the inverse of `parse`), for tests and other apps.
    public static func make(url: String, name: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "connect"
        components.queryItems = [URLQueryItem(name: "url", value: url)] + (name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        // `+` and `&` inside the connection URL must not read as separators.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// The saved data source this request points at: same engine and endpoint (host, port,
    /// database, user — or file for SQLite). Names, TLS and SSH settings are not compared.
    public static func match(_ request: Request, in configs: [DataSourceConfig]) -> DataSourceConfig? {
        let c = request.parsed.config
        return configs.first { s in
            guard s.dialect == c.dialect else { return false }
            if c.dialect == .sqlite {
                return URL(fileURLWithPath: (s.filePath as NSString).expandingTildeInPath).standardizedFileURL
                    == URL(fileURLWithPath: (c.filePath as NSString).expandingTildeInPath).standardizedFileURL
            }
            return host(s.host) == host(c.host) && s.port == c.port
                && s.database == c.database && (c.user.isEmpty || s.user == c.user)
        }
    }

    /// `localhost`, `127.0.0.1` and `::1` are the same machine.
    private static func host(_ name: String) -> String {
        let lower = name.lowercased()
        return ["localhost", "127.0.0.1", "::1", ""].contains(lower) ? "localhost" : lower
    }
}
