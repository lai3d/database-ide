import Foundation
import Security

/// ClickHouse over its HTTP interface (port 8123, or 8443 with TLS), one server session per connection.
public final class ClickHouseConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect = SQLDialect.clickhouse
    public private(set) var serverVersion = "ClickHouse"
    public private(set) var securityDescription: String?
    public let inTransaction = false
    /// Current database (`USE` changes it).
    public private(set) var database: String

    private let baseURL: URL
    private let user: String, password: String
    private let sessionID = UUID().uuidString
    private let urlSession: URLSession
    private let lock = NSLock()
    private var runningQueryID: String?

    public static func connect(
        host: String, port: Int = 8123, user: String, password: String, database: String, tls: TLSOptions = .disabled
    ) async throws -> ClickHouseConnection {
        let c = try ClickHouseConnection(host: host, port: port, user: user, password: password, database: database, tls: tls)
        c.serverVersion = "ClickHouse " + (try await c.strings("SELECT version()").first ?? "")
        if c.database.isEmpty { c.database = try await c.strings("SELECT currentDatabase()").first ?? "default" }
        return c
    }

    private init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        let useTLS = tls.mode.requiresTLS
        var comps = URLComponents()
        comps.scheme = useTLS ? "https" : "http"
        comps.host = host
        comps.port = port
        comps.path = "/"
        guard let url = comps.url else { throw DatabaseError("Invalid ClickHouse address \(host):\(port)") }
        baseURL = url
        self.user = user.isEmpty ? "default" : user
        self.password = password
        self.database = database
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 24 * 3600
        config.httpMaximumConnectionsPerHost = 2
        urlSession = URLSession(configuration: config, delegate: TrustDelegate(options: tls, host: tls.serverName ?? host), delegateQueue: nil)
        if useTLS { securityDescription = "HTTPS" }
    }

    deinit { urlSession.invalidateAndCancel() }

    // MARK: HTTP

    private func request(_ sql: String, settings: [String: String] = [:], session: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "default_format", value: "JSONCompact"),
            URLQueryItem(name: "output_format_json_quote_64bit_integers", value: "0"),
            URLQueryItem(name: "output_format_json_quote_denormals", value: "1"),
        ]
        if !database.isEmpty { items.append(URLQueryItem(name: "database", value: database)) }
        if session {
            items.append(URLQueryItem(name: "session_id", value: sessionID))
            items.append(URLQueryItem(name: "session_timeout", value: "3600"))
        }
        for (k, v) in settings { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.httpBody = Data(sql.utf8)
        req.setValue(user, forHTTPHeaderField: "X-ClickHouse-User")
        if !password.isEmpty { req.setValue(password, forHTTPHeaderField: "X-ClickHouse-Key") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw DatabaseError("ClickHouse request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw DatabaseError("Invalid ClickHouse response") }
        if http.statusCode != 200 {
            throw Self.parseError(Self.exceptionText(data) ?? String(decoding: data, as: UTF8.self))
        }
        // Errors after streaming started arrive inside the JSON body.
        if let text = Self.exceptionText(data) { throw Self.parseError(text) }
        return (data, http)
    }

    static func exceptionText(_ data: Data) -> String? {
        guard data.first == UInt8(ascii: "{"), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["exception"] as? String
    }

    /// "Code: 62. DB::Exception: Syntax error: … (SYNTAX_ERROR) (version …)"
    static func parseError(_ text: String) -> DatabaseError {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var code: String?
        if let r = message.range(of: #"^Code: (\d+)\. "#, options: .regularExpression) {
            code = String(message[r].dropFirst(6).dropLast(2))
            message = String(message[r.upperBound...])
        }
        if message.hasPrefix("DB::Exception: ") { message = String(message.dropFirst(15)) }
        if let v = message.range(of: " (version ", options: .backwards) { message = String(message[..<v.lowerBound]) }
        if let n = message.range(of: #" \(([A-Z_]+)\)$"#, options: .regularExpression) {
            let name = String(message[n].dropFirst(2).dropLast())
            code = code.map { "\($0) \(name)" } ?? name
            message = String(message[..<n.lowerBound])
        }
        var position: Int?
        if let p = message.range(of: #"failed at position (\d+)"#, options: .regularExpression),
            let n = Int(message[p].split(separator: " ").last ?? "")
        {
            position = n - 1
        }
        return DatabaseError(message, code: code, position: position)
    }

    // MARK: DatabaseConnection

    public func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        let start = Date()
        let queryID = UUID().uuidString
        setRunning(queryID)
        defer { setRunning(nil) }
        var settings = ["query_id": queryID]
        if maxRows < Int.max {
            settings["max_result_rows"] = String(maxRows + 1)
            settings["result_overflow_mode"] = "break"
        }
        let (data, http) = try await request(sql, settings: settings)
        var result = QueryResult(statement: sql)
        if let first = data.first, first == UInt8(ascii: "{"),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let meta = json["meta"] as? [[String: Any]], let rows = json["data"] as? [[Any]]
        {
            result.columns = meta.map { ResultColumn(name: $0["name"] as? String ?? "?", typeName: $0["type"] as? String ?? "") }
            let types = result.columns.map(\.typeName)
            result.rows = rows.prefix(maxRows).map { row in row.enumerated().map { Self.value($0.element, type: $0.offset < types.count ? types[$0.offset] : "") } }
            result.truncated = rows.count > maxRows || (json["rows_before_limit_at_least"] as? Int).map { $0 > rows.count } == true
        } else if !data.isEmpty {
            // Explicit FORMAT clauses return text: one row per line.
            let text = String(decoding: data, as: UTF8.self)
            result.columns = [ResultColumn(name: "result", typeName: "String")]
            result.rows = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0).map { [.text(String($0))] }
        }
        if !result.hasResultSet {
            if let summary = http.value(forHTTPHeaderField: "X-ClickHouse-Summary"),
                let s = try? JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any],
                let written = (s["written_rows"] as? String).flatMap(Int.init) ?? (s["written_rows"] as? Int), written > 0
            {
                result.affectedRows = written
            }
            result.message = SQLLexer.leadingKeywords(sql, count: 2).uppercased()
            if let target = Self.useTarget(sql) { database = target }
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    static func useTarget(_ sql: String) -> String? {
        let parts = sql.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0].uppercased() == "USE" else { return nil }
        return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "`\";"))
    }

    static func value(_ v: Any, type: String) -> SQLValue {
        switch v {
        case is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .text(n.boolValue ? "true" : "false") }
            if type.contains("Float") || type.contains("Decimal") { return .real(n.doubleValue) }
            if CFNumberIsFloatType(n) { return .real(n.doubleValue) }
            return .integer(n.int64Value)
        case let s as String:
            return .text(s)
        default:
            if let data = try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes, .fragmentsAllowed]) {
                return .text(String(decoding: data, as: UTF8.self))
            }
            return .text(String(describing: v))
        }
    }

    private func setRunning(_ id: String?) {
        lock.lock()
        runningQueryID = id
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        let id = runningQueryID
        lock.unlock()
        guard let id else { return }
        Task { _ = try? await request("KILL QUERY WHERE query_id = \(dialect.literal(id)) SYNC", session: false) }
    }

    public func close() async {
        urlSession.invalidateAndCancel()
    }
}

/// Server-trust handling for HTTPS connections, honoring the SSL modes.
final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let options: TLSOptions
    let host: String
    init(options: TLSOptions, host: String) {
        self.options = options
        self.host = host
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else { return completionHandler(.performDefaultHandling, nil) }
        switch options.mode {
        case .verifyCA, .verifyFull:
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, options.mode == .verifyFull ? host as CFString : nil))
            if let path = options.rootCertificatePath, !path.isEmpty,
                let anchors = try? TLSStream.loadCertificates((path as NSString).expandingTildeInPath)
            {
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            }
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        default:
            completionHandler(.useCredential, URLCredential(trust: trust))  // encrypted, not verified
        }
    }
}
