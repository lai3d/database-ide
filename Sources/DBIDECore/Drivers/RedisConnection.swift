import Foundation

/// A RESP2 / RESP3 reply.
public indirect enum RedisValue: Sendable, Equatable {
    case string(Data)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([RedisValue])
    case set([RedisValue])
    case map([(RedisValue, RedisValue)])
    case error(String)

    public static func == (a: RedisValue, b: RedisValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): x == y
        case (.integer(let x), .integer(let y)): x == y
        case (.double(let x), .double(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        case (.array(let x), .array(let y)), (.set(let x), .set(let y)): x == y
        case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.error(let x), .error(let y)): x == y
        default: false
        }
    }

    public var text: String? {
        switch self {
        case .string(let d): String(data: d, encoding: .utf8)
        case .integer(let i): String(i)
        case .double(let d): String(d)
        default: nil
        }
    }

    /// redis-cli-like one-line rendering.
    public var display: String {
        switch self {
        case .string(let d): String(data: d, encoding: .utf8).map { "\"\($0)\"" } ?? "<\(d.count) bytes>"
        case .integer(let i): "(integer) \(i)"
        case .double(let d): "(double) \(d)"
        case .bool(let b): b ? "(true)" : "(false)"
        case .null: "(nil)"
        case .array(let a), .set(let a): "[" + a.map(\.display).joined(separator: ", ") + "]"
        case .map(let m): "{" + m.map { "\($0.0.display): \($0.1.display)" }.joined(separator: ", ") + "}"
        case .error(let e): "(error) \(e)"
        }
    }

    var cell: SQLValue {
        switch self {
        case .string(let d): String(data: d, encoding: .utf8).map(SQLValue.text) ?? .blob(d)
        case .integer(let i): .integer(i)
        case .double(let d): .real(d)
        case .bool(let b): .text(b ? "true" : "false")
        case .null: .null
        default: .text(display)
        }
    }
}

