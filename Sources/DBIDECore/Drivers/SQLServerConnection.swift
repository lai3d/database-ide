import Foundation

/// Microsoft SQL Server / Azure SQL over TDS 7.4. TLS uses TDS 8.0 "strict" mode
/// (TLS first, ALPN tds/8.0); without TLS the server must not force encryption.
public final class SQLServerConnection: DatabaseConnection, @unchecked Sendable {
    public let dialect = SQLDialect.sqlserver
    public private(set) var serverVersion = "SQL Server"
    public private(set) var securityDescription: String?
    public private(set) var inTransaction = false
    public private(set) var database = ""

    private var stream: any ByteStream
    private let worker = SerialWorker(label: "dbide.mssql")
    private var packetSize = 4096
    private var transactionDescriptor = [UInt8](repeating: 0, count: 8)
    private let writeLock = NSLock()
    private var running = false
    private var attentionSent = false

    public static func connect(
        host: String, port: Int = 1433, user: String, password: String, database: String, tls: TLSOptions = .disabled
    ) async throws -> SQLServerConnection {
        try await SerialWorker(label: "dbide.mssql.connect").run {
            try SQLServerConnection(host: host, port: port, user: user, password: password, database: database, tls: tls)
        }
    }

    private init(host: String, port: Int, user: String, password: String, database: String, tls: TLSOptions) throws {
        let strict = tls.mode.requiresTLS
        if strict {
            let t = try NWTLSStream(host: host, port: port, options: tls, alpn: ["tds/8.0"])
            stream = t
            securityDescription = t.negotiatedDescription + " (TDS 8 strict)"
        } else {
            stream = try TCPSocket(host: host, port: port)
        }
        do {
            try prelogin(strict: strict)
            try login(host: host, user: user, password: password, database: database)
        } catch {
            stream.close()
            throw error
        }
    }

    // MARK: Packets

    enum PacketType: UInt8 { case sqlBatch = 0x01, reply = 0x04, attention = 0x06, login7 = 0x10, prelogin = 0x12 }

    private func send(_ type: PacketType, _ payload: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let chunk = packetSize - 8
        var offset = 0
        var id: UInt8 = 1
        repeat {
            let n = min(chunk, payload.count - offset)
            let last = offset + n >= payload.count
            var p: [UInt8] = [type.rawValue, last ? 0x01 : 0x00, UInt8((n + 8) >> 8), UInt8((n + 8) & 0xFF), 0, 0, id, 0]
            p += payload[offset..<offset + n]
            try stream.write(p)
            offset += n
            id &+= 1
        } while offset < payload.count
    }

