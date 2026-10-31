import Foundation

/// Little helper for building wire-protocol messages.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func append(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
    mutating func cString(_ s: String) {
        append(s)
        bytes.append(0)
    }
    mutating func int16BE(_ v: Int) { bytes += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func int32BE(_ v: Int32) {
        let u = UInt32(bitPattern: v)
        bytes += [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }
    mutating func intLE(_ v: UInt64, size: Int) {
        for i in 0..<size { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) }
    }
    /// MySQL length-encoded integer.
    mutating func lenencInt(_ v: UInt64) {
        switch v {
        case ..<251: u8(UInt8(v))
        case ..<(1 << 16): u8(0xFC); intLE(v, size: 2)
        case ..<(1 << 24): u8(0xFD); intLE(v, size: 3)
        default: u8(0xFE); intLE(v, size: 8)
        }
    }
}

struct ProtocolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Cursor over a received message payload.
struct ByteReader {
    let bytes: [UInt8]
    var index: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - index }
    var atEnd: Bool { index >= bytes.count }

    private func need(_ n: Int) throws {
        if n < 0 || index + n > bytes.count { throw DatabaseError("Malformed server message (truncated)") }
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { index += 1 }
        return bytes[index]
    }
    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func take(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { index += n }
        return Array(bytes[index..<index + n])
    }
    mutating func skip(_ n: Int) throws {
        try need(n)
        index += n
    }
    mutating func rest() -> [UInt8] {
        defer { index = bytes.count }
        return Array(bytes[min(index, bytes.count)...])
    }

    mutating func int16BE() throws -> Int16 {
        let b = try take(2)
        return Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
    }
    mutating func int32BE() throws -> Int32 {
        let b = try take(4)
        return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }
    mutating func uintLE(_ size: Int) throws -> UInt64 {
        let b = try take(size)
        var v: UInt64 = 0
        for (i, byte) in b.enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
        return v
    }
    /// NUL-terminated string (terminator consumed). A missing terminator reads to the end.
    mutating func cString() throws -> String {
        let start = index
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        let s = String(decoding: bytes[start..<index], as: UTF8.self)
        if index < bytes.count { index += 1 }
        return s
    }
    /// MySQL length-encoded integer; returns nil for the NULL marker 0xFB.
    mutating func lenencInt() throws -> UInt64? {
        let first = try u8()
        switch first {
        case 0xFB: return nil
        case 0xFC: return try uintLE(2)
        case 0xFD: return try uintLE(3)
        case 0xFE: return try uintLE(8)
        default: return UInt64(first)
        }
    }
    mutating func lenencBytes() throws -> [UInt8]? {
        guard let n = try lenencInt() else { return nil }
        return try take(Int(n))
    }
    mutating func lenencString() throws -> String? {
        try lenencBytes().map { String(decoding: $0, as: UTF8.self) }
    }
}
