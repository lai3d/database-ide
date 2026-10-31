import Foundation

/// MongoDB over the OP_MSG wire protocol (MongoDB 3.6+), with SCRAM-SHA-256 / SHA-1 auth.
public final class MongoConnection: @unchecked Sendable {
    public private(set) var serverVersion = "MongoDB"
    public private(set) var securityDescription: String?
    /// Database used by `db.` in the console (`use x` switches it).
    public var database: String
    public private(set) var isWritablePrimary = true
    public private(set) var primaryHost: String?

    private let socket: TCPSocket
    private var stream: any ByteStream
    private let worker = SerialWorker(label: "dbide.mongo")
    private var requestID: Int32 = 0
    let host: String, port: Int
    let user: String, password: String, authSource: String
    let tls: TLSOptions

    public static func connect(
        host: String, port: Int = 27017, user: String, password: String, database: String,
        authSource: String? = nil, tls: TLSOptions = .disabled
    ) async throws -> MongoConnection {
        try await SerialWorker(label: "dbide.mongo.connect").run {
            try MongoConnection(
                host: host, port: port, user: user, password: password, database: database,
                authSource: (authSource?.isEmpty == false ? authSource! : "admin"), tls: tls)
        }
    }

    private init(host: String, port: Int, user: String, password: String, database: String, authSource: String, tls: TLSOptions) throws {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.authSource = authSource
        self.database = database.isEmpty ? "test" : database
        self.tls = tls
        socket = try TCPSocket(host: host, port: port)
        stream = socket
        do {
            // MongoDB speaks TLS from the first byte (no negotiation), so "prefer" means plain.
            if tls.mode.requiresTLS {
                let t = try TLSStream(socket: socket, host: host, options: tls)
                stream = t
                securityDescription = t.negotiatedDescription
            }
            try handshake()
        } catch {
            socket.close()
            throw error
        }
    }

