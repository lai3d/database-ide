import Foundation

/// Server-side paging with the extended query protocol: Parse / Bind / Execute(n) followed by
/// Flush (not Sync) leaves the unnamed portal suspended, so later Executes fetch more rows.
extension PostgresConnection: CursorCapable {
    public var hasOpenCursor: Bool { portalKinds != nil }

    public func openCursor(_ sql: String, pageSize: Int) async throws -> QueryResult {
        try await worker.run { [self] in
            try closePortalSync()
            let start = Date()
            var parse = ByteWriter()
            parse.cString("")
            parse.cString(sql)
            parse.int16BE(0)
            try send(UInt8(ascii: "P"), parse.bytes)
            var bind = ByteWriter()
            bind.cString("")  // portal
            bind.cString("")  // statement
            bind.int16BE(0)  // parameter formats
            bind.int16BE(0)  // parameters
            bind.int16BE(1)
            bind.int16BE(0)  // all results as text
            try send(UInt8(ascii: "B"), bind.bytes)
            try send(UInt8(ascii: "D"), [UInt8(ascii: "P"), 0])
            try sendExecute(pageSize)

            var result = QueryResult(statement: sql)
            var kinds: [PGTypeKind] = []
            while true {
                let (type, body) = try receive()
                var r = body
                switch type {
                case UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "n"), UInt8(ascii: "N"), UInt8(ascii: "S"):
                    continue
                case UInt8(ascii: "T"):
                    let n = Int(try r.int16BE())
                    for _ in 0..<n {
                        let name = try r.cString()
                        try r.skip(6)
                        let oid = UInt32(bitPattern: try r.int32BE())
                        try r.skip(8)
                        result.columns.append(ResultColumn(name: name, typeName: PGTypes.name(oid)))
                        kinds.append(PGTypes.kind(oid))
                    }
                case UInt8(ascii: "D"):
                    result.rows.append(try Self.decodeRow(&r, kinds))
                case UInt8(ascii: "s"):  // PortalSuspended: more rows remain
                    portalKinds = kinds
                    result.truncated = true
                    result.duration = Date().timeIntervalSince(start)
                    return result
                case UInt8(ascii: "C"):
                    let tag = try r.cString()
                    try syncSync()
                    if !result.hasResultSet { result.message = tag }
                    result.duration = Date().timeIntervalSince(start)
                    return result
                case UInt8(ascii: "E"):
                    let error = Self.parseError(body)
                    try syncSync()
                    throw error
                default:
                    continue
                }
            }
        }
    }

    public func fetchMore(_ count: Int) async throws -> (rows: [[SQLValue]], hasMore: Bool) {
        try await worker.run { [self] in
            guard let kinds = portalKinds else { return ([], false) }
            try sendExecute(count)
            var rows: [[SQLValue]] = []
            while true {
                let (type, body) = try receive()
                var r = body
                switch type {
                case UInt8(ascii: "D"): rows.append(try Self.decodeRow(&r, kinds))
                case UInt8(ascii: "s"): return (rows, true)
                case UInt8(ascii: "C"):
                    portalKinds = nil
                    try syncSync()
                    return (rows, false)
                case UInt8(ascii: "E"):
                    portalKinds = nil
                    let error = Self.parseError(body)
                    try syncSync()
                    throw error
                default: continue
                }
            }
        }
    }

    public func closeCursor() async {
        _ = try? await worker.run { [self] in try closePortalSync() }
    }

    // MARK: Helpers (run on the worker)

    func closePortalSync() throws {
        guard portalKinds != nil else { return }
        portalKinds = nil
        try send(UInt8(ascii: "C"), [UInt8(ascii: "P"), 0])  // Close portal ""
        try syncSync()
    }

    private func sendExecute(_ maxRows: Int) throws {
        var w = ByteWriter()
        w.cString("")
        w.int32BE(Int32(clamping: max(1, maxRows)))
        try send(UInt8(ascii: "E"), w.bytes)
        try send(UInt8(ascii: "H"), [])  // Flush: keep the portal open
    }

    /// Sends Sync and reads up to ReadyForQuery (ending the implicit transaction).
    private func syncSync() throws {
        try send(UInt8(ascii: "S"), [])
        while true {
            let (type, _) = try receive()
            if type == UInt8(ascii: "Z") { return }
        }
    }

    private static func decodeRow(_ r: inout ByteReader, _ kinds: [PGTypeKind]) throws -> [SQLValue] {
        let n = Int(try r.int16BE())
        var row: [SQLValue] = []
        row.reserveCapacity(n)
        for i in 0..<n {
            let len = Int(try r.int32BE())
            row.append(len < 0 ? .null : PGTypes.decode(try r.take(len), kind: i < kinds.count ? kinds[i] : .text))
        }
        return row
    }
}
