import CommonCrypto
import CryptoKit
import Foundation

/// PostgreSQL over the v3 frontend/backend protocol (simple query flow, text format).
/// TLS is not supported yet: the server must accept non-SSL connections.
public final class PostgresConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect = SQLDialect.postgres
    public private(set) var serverVersion = "PostgreSQL"
    private let socket: TCPSocket
    private var stream: any ByteStream
    public private(set) var securityDescription: String?
    public private(set) var inTransaction = false
    private let worker = SerialWorker(label: "dbide.postgres")
    private let host: String
    private let port: Int
    private var backendPID: Int32 = 0
    private var backendSecret: Int32 = 0
    public private(set) var parameters: [String: String] = [:]
    /// Notices raised by the server during the last statement (RAISE NOTICE etc).
    public private(set) var notices: [String] = []

    public static func connect(
        host: String, port: Int = 5432, user: String, password: String, database: String,
        tls: TLSOptions = .disabled
    ) async throws -> PostgresConnection {
        let worker = SerialWorker(label: "dbide.postgres.connect")
        return try await worker.run {
            try PostgresConnection(host: host, port: port, user: user, password: password, database: database, tls: tls)
        }
    }

    private init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        self.host = host
        self.port = port
        socket = try TCPSocket(host: host, port: port)
        stream = socket
        do {
            try negotiateTLS(tls)
            try startup(user: user, password: password, database: database.isEmpty ? user : database)
        } catch {
            socket.close()
            throw error
        }
    }

    // MARK: TLS

    private func negotiateTLS(_ tls: TLSOptions) throws {
        guard tls.mode != .disable else { return }
        var w = ByteWriter()
        w.int32BE(8)
        w.int32BE(80877103)  // SSLRequest
        try socket.write(w.bytes)
        let answer = try socket.read(1)[0]
        if answer == UInt8(ascii: "S") {
            let t = try TLSStream(socket: socket, host: host, options: tls)
            stream = t
            securityDescription = t.negotiatedDescription
        } else if tls.mode.requiresTLS {
            throw DatabaseError("Server does not support SSL, but SSL mode is \(tls.mode.rawValue)")
        }
    }

    // MARK: Framing

    private func send(_ type: UInt8, _ payload: [UInt8]) throws {
        var w = ByteWriter()
        w.u8(type)
        w.int32BE(Int32(payload.count + 4))
        w.append(payload)
        try stream.write(w.bytes)
    }

    private func receive() throws -> (type: UInt8, body: ByteReader) {
        let header = try stream.read(5)
        var r = ByteReader(header)
        let type = try r.u8()
        let length = Int(try r.int32BE())
        guard length >= 4 else { throw DatabaseError("Malformed PostgreSQL message") }
        return (type, ByteReader(try stream.read(length - 4)))
    }

    private static func parseError(_ body: ByteReader) -> DatabaseError {
        var r = body
        var fields: [UInt8: String] = [:]
        while let t = try? r.u8(), t != 0 { fields[t] = (try? r.cString()) ?? "" }
        let severity = fields[UInt8(ascii: "S")].map { $0 + ": " } ?? ""
        var detail = [fields[UInt8(ascii: "D")], fields[UInt8(ascii: "H")].map { "Hint: " + $0 }]
            .compactMap { $0 }.joined(separator: "\n")
        if let w = fields[UInt8(ascii: "W")] { detail += (detail.isEmpty ? "" : "\n") + "Where: " + w }
        return DatabaseError(
            severity + (fields[UInt8(ascii: "M")] ?? "Unknown error"),
            code: fields[UInt8(ascii: "C")],
            detail: detail.isEmpty ? nil : detail,
            position: fields[UInt8(ascii: "P")].flatMap { Int($0) }.map { $0 - 1 })
    }

    // MARK: Startup & authentication

    private func startup(user: String, password: String, database: String) throws {
        var p = ByteWriter()
        p.int32BE(196608)  // protocol 3.0
        for (k, v) in [
            ("user", user), ("database", database), ("application_name", "DBIDE"),
            ("client_encoding", "UTF8"), ("DateStyle", "ISO"),
        ] {
            p.cString(k)
            p.cString(v)
        }
        p.u8(0)
        var msg = ByteWriter()
        msg.int32BE(Int32(p.bytes.count + 4))
        msg.append(p.bytes)
        try stream.write(msg.bytes)

        var scram: SCRAMClient?
        while true {
            let (type, body) = try receive()
            var r = body
            switch type {
            case UInt8(ascii: "R"):
                let code = try r.int32BE()
                switch code {
                case 0: break  // AuthenticationOk
                case 3:
                    try send(UInt8(ascii: "p"), Array(password.utf8) + [0])
                case 5:
                    let salt = try r.take(4)
                    let inner = md5Hex(Array((password + user).utf8))
                    try send(UInt8(ascii: "p"), Array(("md5" + md5Hex(Array(inner.utf8) + salt)).utf8) + [0])
                case 10:
                    var mechanisms: [String] = []
                    while r.peek() != nil && r.peek() != 0 { mechanisms.append(try r.cString()) }
                    guard mechanisms.contains("SCRAM-SHA-256") else {
                        throw DatabaseError("Unsupported SASL mechanisms: \(mechanisms.joined(separator: ", "))")
                    }
                    let client = SCRAMClient(password: password)
                    scram = client
                    let first = Array(client.clientFirstMessage.utf8)
                    var w = ByteWriter()
                    w.cString("SCRAM-SHA-256")
                    w.int32BE(Int32(first.count))
                    w.append(first)
                    try send(UInt8(ascii: "p"), w.bytes)
                case 11:
                    guard let client = scram else { throw DatabaseError("Unexpected SASL continue") }
                    let final = try client.clientFinalMessage(serverFirst: String(decoding: r.rest(), as: UTF8.self))
                    try send(UInt8(ascii: "p"), Array(final.utf8))
                case 12:
                    guard let client = scram else { throw DatabaseError("Unexpected SASL final") }
                    try client.verifyServerFinal(String(decoding: r.rest(), as: UTF8.self))
                default:
                    throw DatabaseError("Unsupported authentication method (code \(code))")
                }
            case UInt8(ascii: "S"):
                let k = try r.cString()
                parameters[k] = try r.cString()
            case UInt8(ascii: "K"):
                backendPID = try r.int32BE()
                backendSecret = try r.int32BE()
            case UInt8(ascii: "E"):
                throw Self.parseError(body)
            case UInt8(ascii: "N"):
                break
            case UInt8(ascii: "Z"):
                serverVersion = "PostgreSQL " + (parameters["server_version"] ?? "")
                return
            default:
                throw DatabaseError("Unexpected message '\(Character(UnicodeScalar(type)))' during startup")
            }
        }
    }

    private func md5Hex(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Query

    public func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        try await worker.run { [self] in try executeSync(sql, maxRows: maxRows) }
    }

    private func executeSync(_ sql: String, maxRows: Int) throws -> QueryResult {
        let start = Date()
        notices = []
        try send(UInt8(ascii: "Q"), Array(sql.utf8) + [0])

        var results: [QueryResult] = []
        var current: QueryResult?
        var columnKinds: [PGTypeKind] = []
        var failure: DatabaseError?

        while true {
            let (type, body) = try receive()
            var r = body
            switch type {
            case UInt8(ascii: "T"):
                let n = Int(try r.int16BE())
                var columns: [ResultColumn] = []
                columnKinds = []
                for _ in 0..<n {
                    let name = try r.cString()
                    try r.skip(6)
                    let oid = UInt32(bitPattern: try r.int32BE())
                    try r.skip(8)
                    columns.append(ResultColumn(name: name, typeName: PGTypes.name(oid)))
                    columnKinds.append(PGTypes.kind(oid))
                }
                current = QueryResult(statement: sql, columns: columns)
            case UInt8(ascii: "D"):
                guard current != nil else { continue }
                if current!.rows.count >= maxRows {
                    current!.truncated = true
                    continue
                }
                let n = Int(try r.int16BE())
                var row: [SQLValue] = []
                row.reserveCapacity(n)
                for i in 0..<n {
                    let len = Int(try r.int32BE())
                    if len < 0 {
                        row.append(.null)
                    } else {
                        row.append(PGTypes.decode(try r.take(len), kind: i < columnKinds.count ? columnKinds[i] : .text))
                    }
                }
                current!.rows.append(row)
            case UInt8(ascii: "C"):
                let tag = try r.cString()
                var res = current ?? QueryResult(statement: sql)
                current = nil
                res.message = tag
                let parts = tag.split(separator: " ")
                if let first = parts.first, ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY", "MOVE", "FETCH", "SELECT"]
                    .contains(String(first)), let n = parts.last.flatMap({ Int($0) })
                {
                    if !res.hasResultSet { res.affectedRows = n }
                }
                results.append(res)
            case UInt8(ascii: "I"):
                results.append(QueryResult(statement: sql, message: "empty query"))
            case UInt8(ascii: "E"):
                failure = Self.parseError(body)
            case UInt8(ascii: "N"):
                let e = Self.parseError(body)
                notices.append(e.message)
            case UInt8(ascii: "G"):
                // COPY FROM STDIN is not supported from the console.
                var w = ByteWriter()
                w.cString("COPY FROM STDIN is not supported in DBIDE")
                try send(UInt8(ascii: "f"), w.bytes)
            case UInt8(ascii: "H"), UInt8(ascii: "d"), UInt8(ascii: "c"):
                break  // COPY TO STDOUT data is discarded
            case UInt8(ascii: "S"):
                let k = try r.cString()
                parameters[k] = try r.cString()
            case UInt8(ascii: "A"), UInt8(ascii: "K"):
                break
            case UInt8(ascii: "Z"):
                let status = (try? r.u8()) ?? UInt8(ascii: "I")
                inTransaction = status != UInt8(ascii: "I")  // 'T' in transaction, 'E' failed transaction
                if let failure { throw failure }
                // Prefer the last result that returned rows; otherwise the last one.
                var res = results.last(where: { $0.hasResultSet }) ?? results.last ?? QueryResult(statement: sql)
                res.duration = Date().timeIntervalSince(start)
                return res
            default:
                break
            }
        }
    }

    public func cancel() {
        let host = host, port = port, pid = backendPID, secret = backendSecret
        DispatchQueue.global().async {
            guard let s = try? TCPSocket(host: host, port: port, timeout: 5) else { return }
            var w = ByteWriter()
            w.int32BE(16)
            w.int32BE(80877102)
            w.int32BE(pid)
            w.int32BE(secret)
            try? s.write(w.bytes)
            s.close()
        }
    }

    public func close() async {
        try? stream.write([UInt8(ascii: "X"), 0, 0, 0, 4])
        socket.close()
    }
}

