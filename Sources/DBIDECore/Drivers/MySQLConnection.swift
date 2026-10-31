import CryptoKit
import Foundation
import Security

/// MySQL / MariaDB over the classic client/server protocol (text resultsets).
/// Supports mysql_native_password and caching_sha2_password (RSA full auth without TLS).
public final class MySQLConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect = SQLDialect.mysql
    public private(set) var serverVersion = "MySQL"
    private let socket: TCPSocket
    private var stream: any ByteStream
    public private(set) var securityDescription: String?
    private let tls: TLSOptions
    private let worker = SerialWorker(label: "dbide.mysql")
    private var sequence: UInt8 = 0
    private var threadID: UInt32 = 0
    private let host: String, port: Int, user: String, password: String

    // Capability flags.
    private static let longPassword: UInt32 = 0x1
    private static let foundRows: UInt32 = 0x2  // affected rows = matched rows
    private static let longFlag: UInt32 = 0x4
    private static let clientSSL: UInt32 = 0x800
    private static let connectWithDB: UInt32 = 0x8
    private static let protocol41: UInt32 = 0x200
    private static let transactions: UInt32 = 0x2000
    private static let secureConnection: UInt32 = 0x8000
    private static let multiStatements: UInt32 = 0x10000
    private static let multiResults: UInt32 = 0x20000
    private static let pluginAuth: UInt32 = 0x80000
    private static let pluginAuthLenenc: UInt32 = 0x200000
    private static let moreResultsExist: UInt16 = 0x0008

    public static func connect(
        host: String, port: Int = 3306, user: String, password: String, database: String,
        tls: TLSOptions = .disabled
    ) async throws -> MySQLConnection {
        try await SerialWorker(label: "dbide.mysql.connect").run {
            try MySQLConnection(host: host, port: port, user: user, password: password, database: database, tls: tls)
        }
    }

    private init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.tls = tls
        socket = try TCPSocket(host: host, port: port)
        stream = socket
        do {
            try handshake(database: database)
        } catch {
            socket.close()
            throw error
        }
    }

    // MARK: Packets

    private func readPacket() throws -> [UInt8] {
        var payload: [UInt8] = []
        while true {
            let header = try stream.read(4)
            let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            sequence = header[3] &+ 1
            payload += try stream.read(length)
            if length < 0xFFFFFF { return payload }
        }
    }

    private func writePacket(_ payload: [UInt8]) throws {
        var offset = 0
        repeat {
            let chunk = min(0xFFFFFF, payload.count - offset)
            var w = ByteWriter()
            w.intLE(UInt64(chunk), size: 3)
            w.u8(sequence)
            sequence &+= 1
            w.append(Array(payload[offset..<offset + chunk]))
            try stream.write(w.bytes)
            offset += chunk
            if chunk < 0xFFFFFF { break }
        } while true
    }

    private static func parseError(_ packet: [UInt8]) -> DatabaseError {
        var r = ByteReader(packet)
        _ = try? r.u8()
        let code = (try? r.uintLE(2)) ?? 0
        var state: String?
        if r.peek() == UInt8(ascii: "#") {
            _ = try? r.u8()
            state = (try? r.take(5)).map { String(decoding: $0, as: UTF8.self) }
        }
        let message = String(decoding: r.rest(), as: UTF8.self)
        return DatabaseError(message, code: state.map { "\(code) (\($0))" } ?? "\(code)")
    }

    // MARK: Handshake

    private func handshake(database: String) throws {
        let greeting = try readPacket()
        if greeting.first == 0xFF { throw Self.parseError(greeting) }
        var r = ByteReader(greeting)
        let proto = try r.u8()
        guard proto == 10 else { throw DatabaseError("Unsupported MySQL protocol version \(proto)") }
        let version = try r.cString()
        serverVersion = (version.lowercased().contains("mariadb") ? "MariaDB " : "MySQL ") + version
        threadID = UInt32(try r.uintLE(4))
        var scramble = try r.take(8)
        try r.skip(1)
        var caps = UInt32(try r.uintLE(2))
        var plugin = "mysql_native_password"
        if !r.atEnd {
            try r.skip(1)  // charset
            try r.skip(2)  // status
            caps |= UInt32(try r.uintLE(2)) << 16
            let authLen = Int(try r.u8())
            try r.skip(10)
            if caps & Self.secureConnection != 0 {
                let n = max(13, authLen - 8)
                scramble += try r.take(n).prefix(while: { $0 != 0 })
            }
            if caps & Self.pluginAuth != 0, !r.atEnd { plugin = try r.cString() }
        }

        var flags: UInt32 = Self.longPassword | Self.foundRows | Self.longFlag | Self.protocol41 | Self.transactions
            | Self.secureConnection | Self.multiStatements | Self.multiResults | Self.pluginAuth
            | Self.pluginAuthLenenc
        if !database.isEmpty { flags |= Self.connectWithDB }
        flags &= caps | Self.connectWithDB

        if tls.mode != .disable {
            if caps & Self.clientSSL != 0 {
                flags |= Self.clientSSL
                // SSLRequest: the first 32 bytes of the handshake response, then upgrade.
                var ssl = ByteWriter()
                ssl.intLE(UInt64(flags), size: 4)
                ssl.intLE(16 * 1024 * 1024, size: 4)
                ssl.u8(45)
                ssl.append([UInt8](repeating: 0, count: 23))
                try writePacket(ssl.bytes)
                let t = try TLSStream(socket: socket, host: host, options: tls)
                stream = t
                securityDescription = t.negotiatedDescription
            } else if tls.mode.requiresTLS {
                throw DatabaseError("Server does not support SSL, but SSL mode is \(tls.mode.rawValue)")
            }
        }

        let authResponse = try scrambleResponse(plugin: plugin, scramble: scramble)
        var w = ByteWriter()
        w.intLE(UInt64(flags), size: 4)
        w.intLE(16 * 1024 * 1024, size: 4)
        w.u8(45)  // utf8mb4_general_ci
        w.append([UInt8](repeating: 0, count: 23))
        w.cString(user)
        if flags & Self.pluginAuthLenenc != 0 {
            w.lenencInt(UInt64(authResponse.count))
        } else {
            w.u8(UInt8(authResponse.count))
        }
        w.append(authResponse)
        if flags & Self.connectWithDB != 0 { w.cString(database) }
        if flags & Self.pluginAuth != 0 { w.cString(plugin) }
        try writePacket(w.bytes)

        try authenticate(plugin: plugin, scramble: scramble)
        _ = try executeSync("SET NAMES utf8mb4", maxRows: 0)
    }

    private func scrambleResponse(plugin: String, scramble: [UInt8]) throws -> [UInt8] {
        let pw = Array(password.utf8)
        if pw.isEmpty { return [] }
        let nonce = Array(scramble.prefix(20))
        switch plugin {
        case "mysql_native_password":
            let h1 = [UInt8](Insecure.SHA1.hash(data: pw))
            let h2 = [UInt8](Insecure.SHA1.hash(data: h1))
            let h3 = [UInt8](Insecure.SHA1.hash(data: nonce + h2))
            return zip(h1, h3).map { $0 ^ $1 }
        case "caching_sha2_password":
            let h1 = [UInt8](SHA256.hash(data: pw))
            let h2 = [UInt8](SHA256.hash(data: h1))
            let h3 = [UInt8](SHA256.hash(data: h2 + nonce))
            return zip(h1, h3).map { $0 ^ $1 }
        case "mysql_clear_password":
            return pw + [0]
        default:
            throw DatabaseError("Unsupported MySQL auth plugin '\(plugin)'")
        }
    }

    private func authenticate(plugin startPlugin: String, scramble startScramble: [UInt8]) throws {
        var plugin = startPlugin
        var scramble = startScramble
        while true {
            let packet = try readPacket()
            guard let head = packet.first else { throw DatabaseError("Empty auth packet") }
            switch head {
            case 0x00:
                return
            case 0xFF:
                throw Self.parseError(packet)
            case 0xFE:  // auth switch
                var r = ByteReader(packet)
                _ = try r.u8()
                plugin = try r.cString()
                scramble = Array(r.rest().prefix(while: { $0 != 0 }))
                try writePacket(try scrambleResponse(plugin: plugin, scramble: scramble))
            case 0x01:  // more data
                guard plugin == "caching_sha2_password" else { throw DatabaseError("Unexpected auth data") }
                if packet.count >= 2, packet[1] == 0x03 { continue }  // fast auth OK; OK packet follows
                if packet.count >= 2, packet[1] == 0x04 {
                    if securityDescription != nil {
                        try writePacket(Array(password.utf8) + [0])  // cleartext is fine over TLS
                    } else {
                        try writePacket([0x02])  // request server public key
                    }
                    continue
                }
                // Public key (PEM) arrived.
                let pem = String(decoding: packet.dropFirst(), as: UTF8.self)
                let plain = Array(password.utf8) + [0]
                let xored = plain.enumerated().map { $0.element ^ scramble[$0.offset % scramble.count] }
                try writePacket(try Self.rsaEncrypt(xored, pem: pem))
            default:
                throw DatabaseError("Unexpected auth packet 0x\(String(head, radix: 16))")
            }
        }
    }

    static func rsaEncrypt(_ data: [UInt8], pem: String) throws -> [UInt8] {
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64) else { throw DatabaseError("Bad server public key") }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error)
            ?? SecKeyCreateWithData(ASN1.rsaKeyFromSPKI(der) as CFData, attrs as CFDictionary, &error)
        guard let key else { throw DatabaseError("Cannot load server public key") }
        guard let out = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(data) as CFData, &error)
        else { throw DatabaseError("RSA encryption failed") }
        return [UInt8](out as Data)
    }

    // MARK: Query

    public func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        try await worker.run { [self] in try executeSync(sql, maxRows: maxRows) }
    }

    private func executeSync(_ sql: String, maxRows: Int) throws -> QueryResult {
        let start = Date()
        sequence = 0
        try writePacket([0x03] + Array(sql.utf8))

        var results: [QueryResult] = []
        var failure: DatabaseError?
        var more = true
        while more {
            let packet = try readPacket()
            guard let head = packet.first else { throw DatabaseError("Empty response") }
            switch head {
            case 0x00:
                var r = ByteReader(packet)
                _ = try r.u8()
                let affected = try r.lenencInt() ?? 0
                _ = try r.lenencInt()
                let status = UInt16(try r.uintLE(2))
                _ = try r.uintLE(2)
                let info = String(decoding: r.rest(), as: UTF8.self)
                results.append(
                    QueryResult(statement: sql, affectedRows: Int(affected), message: info.isEmpty ? nil : info))
                more = status & Self.moreResultsExist != 0
            case 0xFF:
                failure = Self.parseError(packet)
                more = false
            case 0xFB:
                try writePacket([])  // refuse LOCAL INFILE
                failure = DatabaseError("LOAD DATA LOCAL INFILE is not supported")
            default:
                var r = ByteReader(packet)
                let count = Int(try r.lenencInt() ?? 0)
                var columns: [ResultColumn] = []
                var kinds: [MySQLTypes.Kind] = []
                for _ in 0..<count {
                    var c = ByteReader(try readPacket())
                    for _ in 0..<4 { _ = try c.lenencBytes() }  // catalog, schema, table, org_table
                    let name = try c.lenencString() ?? ""
                    _ = try c.lenencBytes()  // org_name
                    _ = try c.lenencInt()
                    let charset = UInt16(try c.uintLE(2))
                    _ = try c.uintLE(4)
                    let type = try c.u8()
                    let flags = UInt16(try c.uintLE(2))
                    columns.append(ResultColumn(name: name, typeName: MySQLTypes.name(type, flags: flags)))
                    kinds.append(MySQLTypes.kind(type, charset: charset))
                }
                var p = try readPacket()
                if !Self.isEOF(p) { throw DatabaseError("Expected EOF after column definitions") }
                var res = QueryResult(statement: sql, columns: columns)
                while true {
                    p = try readPacket()
                    if Self.isEOF(p) {
                        var e = ByteReader(p)
                        _ = try e.u8()
                        _ = try e.uintLE(2)
                        more = UInt16(try e.uintLE(2)) & Self.moreResultsExist != 0
                        break
                    }
                    if p.first == 0xFF {
                        failure = Self.parseError(p)
                        more = false
                        break
                    }
                    if res.rows.count >= maxRows {
                        res.truncated = true
                        continue
                    }
                    var rr = ByteReader(p)
                    var row: [SQLValue] = []
                    row.reserveCapacity(count)
                    for i in 0..<count {
                        if let bytes = try rr.lenencBytes() {
                            row.append(MySQLTypes.decode(bytes, kind: kinds[i]))
                        } else {
                            row.append(.null)
                        }
                    }
                    res.rows.append(row)
                }
                results.append(res)
            }
        }
        if let failure { throw failure }
        var res = results.last(where: { $0.hasResultSet }) ?? results.last ?? QueryResult(statement: sql)
        if !res.hasResultSet, res.message == nil {
            res.message = SQLLexer.leadingKeywords(sql, count: 2).uppercased()
        }
        res.duration = Date().timeIntervalSince(start)
        return res
    }

    private static func isEOF(_ p: [UInt8]) -> Bool { p.first == 0xFE && p.count < 9 }

    public func cancel() {
        let host = host, port = port, user = user, password = password, id = threadID, tls = tls
        Task.detached {
            guard let killer = try? await MySQLConnection.connect(
                host: host, port: port, user: user, password: password, database: "", tls: tls)
            else { return }
            _ = try? await killer.execute("KILL QUERY \(id)")
            await killer.close()
        }
    }

    public func close() async {
        sequence = 0
        try? writePacket([0x01])
        socket.close()
    }
}