    /// Connects using a data source config (SSH tunnel, SRV, authSource, replica-set primary).
    public static func connect(config: DataSourceConfig, password: String) async throws -> MongoConnection {
        var tls = config.tlsOptions
        var authSource = config.authSource
        var candidates: [(String, Int)] = [(config.host, config.port)]
        if config.srv {
            let resolved = try await SerialWorker(label: "dbide.srv").run { try DNSSRV.resolveMongoSRV(config.host) }
            candidates = resolved.hosts
            if authSource.isEmpty, let a = resolved.options["authSource"] { authSource = a }
            if tls.mode == .disable || tls.mode == .prefer { tls.mode = .require }  // SRV implies TLS by default
            if resolved.options["tls"] == "false" || resolved.options["ssl"] == "false" { tls.mode = .disable }
        }
        var lastError: Error = DatabaseError("No MongoDB hosts")
        for (host, port) in candidates {
            do {
                var cfg = config
                cfg.host = host
                cfg.port = port
                cfg.sslMode = tls.mode
                let (h, p, endpointTLS) = try await cfg.endpoint()
                var useTLS = endpointTLS
                useTLS.serverName = config.ssh.enabled ? host : nil
                let conn = try await connect(
                    host: h, port: p, user: config.user, password: password, database: config.database,
                    authSource: authSource, tls: useTLS)
                // Writes must go to the primary of a replica set.
                if !conn.isWritablePrimary, let primary = conn.primaryHost, !config.ssh.enabled,
                    let colon = primary.lastIndex(of: ":"), let pport = Int(primary[primary.index(after: colon)...])
                {
                    let phost = String(primary[..<colon])
                    if phost != host || pport != port {
                        await conn.close()
                        return try await connect(
                            host: phost, port: pport, user: config.user, password: password, database: config.database,
                            authSource: authSource, tls: tls)
                    }
                }
                return conn
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: OP_MSG

    private func send(_ command: BSONDocument) throws -> Int32 {
        requestID &+= 1
        let body = BSON.encode(command)
        var w = ByteWriter()
        w.intLE(UInt64(16 + 4 + 1 + body.count), size: 4)
        w.intLE(UInt64(UInt32(bitPattern: requestID)), size: 4)
        w.intLE(0, size: 4)
        w.intLE(2013, size: 4)  // OP_MSG
        w.intLE(0, size: 4)  // flagBits
        w.u8(0)  // section kind 0: body
        w.append(body)
        try stream.write(w.bytes)
        return requestID
    }

    private func receive() throws -> BSONDocument {
        var header = ByteReader(try stream.read(16))
        let length = Int(try header.uintLE(4))
        _ = try header.uintLE(4)
        _ = try header.uintLE(4)
        let opCode = try header.uintLE(4)
        guard length >= 21 else { throw DatabaseError("Malformed MongoDB reply") }
        var r = ByteReader(try stream.read(length - 16))
        guard opCode == 2013 else { throw DatabaseError("Unexpected MongoDB opcode \(opCode)") }
        let flags = try r.uintLE(4)
        let end = r.bytes.count - (flags & 1 != 0 ? 4 : 0)  // checksumPresent
        var body: BSONDocument?
        while r.index < end {
            let kind = try r.u8()
            if kind == 0 {
                body = try BSON.readDocument(&r)
            } else {
                let size = Int(try r.uintLE(4))
                try r.skip(size - 4)  // document sequences are not used in replies we request
            }
        }
        guard let body else { throw DatabaseError("MongoDB reply without body") }
        return body
    }

    /// Runs a command synchronously against `db`; throws on `ok: 0`.
    func runSync(_ command: BSONDocument, db: String) throws -> BSONDocument {
        var cmd = command
        cmd["$db"] = .string(db)
        _ = try send(cmd)
        let reply = try receive()
        let ok: Bool =
            switch reply["ok"] {
            case .double(let d): d == 1
            case .int32(let i): i == 1
            case .int64(let i): i == 1
            case .bool(let b): b
            default: false
            }
        guard ok else {
            let msg = reply["errmsg"]?.string ?? "Command failed"
            let code = reply["codeName"]?.string ?? reply["code"].flatMap(\.int).map(String.init)
            throw DatabaseError(msg, code: code)
        }
        if let wErrors = reply["writeErrors"]?.array, let first = wErrors.first?.document {
            throw DatabaseError(first["errmsg"]?.string ?? "Write error", code: first["code"].flatMap(\.int).map(String.init))
        }
        return reply
    }

    public func runCommand(_ command: BSONDocument, db: String? = nil) async throws -> BSONDocument {
        let db = db ?? database
        return try await worker.run { [self] in try runSync(command, db: db) }
    }

    // MARK: Handshake & auth

    private func handshake() throws {
        var hello: BSONDocument = [
            "hello": .int32(1),
            "client": .document([
                "application": .document(["name": .string("DBIDE")]),
                "driver": .document(["name": .string("DBIDE"), "version": .string("0.1")]),
                "os": .document(["type": .string("Darwin")]),
            ]),
        ]
        if !user.isEmpty { hello["saslSupportedMechs"] = .string("\(authSource).\(user)") }
        let reply = try runSync(hello, db: "admin")
        isWritablePrimary = reply["isWritablePrimary"]?.bool ?? reply["ismaster"]?.bool ?? true
        primaryHost = reply["primary"]?.string
        let mechs = reply["saslSupportedMechs"]?.array?.compactMap(\.string) ?? []
        if !user.isEmpty {
            let mech: SCRAMClient.Hash = mechs.isEmpty || mechs.contains("SCRAM-SHA-256") ? .sha256 : .sha1
            try authenticate(mech)
        }
        let info = (try? runSync(["buildInfo": .int32(1)], db: "admin")) ?? [:]
        serverVersion = "MongoDB " + (info["version"]?.string ?? "")
    }

    private func authenticate(_ hash: SCRAMClient.Hash) throws {
        // SCRAM-SHA-1 hashes the password the legacy MongoDB way first.
        let secret = hash == .sha1 ? md5Hex("\(user):mongo:\(password)") : password
        let client = SCRAMClient(password: secret, user: user, hash: hash)
        let mechanism = hash == .sha256 ? "SCRAM-SHA-256" : "SCRAM-SHA-1"
        var reply = try runSync([
            "saslStart": .int32(1), "mechanism": .string(mechanism),
            "payload": .binary(subtype: 0, Data(client.clientFirstMessage.utf8)),
            "options": .document(["skipEmptyExchange": .bool(true)]),
        ], db: authSource)
        func payload(_ r: BSONDocument) -> String {
            if case .binary(_, let d) = r["payload"] { return String(decoding: d, as: UTF8.self) }
            return ""
        }
        let conversation = reply["conversationId"] ?? .int32(1)
        let final = try client.clientFinalMessage(serverFirst: payload(reply))
        reply = try runSync([
            "saslContinue": .int32(1), "conversationId": conversation,
            "payload": .binary(subtype: 0, Data(final.utf8)),
        ], db: authSource)
        try client.verifyServerFinal(payload(reply))
        var rounds = 0
        while reply["done"]?.bool != true && rounds < 3 {
            rounds += 1
            reply = try runSync([
                "saslContinue": .int32(1), "conversationId": conversation, "payload": .binary(subtype: 0, Data()),
            ], db: authSource)
        }
    }

    private func md5Hex(_ s: String) -> String {
        Insecure_MD5_hex(Array(s.utf8))
    }

    // MARK: Cursors

    /// Drains a cursor reply ({cursor: {firstBatch, id, ns}}) up to `limit` documents.
    func drainCursor(_ reply: BSONDocument, db: String, limit: Int) throws -> (docs: [BSONDocument], truncated: Bool) {
        guard var cursor = reply["cursor"]?.document else { return ([], false) }
        var docs = (cursor["firstBatch"]?.array ?? []).compactMap(\.document)
        var id = cursor["id"]?.int ?? 0
        let collection = cursor["ns"]?.string.map { String($0.split(separator: ".", maxSplits: 1).last ?? "") } ?? ""
        while id != 0 && docs.count < limit {
            let more = try runSync([
                "getMore": .int64(id), "collection": .string(collection),
                "batchSize": .int32(Int32(min(1000, max(1, limit - docs.count)))),
            ], db: db)
            cursor = more["cursor"]?.document ?? [:]
            docs += (cursor["nextBatch"]?.array ?? []).compactMap(\.document)
            id = cursor["id"]?.int ?? 0
        }
        let truncated = id != 0 || docs.count > limit
        if id != 0 {
            _ = try? runSync(["killCursors": .string(collection), "cursors": .array([.int64(id)])], db: db)
        }
        return (Array(docs.prefix(limit)), truncated)
    }

    func cursorSync(_ command: BSONDocument, db: String, limit: Int) throws -> (docs: [BSONDocument], truncated: Bool) {
        try drainCursor(try runSync(command, db: db), db: db, limit: limit)
    }

    public func cursor(_ command: BSONDocument, db: String? = nil, limit: Int = .max) async throws -> [BSONDocument] {
        let db = db ?? database
        return try await worker.run { [self] in try cursorSync(command, db: db, limit: limit).docs }
    }

    public func close() async {
        socket.close()
    }

    /// Runs work on the connection's serial queue (used by the shell layer).
    func onWorker<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await worker.run(body)
    }

    func shutdownSocket() { socket.shutdown() }

    private let tagLock = NSLock()
    private var _runningTag: String?
    /// Comment attached to the operation in flight (used by `cancel()` to find it).
    var runningTag: String? {
        tagLock.lock()
        defer { tagLock.unlock() }
        return _runningTag
    }
    func setRunningTag(_ tag: String?) {
        tagLock.lock()
        _runningTag = tag
        tagLock.unlock()
    }
}

import CryptoKit

func Insecure_MD5_hex(_ bytes: [UInt8]) -> String {
    Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