/// Redis (and Valkey / KeyDB) over RESP3, falling back to RESP2 for older servers.
public final class RedisConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect = SQLDialect.redis
    public private(set) var serverVersion = "Redis"
    public private(set) var securityDescription: String?
    public let inTransaction = false
    public private(set) var currentDB = 0
    private var stream: any ByteStream
    private let worker = SerialWorker(label: "dbide.redis")
    private var clientID: Int64?
    private var resp3 = true
    let host: String, port: Int, user: String, password: String, tls: TLSOptions

    public static func connect(
        host: String, port: Int = 6379, user: String, password: String, database: Int = 0, tls: TLSOptions = .disabled
    ) async throws -> RedisConnection {
        try await SerialWorker(label: "dbide.redis.connect").run {
            try RedisConnection(host: host, port: port, user: user, password: password, database: database, tls: tls)
        }
    }

    private init(host: String, port: Int, user: String, password: String, database: Int, tls: TLSOptions) throws {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.tls = tls
        if tls.mode.requiresTLS {
            let t = try NWTLSStream(host: host, port: port, options: tls)
            stream = t
            securityDescription = t.negotiatedDescription
        } else {
            stream = try TCPSocket(host: host, port: port)
        }
        do {
            try handshake(database: database)
        } catch {
            stream.close()
            throw error
        }
    }

    private func handshake(database: Int) throws {
        var hello = ["HELLO", "3", "SETNAME", "DBIDE"]
        if !password.isEmpty { hello += ["AUTH", user.isEmpty ? "default" : user, password] }
        let reply = try commandSync(hello.map { Data($0.utf8) })
        if case .error(let e) = reply {
            if e.hasPrefix("ERR unknown command") || e.hasPrefix("NOPROTO") {
                resp3 = false
                if !password.isEmpty {
                    let auth = user.isEmpty ? ["AUTH", password] : ["AUTH", user, password]
                    if case .error(let e) = try commandSync(auth.map { Data($0.utf8) }) { throw DatabaseError(e) }
                }
            } else {
                throw DatabaseError(e)
            }
        } else if case .map(let pairs) = reply {
            for (k, v) in pairs where k.text == "version" { serverVersion = "Redis " + (v.text ?? "") }
        }
        if !resp3, case .string(let info) = try commandSync([Data("INFO".utf8), Data("server".utf8)]) {
            let text = String(decoding: info, as: UTF8.self)
            if let line = text.split(separator: "\r\n").first(where: { $0.hasPrefix("redis_version:") }) {
                serverVersion = "Redis " + line.dropFirst(14)
            }
        }
        if case .integer(let id) = try commandSync([Data("CLIENT".utf8), Data("ID".utf8)]) { clientID = id }
        if database != 0 { try select(database) }
    }

    private func select(_ db: Int) throws {
        if case .error(let e) = try commandSync([Data("SELECT".utf8), Data(String(db).utf8)]) { throw DatabaseError(e) }
        currentDB = db
    }

    // MARK: RESP

    private func write(_ args: [Data]) throws {
        var out = Data("*\(args.count)\r\n".utf8)
        for a in args {
            out += Data("$\(a.count)\r\n".utf8)
            out += a
            out += Data("\r\n".utf8)
        }
        try stream.write([UInt8](out))
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        while true {
            let b = try stream.read(1)[0]
            if b == 13 {
                _ = try stream.read(1)  // \n
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(b)
        }
    }

    func readReply() throws -> RedisValue {
        let line = try readLine()
        guard let prefix = line.first else { throw DatabaseError("Empty Redis reply") }
        let rest = String(line.dropFirst())
        switch prefix {
        case "+": return .string(Data(rest.utf8))
        case "-": return .error(rest)
        case ":": return .integer(Int64(rest) ?? 0)
        case "_": return .null
        case "#": return .bool(rest == "t")
        case ",": return .double(Double(rest.replacingOccurrences(of: "inf", with: "infinity")) ?? .nan)
        case "(": return .string(Data(rest.utf8))
        case "$", "!", "=":
            let n = Int(rest) ?? -1
            if n < 0 { return .null }
            var data = Data(try stream.read(n))
            _ = try stream.read(2)
            if prefix == "!" { return .error(String(decoding: data, as: UTF8.self)) }
            if prefix == "=", data.count >= 4 { data = data.dropFirst(4) }  // "txt:"
            return .string(data)
        case "*", "~", ">":
            let n = Int(rest) ?? -1
            if n < 0 { return .null }
            let items = try (0..<n).map { _ in try readReply() }
            if prefix == ">" { return try readReply() }  // out-of-band push: skip, read the real reply
            return prefix == "~" ? .set(items) : .array(items)
        case "%":
            let n = Int(rest) ?? 0
            return .map(try (0..<n).map { _ in (try readReply(), try readReply()) })
        case "|":  // attributes precede the actual reply
            let n = Int(rest) ?? 0
            for _ in 0..<(2 * n) { _ = try readReply() }
            return try readReply()
        default:
            throw DatabaseError("Unexpected Redis reply '\(line.prefix(40))'")
        }
    }

    func commandSync(_ args: [Data]) throws -> RedisValue {
        try write(args)
        return try readReply()
    }

    /// Sends several commands, then reads all replies (pipelining).
    func pipelineSync(_ commands: [[Data]]) throws -> [RedisValue] {
        for c in commands { try write(c) }
        return try commands.map { _ in try readReply() }
    }

    public func command(_ args: [String]) async throws -> RedisValue {
        try await worker.run { [self] in try commandSync(args.map { Data($0.utf8) }) }
    }

    func onWorker<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T { try await worker.run(body) }

    // MARK: Console

    /// Splits a redis-cli style line: "double quoted" (with \n \t \" \\ \xHH escapes), 'single quoted', or bare words.
    public static func parseArguments(_ line: String) throws -> [Data] {
        var args: [Data] = []
        var current = Data()
        var inWord = false
        var chars = Array(line.unicodeScalars)
        var i = 0
        func flush() {
            if inWord { args.append(current) }
            current = Data()
            inWord = false
        }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" {
                flush()
            } else if c == "\"" {
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": current.append(10)
                        case "r": current.append(13)
                        case "t": current.append(9)
                        case "x" where i + 2 < chars.count:
                            if let b = UInt8(String(chars[i + 1]) + String(chars[i + 2]), radix: 16) {
                                current.append(b)
                                i += 2
                            }
                        default: current += Data(String(chars[i]).utf8)
                        }
                    } else {
                        current += Data(String(chars[i]).utf8)
                    }
                    i += 1
                }
                guard i < chars.count else { throw DatabaseError("Unbalanced quotes") }
            } else if c == "'" {
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "'" {
                    if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "'" { i += 1 }
                    current += Data(String(chars[i]).utf8)
                    i += 1
                }
                guard i < chars.count else { throw DatabaseError("Unbalanced quotes") }
            } else {
                inWord = true
                current += Data(String(c).utf8)
            }
            i += 1
        }
        flush()
        chars.removeAll()
        return args
    }

    public func execute(_ text: String, maxRows: Int) async throws -> QueryResult {
        let start = Date()
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return QueryResult(statement: text, message: "empty") }
        let commands = try lines.map(Self.parseArguments)
        let reply = try await worker.run { [self] () -> RedisValue in
            var last: RedisValue = .null
            for args in commands where !args.isEmpty {
                last = try commandSync(args)
                if case .error(let e) = last { throw DatabaseError(e) }
                let name = String(decoding: args[0], as: UTF8.self).uppercased()
                if name == "SELECT", args.count > 1, let db = Int(String(decoding: args[1], as: UTF8.self)) { currentDB = db }
            }
            return last
        }
        var result = Self.result(reply, statement: text, maxRows: maxRows)
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    static func result(_ reply: RedisValue, statement: String, maxRows: Int) -> QueryResult {
        func rows(_ items: [[SQLValue]], _ columns: [String]) -> QueryResult {
            QueryResult(
                statement: statement, columns: columns.map { ResultColumn(name: $0, typeName: "") },
                rows: Array(items.prefix(maxRows)), truncated: items.count > maxRows)
        }
        switch reply {
        case .null:
            return QueryResult(statement: statement, message: "(nil)")
        case .string(let d) where d == Data("OK".utf8):
            return QueryResult(statement: statement, message: "OK")
        case .map(let pairs):
            return rows(pairs.map { [$0.0.cell, $0.1.cell] }, ["key", "value"])
        case .array(let items), .set(let items):
            // [[a, b], …] (e.g. ZRANGE … WITHSCORES, XRANGE) → two columns.
            if !items.isEmpty, items.allSatisfy({ if case .array(let p) = $0 { p.count == 2 } else { false } }) {
                return rows(items.map { if case .array(let p) = $0 { [p[0].cell, p[1].cell] } else { [] } }, ["item", "value"])
            }
            return rows(items.enumerated().map { [.integer(Int64($0.offset)), $0.element.cell] }, ["#", "value"])
        default:
            return rows([[reply.cell]], ["value"])
        }
    }

    public func cancel() {
        guard let id = clientID else { return }
        let (host, port, user, password, tls) = (host, port, user, password, tls)
        Task.detached {
            guard let killer = try? await RedisConnection.connect(host: host, port: port, user: user, password: password, tls: tls) else { return }
            _ = try? await killer.command(["CLIENT", "KILL", "ID", String(id)])
            await killer.close()
        }
    }

    public func close() async {
        try? write([Data("QUIT".utf8)])
        stream.close()
    }
}