enum MySQLTypes {
    enum Kind { case integer, real, binary, text }

    static func kind(_ type: UInt8, charset: UInt16) -> Kind {
        switch type {
        case 0x01, 0x02, 0x03, 0x08, 0x09, 0x0D: return .integer
        case 0x04, 0x05: return .real
        case 0xF9, 0xFA, 0xFB, 0xFC, 0xFE, 0xFD, 0x0F: return charset == 63 ? .binary : .text
        case 0x10: return .binary  // BIT
        default: return .text
        }
    }

    static func name(_ type: UInt8, flags: UInt16) -> String {
        let unsigned = flags & 0x20 != 0 ? " unsigned" : ""
        let n: String =
            switch type {
            case 0x00, 0xF6: "decimal"
            case 0x01: "tinyint"
            case 0x02: "smallint"
            case 0x03: "int"
            case 0x04: "float"
            case 0x05: "double"
            case 0x06: "null"
            case 0x07: "timestamp"
            case 0x08: "bigint"
            case 0x09: "mediumint"
            case 0x0A: "date"
            case 0x0B: "time"
            case 0x0C: "datetime"
            case 0x0D: "year"
            case 0x0F, 0xFD: "varchar"
            case 0x10: "bit"
            case 0xF5: "json"
            case 0xF7: "enum"
            case 0xF8: "set"
            case 0xF9, 0xFA, 0xFB, 0xFC: "blob"
            case 0xFE: "char"
            case 0xFF: "geometry"
            default: "type:\(type)"
            }
        return n + unsigned
    }