// MARK: - SCRAM (SHA-256 for PostgreSQL / MongoDB, SHA-1 for older MongoDB users)

final class SCRAMClient {
    enum Hash { case sha256, sha1 }

    let password: String
    let clientNonce: String
    let hash: Hash
    private(set) var clientFirstBare: String
    private var expectedServerSignature: [UInt8] = []

    /// PostgreSQL ignores the SCRAM user name (it uses the startup user), so it defaults to empty.
    init(password: String, nonce: String? = nil, user: String = "", hash: Hash = .sha256) {
        self.password = password
        self.hash = hash
        clientNonce = nonce ?? Data((0..<18).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let escapedUser = user.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        clientFirstBare = "n=\(escapedUser),r=" + clientNonce
    }

    var clientFirstMessage: String { "n,," + clientFirstBare }

    func clientFinalMessage(serverFirst: String) throws -> String {
        var attrs: [Character: String] = [:]
        for part in serverFirst.split(separator: ",") where part.count >= 2 {
            attrs[part.first!] = String(part.dropFirst(2))
        }
        guard let nonce = attrs["r"], nonce.hasPrefix(clientNonce),
            let saltB64 = attrs["s"], let salt = Data(base64Encoded: saltB64),
            let iterations = attrs["i"].flatMap({ Int($0) })
        else { throw DatabaseError("Invalid SCRAM server-first message") }

        let salted = pbkdf2(password: password, salt: [UInt8](salt), iterations: iterations)
        let clientKey = hmac(salted, Array("Client Key".utf8))
        let storedKey = digest(clientKey)
        let withoutProof = "c=biws,r=" + nonce
        let authMessage = clientFirstBare + "," + serverFirst + "," + withoutProof
        let signature = hmac(storedKey, Array(authMessage.utf8))
        let proof = zip(clientKey, signature).map { $0 ^ $1 }
        let serverKey = hmac(salted, Array("Server Key".utf8))
        expectedServerSignature = hmac(serverKey, Array(authMessage.utf8))
        return withoutProof + ",p=" + Data(proof).base64EncodedString()
    }

    func verifyServerFinal(_ message: String) throws {
        if message.hasPrefix("e=") { throw DatabaseError("SCRAM authentication failed: \(message.dropFirst(2))") }
        // MongoDB may append further attributes after v=…
        let v = message.split(separator: ",").first { $0.hasPrefix("v=") }.map { String($0.dropFirst(2)) } ?? ""
        guard let sig = Data(base64Encoded: v), [UInt8](sig) == expectedServerSignature
        else { throw DatabaseError("SCRAM server signature mismatch") }
    }

    private func digest(_ data: [UInt8]) -> [UInt8] {
        switch hash {
        case .sha256: [UInt8](SHA256.hash(data: data))
        case .sha1: [UInt8](Insecure.SHA1.hash(data: data))
        }
    }

    private func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        switch hash {
        case .sha256: [UInt8](HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        case .sha1: [UInt8](HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
    }

    static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        [UInt8](HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private func pbkdf2(password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        let size = hash == .sha256 ? 32 : 20
        var out = [UInt8](repeating: 0, count: size)
        let pw = Array(password.utf8)
        let prf = CCPseudoRandomAlgorithm(hash == .sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1)
        _ = pw.withUnsafeBufferPointer { pwp in
            pwp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(pw.count, 1)) { pwc in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pwc, pw.count, salt, salt.count, prf, UInt32(iterations), &out, out.count)
            }
        }
        return out
    }
}

// MARK: - Types

enum PGTypeKind { case integer, real, bool, bytea, text }

enum PGTypes {
    static let names: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 24: "regproc",
        25: "text", 26: "oid", 114: "json", 142: "xml", 700: "float4", 701: "float8", 790: "money",
        869: "inet", 650: "cidr", 829: "macaddr", 1042: "bpchar", 1043: "varchar", 1082: "date",
        1083: "time", 1114: "timestamp", 1184: "timestamptz", 1186: "interval", 1266: "timetz",
        1560: "bit", 1562: "varbit", 1700: "numeric", 2950: "uuid", 3802: "jsonb", 3614: "tsvector",
        1000: "_bool", 1005: "_int2", 1007: "_int4", 1016: "_int8", 1009: "_text", 1015: "_varchar",
        1021: "_float4", 1022: "_float8", 2951: "_uuid", 3807: "_jsonb", 199: "_json",
    ]

    static func name(_ oid: UInt32) -> String { names[oid] ?? "oid:\(oid)" }

    static func kind(_ oid: UInt32) -> PGTypeKind {
        switch oid {
        case 20, 21, 23, 26: .integer
        case 700, 701: .real
        case 16: .bool
        case 17: .bytea
        default: .text
        }
    }

    static func decode(_ bytes: [UInt8], kind: PGTypeKind) -> SQLValue {
        let s = String(decoding: bytes, as: UTF8.self)
        switch kind {
        case .integer: return Int64(s).map(SQLValue.integer) ?? .text(s)
        case .real: return Double(s).map(SQLValue.real) ?? .text(s)
        case .bool: return .text(s == "t" ? "true" : s == "f" ? "false" : s)
        case .bytea:
            guard s.hasPrefix("\\x") else { return .text(s) }
            var data = Data(capacity: (s.utf8.count - 2) / 2)
            var hi: UInt8?
            for c in s.utf8.dropFirst(2) {
                guard let v = hexValue(c) else { return .text(s) }
                if let h = hi {
                    data.append(h << 4 | v)
                    hi = nil
                } else {
                    hi = v
                }
            }
            return .blob(data)
        case .text: return .text(s)
        }
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        case 65...70: c - 55
        default: nil
        }
    }
}