    /// Reads one whole message (all packets up to end-of-message) for small replies.
    private func readMessage() throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let h = try stream.read(8)
            let length = Int(h[2]) << 8 | Int(h[3])
            out += try stream.read(length - 8)
            if h[1] & 0x01 != 0 { return out }
        }
    }

    // MARK: Pre-login & login

    private func prelogin(strict: Bool) throws {
        // VERSION, ENCRYPTION, THREADID, MARS, TERMINATOR
        let encryption: UInt8 = strict ? 0x00 : 0x02  // strict: already encrypted; else ENCRYPT_NOT_SUP
        let options: [(UInt8, [UInt8])] = [
            (0x00, [0x10, 0x00, 0x00, 0x00, 0x00, 0x00]),
            (0x01, [encryption]),
            (0x03, [0, 0, 0, 0]),
            (0x04, [0]),
        ]
        var header: [UInt8] = []
        var data: [UInt8] = []
        let base = options.count * 5 + 1
        for (token, value) in options {
            let offset = base + data.count
            header += [token, UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(value.count >> 8), UInt8(value.count & 0xFF)]
            data += value
        }
        try send(.prelogin, header + [0xFF] + data)
        let reply = try readMessage()
        // Find the server's ENCRYPTION option.
        var i = 0
        while i + 4 < reply.count, reply[i] != 0xFF {
            let token = reply[i], offset = Int(reply[i + 1]) << 8 | Int(reply[i + 2])
            if token == 0x01, offset < reply.count, !strict {
                let mode = reply[offset]
                if mode == 0x01 || mode == 0x03 {
                    throw DatabaseError("The server requires encryption. Set SSL mode to Require (TDS 8 strict, SQL Server 2022+ / Azure SQL).")
                }
            }
            i += 5
        }
    }

    private static func ucs2(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }

    private func login(host: String, user: String, password: String, database: String) throws {
        let fields: [[UInt8]] = [
            Self.ucs2(ProcessInfo.processInfo.hostName),  // HostName
            Self.ucs2(user),
            Self.ucs2(password).map { (($0 << 4) | ($0 >> 4)) ^ 0xA5 },  // Password (obfuscated)
            Self.ucs2("DBIDE"),  // AppName
            Self.ucs2(host),  // ServerName
            [],  // Extension
            Self.ucs2("DBIDE"),  // CltIntName
            [],  // Language
            Self.ucs2(database),  // Database
        ]
        let fixed = 94
        var w = ByteWriter()
        var offsets: [(Int, Int)] = []
        var dataOffset = fixed
        for f in fields {
            offsets.append((dataOffset, f.count / 2))
            dataOffset += f.count
        }
        let total = dataOffset
        w.intLE(UInt64(total), size: 4)
        w.intLE(0x7400_0004, size: 4)  // TDS 7.4
        w.intLE(UInt64(packetSize), size: 4)
        w.intLE(0x0700_0000, size: 4)  // client program version
        w.intLE(UInt64(ProcessInfo.processInfo.processIdentifier), size: 4)
        w.intLE(0, size: 4)  // connection id
        w.u8(0xE0)  // USE_DB_ON | INIT_DB_FATAL | SET_LANG_ON
        w.u8(0x03)  // INIT_LANG_FATAL | ODBC
        w.u8(0x00)  // type flags
        w.u8(0x00)  // option flags 3
        w.intLE(0, size: 4)  // time zone
        w.intLE(0x0409, size: 4)  // LCID
        for (i, (off, len)) in offsets.enumerated() {
            if i == 5 {  // Extension slot unused
                w.intLE(UInt64(off), size: 2)
                w.intLE(0, size: 2)
                continue
            }
            w.intLE(UInt64(off), size: 2)
            w.intLE(UInt64(len), size: 2)
        }
        w.append([0, 0, 0, 0, 0, 0])  // client MAC
        for _ in 0..<3 { w.intLE(UInt64(total), size: 2); w.intLE(0, size: 2) }  // SSPI, AtchDBFile, ChangePassword
        w.intLE(0, size: 4)  // SSPI long
        for f in fields { w.append(f) }
        try send(.login7, w.bytes)
        var r = TokenReader(connection: self, buffer: try readMessage())
        var loggedIn = false
        var failure: DatabaseError?
        while !r.atEnd {
            switch try r.u8() {
            case 0xAD:  // LOGINACK
                let len = Int(try r.u16())
                var ack = ByteReader(try r.take(len))
                try ack.skip(1 + 4)
                let nameLen = Int(try ack.u8())
                let name = String(decoding: try ack.take(nameLen * 2).chunked16(), as: UTF16.self)
                let major = try ack.u8(), minor = try ack.u8(), hi = try ack.u8(), lo = try ack.u8()
                serverVersion = "\(name.hasPrefix("Microsoft") ? "SQL Server" : name) \(major).\(minor).\(Int(hi) << 8 | Int(lo))"
                loggedIn = true
            case 0xAA:
                let e = try r.errorToken()
                failure = DatabaseError(e.message, code: e.code)
            case let t: try r.skipToken(t)
            }
        }
        if let failure { throw failure }
        guard loggedIn else { throw DatabaseError("SQL Server login failed") }
    }

    // MARK: Environment changes

    fileprivate func envChange(_ type: UInt8, _ newValue: [UInt8], _ oldValue: [UInt8]) {
        switch type {
        case 1: database = String(decoding: newValue.chunked16(), as: UTF16.self)
        case 4: if let n = Int(String(decoding: newValue.chunked16(), as: UTF16.self)) { packetSize = n }
        case 8:
            transactionDescriptor = newValue.count == 8 ? newValue : [UInt8](repeating: 0, count: 8)
            inTransaction = true
        case 9, 10, 17:
            transactionDescriptor = [UInt8](repeating: 0, count: 8)
            inTransaction = false
        default: break
        }
    }

    /// Reads the payload of the next packet of the current reply (streaming).
    fileprivate func nextPacket() throws -> (payload: [UInt8], last: Bool) {
        let h = try stream.read(8)
        let length = Int(h[2]) << 8 | Int(h[3])
        return (try stream.read(length - 8), h[1] & 0x01 != 0)
    }

    // MARK: Query

    public func execute(_ sql: String, maxRows: Int) async throws -> QueryResult {
        try await worker.run { [self] in try executeSync(sql, maxRows: maxRows) }
    }

    private func executeSync(_ sql: String, maxRows: Int) throws -> QueryResult {
        let start = Date()
        var payload = ByteWriter()
        payload.intLE(22, size: 4)  // ALL_HEADERS total length
        payload.intLE(18, size: 4)  // header length
        payload.intLE(2, size: 2)  // transaction descriptor header
        payload.append(transactionDescriptor)
        payload.intLE(1, size: 4)  // outstanding requests
        payload.append(Self.ucs2(sql))
        setRunning(true)
        defer { setRunning(false) }
        try send(.sqlBatch, payload.bytes)

        var r = TokenReader(connection: self, buffer: nil)
        var results: [QueryResult] = []
        var current: QueryResult?
        var columns: [TDSColumn] = []
        var failure: DatabaseError?
        var lastCount: Int?
        var cancelled = false
        while true {
            if r.atEnd { break }
            let token = try r.u8()
            switch token {
            case 0x81:  // COLMETADATA
                let count = Int(try r.u16())
                if count == 0xFFFF { continue }
                columns = try (0..<count).map { _ in try r.column() }
                current = QueryResult(statement: sql, columns: columns.map { ResultColumn(name: $0.name, typeName: $0.typeName) })
            case 0xD1, 0xD2:  // ROW, NBCROW
                var nulls: [UInt8] = []
                if token == 0xD2 { nulls = try r.take((columns.count + 7) / 8) }
                var row: [SQLValue] = []
                row.reserveCapacity(columns.count)
                for (i, c) in columns.enumerated() {
                    if token == 0xD2, nulls[i / 8] & (1 << (i % 8)) != 0 {
                        row.append(.null)
                    } else {
                        row.append(try r.value(c))
                    }
                }
                if current!.rows.count < maxRows { current!.rows.append(row) } else { current!.truncated = true }
            case 0xFD, 0xFE, 0xFF:  // DONE, DONEPROC, DONEINPROC
                let status = try r.u16()
                _ = try r.u16()
                let count = Int(try r.u64())
                if status & 0x20 != 0 { cancelled = true }
                if status & 0x10 != 0 { lastCount = count }
                if let res = current {
                    results.append(res)
                    current = nil
                    columns = []
                } else if token == 0xFD || token == 0xFF, status & 0x10 != 0 {
                    results.append(QueryResult(statement: sql, affectedRows: count))
                }
            case 0xAA:
                let e = try r.errorToken()
                if failure == nil { failure = Self.positioned(e, in: sql) }
            case let t:
                try r.skipToken(t)
            }
        }
        // After ATTENTION the server acknowledges with DONE(ATTN), possibly in a following message.
        if takeAttention() {
            while !cancelled {
                var a = TokenReader(connection: self, buffer: nil)
                while !a.atEnd {
                    let t = try a.u8()
                    if t == 0xFD || t == 0xFE || t == 0xFF {
                        let status = try a.u16()
                        try a.skip(10)
                        if status & 0x20 != 0 { cancelled = true }
                    } else if t == 0x81 || t == 0xD1 || t == 0xD2 {
                        break  // rows of the interrupted batch: the ack follows in the next message
                    } else {
                        try a.skipToken(t)
                    }
                }
            }
        }
        if cancelled { throw DatabaseError("Query cancelled") }
        if let failure { throw failure }
        var res = results.last(where: { $0.hasResultSet }) ?? results.last ?? QueryResult(statement: sql)
        if !res.hasResultSet {
            res.affectedRows = res.affectedRows ?? lastCount
            res.message = SQLLexer.leadingKeywords(sql, count: 2).uppercased()
        }
        res.duration = Date().timeIntervalSince(start)
        return res
    }

    /// Server errors report a line number; point at the start of that line.
    static func positioned(_ e: DatabaseError, in sql: String) -> DatabaseError {
        guard let line = e.position, line > 1 else { return DatabaseError(e.message, code: e.code, detail: e.detail, position: nil) }
        let ns = sql as NSString
        var offset = 0, current = 1
        while current < line, offset < ns.length {
            let r = ns.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(r)
            current += 1
        }
        return DatabaseError(e.message, code: e.code, detail: e.detail, position: offset < ns.length ? offset : nil)
    }

    private func takeAttention() -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        let v = attentionSent
        attentionSent = false
        return v
    }

    private func setRunning(_ v: Bool) {
        writeLock.lock()
        running = v
        writeLock.unlock()
    }

    /// Sends an ATTENTION packet; the server ends the batch with DONE_ATTN.
    public func cancel() {
        writeLock.lock()
        let isRunning = running
        writeLock.unlock()
        guard isRunning else { return }
        writeLock.lock()
        attentionSent = true
        writeLock.unlock()
        DispatchQueue.global().async { [self] in try? send(.attention, []) }
    }

    public func close() async {
        stream.close()
    }
}