    static func decode(_ bytes: [UInt8], kind: Kind) -> SQLValue {
        switch kind {
        case .binary: return .blob(Data(bytes))
        case .integer:
            let s = String(decoding: bytes, as: UTF8.self)
            return Int64(s).map(SQLValue.integer) ?? .text(s)
        case .real:
            let s = String(decoding: bytes, as: UTF8.self)
            return Double(s).map(SQLValue.real) ?? .text(s)
        case .text: return .text(String(decoding: bytes, as: UTF8.self))
        }
    }
}

/// Just enough DER parsing to pull an RSAPublicKey out of a SubjectPublicKeyInfo.
enum ASN1 {
    static func rsaKeyFromSPKI(_ der: Data) -> Data {
        let b = [UInt8](der)
        var i = 0
        func readLength() -> Int? {
            guard i < b.count else { return nil }
            var len = Int(b[i])
            i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                len = 0
                for _ in 0..<n {
                    guard i < b.count else { return nil }
                    len = len << 8 | Int(b[i])
                    i += 1
                }
            }
            return len
        }
        // SEQUENCE { SEQUENCE { algorithm }, BIT STRING { 0x00, RSAPublicKey } }
        guard b.first == 0x30 else { return der }
        i = 1
        guard readLength() != nil, i < b.count, b[i] == 0x30 else { return der }
        i += 1
        guard let algLen = readLength() else { return der }
        i += algLen
        guard i < b.count, b[i] == 0x03 else { return der }
        i += 1
        guard let bitLen = readLength(), i + bitLen <= b.count else { return der }
        return Data(b[(i + 1)..<(i + bitLen)])
    }
}