// MARK: - Token stream

struct TDSColumn {
    var name: String
    var type: UInt8
    var length: Int
    var precision: UInt8 = 0
    var scale: UInt8 = 0
    var plp = false
    var collationUTF8 = false
    var typeName: String
}

/// Reads a TDS reply token stream across packets.
struct TokenReader {
    private let connection: SQLServerConnection?
    private var buffer: [UInt8]
    private var index = 0
    private var lastPacket: Bool
    private var finished = false

    init(connection: SQLServerConnection?, buffer: [UInt8]?) {
        self.connection = connection
        self.buffer = buffer ?? []
        lastPacket = buffer != nil
    }

    var messageComplete: Bool { lastPacket && index >= buffer.count }
    mutating func finish() { finished = true }

    var atEnd: Bool {
        mutating get {
            if finished { return true }
            if index < buffer.count { return false }
            if lastPacket { return true }
            return (try? fill(1)) == nil
        }
    }

    private mutating func fill(_ n: Int) throws {
        while buffer.count - index < n {
            guard !lastPacket, let c = connection else { throw DatabaseError("Truncated TDS message") }
            if index > 0 {
                buffer.removeFirst(index)
                index = 0
            }
            let (p, last) = try c.nextPacket()
            buffer += p
            lastPacket = last
        }
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        try fill(n)
        defer { index += n }
        return Array(buffer[index..<index + n])
    }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) | UInt16(b[1]) << 8 }
    mutating func u32() throws -> UInt32 { try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    mutating func u64() throws -> UInt64 { try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
    mutating func bVarchar() throws -> String { let n = Int(try u8()); return String(decoding: try take(n * 2).chunked16(), as: UTF16.self) }
    mutating func usVarchar() throws -> String { let n = Int(try u16()); return String(decoding: try take(n * 2).chunked16(), as: UTF16.self) }

    mutating func skipToken(_ t: UInt8) throws {
        switch t {
        case 0xE3:  // ENVCHANGE
            let len = Int(try u16())
            var r = ByteReader(try take(len))
            let type = try r.u8()
            func value() throws -> [UInt8] {
                if [7, 8, 9, 10, 11, 12, 15, 16, 17, 19].contains(type) {
                    let n = Int(try r.u8())
                    return try r.take(n)
                }
                let n = Int(try r.u8())
                return try r.take(n * 2)
            }
            if type != 20, let new = try? value(), let old = try? value() { connection?.envChange(type, new, old) }
        case 0xAB, 0xAD, 0xA9, 0xA5, 0xA4, 0xED:  // INFO, LOGINACK, ORDER, COLINFO, TABNAME, SSPI
            try skip(Int(try u16()))
        case 0x79: try skip(4)  // RETURNSTATUS
        case 0xFD, 0xFE, 0xFF: try skip(12)  // DONE*
        case 0xE4: try skip(Int(try u32()))  // SESSIONSTATE
        case 0xAE:  // FEATUREEXTACK
            while try u8() != 0xFF { try skip(Int(try u32())) }
        default:
            throw DatabaseError("Unsupported TDS token 0x\(String(t, radix: 16))")
        }
    }

    mutating func skip(_ n: Int) throws { _ = try take(n) }

    mutating func errorToken() throws -> DatabaseError {
        _ = try u16()
        let number = try u32()
        let state = try u8()
        let severity = try u8()
        let message = try usVarchar()
        _ = try bVarchar()  // server
        _ = try bVarchar()  // procedure
        let line = Int(try u32())
        return DatabaseError(message, code: "\(number)/\(state) severity \(severity)", position: line)
    }

    // MARK: Metadata

    mutating func column() throws -> TDSColumn {
        _ = try u32()  // user type
        _ = try u16()  // flags
        var c = try typeInfo()
        if [0x22, 0x23, 0x63].contains(c.type) {  // text / ntext / image: table name parts
            let parts = Int(try u8())
            for _ in 0..<parts { _ = try usVarchar() }
        }
        c.name = try bVarchar()
        return c
    }

    mutating func typeInfo() throws -> TDSColumn {
        let t = try u8()
        var c = TDSColumn(name: "", type: t, length: 0, typeName: TDSTypes.name(t))
        switch t {
        case 0x1F, 0x30, 0x32, 0x34, 0x38, 0x7F, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x7A:
            c.length = TDSTypes.fixedLength(t)
        case 0x24, 0x26, 0x68, 0x6D, 0x6E, 0x6F:
            c.length = Int(try u8())
            c.typeName = TDSTypes.nullableName(t, c.length)
        case 0x6A, 0x6C:
            c.length = Int(try u8())
            c.precision = try u8()
            c.scale = try u8()
            c.typeName += "(\(c.precision),\(c.scale))"
        case 0x28: break
        case 0x29, 0x2A, 0x2B:
            c.scale = try u8()
        case 0xA7, 0xAF, 0xE7, 0xEF:
            c.length = Int(try u16())
            let collation = try take(5)
            c.collationUTF8 = collation[3] & 0x04 != 0  // UTF-8 collations (SQL Server 2019+)
            c.plp = c.length == 0xFFFF
            let chars = t == 0xE7 || t == 0xEF ? c.length / 2 : c.length
            c.typeName += c.plp ? "(max)" : "(\(chars))"
        case 0xA5, 0xAD:
            c.length = Int(try u16())
            c.plp = c.length == 0xFFFF
            c.typeName += c.plp ? "(max)" : "(\(c.length))"
        case 0x22, 0x23, 0x63:
            c.length = Int(try u32())
            if t != 0x22 { _ = try take(5) }
        case 0xF1:  // XML
            if try u8() != 0 { _ = try bVarchar(); _ = try bVarchar(); _ = try usVarchar() }
            c.plp = true
        case 0x62: c.length = Int(try u32())  // sql_variant
        case 0xF0:  // UDT
            c.length = Int(try u16())
            _ = try bVarchar(); _ = try bVarchar(); c.typeName = try bVarchar(); _ = try usVarchar()
            c.plp = true
        default:
            throw DatabaseError("Unsupported SQL Server type 0x\(String(t, radix: 16))")
        }
        return c
    }

    // MARK: Values

    mutating func plpBytes() throws -> [UInt8]? {
        let total = try u64()
        if total == UInt64.max { return nil }
        var out: [UInt8] = []
        while true {
            let n = Int(try u32())
            if n == 0 { return out }
            out += try take(n)
        }
    }

    mutating func value(_ c: TDSColumn) throws -> SQLValue {
        let t = c.type
        // Fixed-length types.
        if TDSTypes.fixedLength(t) > 0 || t == 0x1F {
            return TDSTypes.decode(t, try take(c.length), c)
        }
        switch t {
        case 0x24, 0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x6A, 0x6C, 0x28, 0x29, 0x2A, 0x2B:
            let n = Int(try u8())
            return n == 0 ? .null : TDSTypes.decode(t, try take(n), c)
        case 0xA7, 0xAF, 0xE7, 0xEF, 0xA5, 0xAD:
            if c.plp { return try plpBytes().map { TDSTypes.decode(t, $0, c) } ?? .null }
            let n = Int(try u16())
            return n == 0xFFFF ? .null : TDSTypes.decode(t, try take(n), c)
        case 0x22, 0x23, 0x63:
            let ptr = Int(try u8())
            if ptr == 0 { return .null }
            _ = try take(ptr + 8)
            let n = Int(try u32())
            return TDSTypes.decode(t, try take(n), c)
        case 0xF1, 0xF0:
            return try plpBytes().map { TDSTypes.decode(t == 0xF1 ? 0xE7 : 0xA5, $0, c) } ?? .null
        case 0x62:
            let n = Int(try u32())
            if n == 0 { return .null }
            var r = ByteReader(try take(n))
            let base = try r.u8()
            let props = Int(try r.u8())
            var inner = TDSColumn(name: "", type: base, length: n - 2 - props, typeName: TDSTypes.name(base))
            if base == 0x6A || base == 0x6C, props >= 2 { inner.precision = try r.u8(); inner.scale = try r.u8() }
            else if [0x29, 0x2A, 0x2B].contains(base), props >= 1 { inner.scale = try r.u8() }
            else { try r.skip(props) }
            return TDSTypes.decode(base, r.rest(), inner)
        default:
            throw DatabaseError("Unsupported SQL Server value type 0x\(String(t, radix: 16))")
        }
    }
}

enum TDSTypes {
    static func fixedLength(_ t: UInt8) -> Int {
        switch t {
        case 0x30, 0x32: 1
        case 0x34: 2
        case 0x38, 0x3A, 0x3B, 0x7A: 4
        case 0x7F, 0x3C, 0x3D, 0x3E: 8
        default: 0
        }
    }

    static func name(_ t: UInt8) -> String {
        switch t {
        case 0x30: "tinyint"
        case 0x32, 0x68: "bit"
        case 0x34: "smallint"
        case 0x38, 0x26: "int"
        case 0x7F: "bigint"
        case 0x3B: "real"
        case 0x3E, 0x6D: "float"
        case 0x3C, 0x6E: "money"
        case 0x7A: "smallmoney"
        case 0x3A: "smalldatetime"
        case 0x3D, 0x6F: "datetime"
        case 0x6A: "decimal"
        case 0x6C: "numeric"
        case 0x24: "uniqueidentifier"
        case 0x28: "date"
        case 0x29: "time"
        case 0x2A: "datetime2"
        case 0x2B: "datetimeoffset"
        case 0xA7: "varchar"
        case 0xAF: "char"
        case 0xE7: "nvarchar"
        case 0xEF: "nchar"
        case 0xA5: "varbinary"
        case 0xAD: "binary"
        case 0x23: "text"
        case 0x63: "ntext"
        case 0x22: "image"
        case 0xF1: "xml"
        case 0x62: "sql_variant"
        case 0x1F: "null"
        default: "type 0x\(String(t, radix: 16))"
        }
    }

    static func nullableName(_ t: UInt8, _ len: Int) -> String {
        switch (t, len) {
        case (0x26, 1): "tinyint"
        case (0x26, 2): "smallint"
        case (0x26, 8): "bigint"
        case (0x6D, 4): "real"
        case (0x6E, 4): "smallmoney"
        case (0x6F, 4): "smalldatetime"
        default: name(t)
        }
    }

    static func le(_ b: [UInt8]) -> UInt64 { b.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }

    static func signed(_ b: [UInt8]) -> Int64 {
        let u = le(b)
        let bits = b.count * 8
        if bits < 64, u & (1 << UInt64(bits - 1)) != 0 { return Int64(bitPattern: u | ~((1 << UInt64(bits)) - 1)) }
        return Int64(bitPattern: u)
    }

    static func decode(_ t: UInt8, _ b: [UInt8], _ c: TDSColumn) -> SQLValue {
        switch t {
        case 0x1F: return .null
        case 0x30: return .integer(Int64(b[0]))
        case 0x32, 0x68: return .text(b.first == 1 ? "true" : "false")
        case 0x34, 0x38, 0x7F, 0x26: return .integer(b.count == 1 ? Int64(b[0]) : signed(b))
        case 0x3B: return .real(Double(Float(bitPattern: UInt32(le(b)))))
        case 0x3E: return .real(Double(bitPattern: le(b)))
        case 0x6D: return b.count == 4 ? .real(Double(Float(bitPattern: UInt32(le(b))))) : .real(Double(bitPattern: le(b)))
        case 0x3C, 0x6E, 0x7A:
            let v: Int64 = b.count == 4 ? signed(b) : (Int64(Int32(bitPattern: UInt32(le(Array(b[0..<4]))))) << 32) | Int64(le(Array(b[4..<8])))
            return .text(decimalString(magnitude: v.magnitude, negative: v < 0, scale: 4))
        case 0x6A, 0x6C:
            let negative = b[0] == 0
            var mag = Array(b.dropFirst())
            while mag.count > 1, mag.last == 0 { mag.removeLast() }
            if mag.count <= 8 { return .text(decimalString(magnitude: le(mag), negative: negative, scale: Int(c.scale))) }
            // 128-bit magnitude: long division by 10
            var words = stride(from: 0, to: mag.count, by: 4).map { i in UInt32(le(Array(mag[i..<min(i + 4, mag.count)]))) }
            var digits = ""
            while words.contains(where: { $0 != 0 }) {
                var rem: UInt64 = 0
                for i in stride(from: words.count - 1, through: 0, by: -1) {
                    let cur = rem << 32 | UInt64(words[i])
                    words[i] = UInt32(cur / 10)
                    rem = cur % 10
                }
                digits = String(rem) + digits
            }
            return .text(insertPoint(digits.isEmpty ? "0" : digits, negative: negative, scale: Int(c.scale)))
        case 0x3D, 0x6F, 0x3A:
            if b.count == 4 {
                let days = Int(le(Array(b[0..<2]))), minutes = Int(le(Array(b[2..<4])))
                return .text(format(days: days, from1900: true, seconds: Double(minutes * 60), scale: 0))
            }
            let days = Int(Int32(bitPattern: UInt32(le(Array(b[0..<4])))))
            let ticks = Double(le(Array(b[4..<8])))  // 1/300 s
            return .text(format(days: days, from1900: true, seconds: ticks / 300, scale: 3))
        case 0x28: return .text(format(days: Int(le(b)), from1900: false, seconds: nil, scale: 0))
        case 0x29, 0x2A, 0x2B:
            let timeLen = c.scale <= 2 ? 3 : c.scale <= 4 ? 4 : 5
            let units = Double(le(Array(b[0..<min(timeLen, b.count)])))
            let seconds = units / pow(10, Double(c.scale))
            if t == 0x29 { return .text(timeString(seconds, scale: Int(c.scale))) }
            let days = Int(le(Array(b[timeLen..<timeLen + 3])))
            var s = format(days: days, from1900: false, seconds: seconds, scale: Int(c.scale))
            if t == 0x2B {
                let offset = Int(Int16(bitPattern: UInt16(le(Array(b[(timeLen + 3)..<(timeLen + 5)])))))
                s += String(format: " %@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60) + " (UTC time)"
            }
            return .text(s)
        case 0x24:
            guard b.count == 16 else { return .blob(Data(b)) }
            let order = [3, 2, 1, 0, -1, 5, 4, -1, 7, 6, -1, 8, 9, -1, 10, 11, 12, 13, 14, 15]
            return .text(order.map { $0 < 0 ? "-" : String(format: "%02X", b[$0]) }.joined())
        case 0xE7, 0xEF, 0x63:
            return .text(String(decoding: b.chunked16(), as: UTF16.self))
        case 0xA7, 0xAF, 0x23:
            if c.collationUTF8 { return .text(String(decoding: b, as: UTF8.self)) }
            return .text(String(data: Data(b), encoding: .windowsCP1252) ?? String(decoding: b, as: UTF8.self))
        default:
            return .blob(Data(b))
        }
    }

    static func decimalString(magnitude: UInt64, negative: Bool, scale: Int) -> String {
        insertPoint(String(magnitude), negative: negative, scale: scale)
    }

    static func insertPoint(_ digits: String, negative: Bool, scale: Int) -> String {
        var d = digits
        if scale > 0 {
            if d.count <= scale { d = String(repeating: "0", count: scale - d.count + 1) + d }
            d.insert(".", at: d.index(d.endIndex, offsetBy: -scale))
        }
        return (negative && d.contains(where: { $0 != "0" && $0 != "." }) ? "-" : "") + d
    }

    static func timeString(_ seconds: Double, scale: Int) -> String {
        let whole = Int(seconds)
        var s = String(format: "%02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
        if scale > 0 {
            let frac = seconds - Double(whole)
            s += "." + String(format: "%0\(scale)d", Int((frac * pow(10, Double(scale))).rounded()))
        }
        return s
    }

    /// Days since 1900-01-01 (datetime) or 0001-01-01 (date / datetime2, proleptic Gregorian).
    static func format(days: Int, from1900: Bool, seconds: Double?, scale: Int) -> String {
        // Day 0 of each epoch counted in days relative to 1970-01-01 (avoids Foundation's Julian switch).
        let unixDays = days - (from1900 ? 25567 : 719_162)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var s: String
        if unixDays >= -141_427 {  // on/after 1582-10-15: Foundation's Gregorian is correct
            let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(unixDays) * 86_400))
            s = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        } else {
            s = civilDate(fromUnixDays: unixDays)
        }
        if let seconds { s += " " + timeString(seconds, scale: scale) }
        return s
    }

    /// Proleptic Gregorian date for a day count relative to 1970-01-01 (Howard Hinnant's algorithm).
    static func civilDate(fromUnixDays z0: Int) -> String {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

extension Array where Element == UInt8 {
    /// Little-endian UTF-16 code units.
    func chunked16() -> [UInt16] {
        stride(from: 0, to: count - 1, by: 2).map { UInt16(self[$0]) | UInt16(self[$0 + 1]) << 8 }
    }
}
