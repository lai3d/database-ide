import Foundation

/// 12-byte MongoDB ObjectId.
public struct ObjectID: Sendable, Hashable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }

    public init?(hex: String) {
        guard hex.count == 24 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        bytes = out
    }

    /// A new id: 4-byte timestamp + 5 random bytes + 3-byte counter.
    public static func generate() -> ObjectID {
        let t = UInt32(Date().timeIntervalSince1970)
        var b = [UInt8(t >> 24), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
        b += (0..<8).map { _ in UInt8.random(in: 0...255) }
        return ObjectID(bytes: b)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { "ObjectId('\(hex)')" }
}

/// Decimal128 kept as its 16 raw bytes, with string conversion.
public struct Decimal128: Sendable, Hashable, CustomStringConvertible {
    public var low: UInt64
    public var high: UInt64

    public init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        var negative = false
        if s.first == "-" || s.first == "+" {
            negative = s.first == "-"
            s = s.dropFirst()
        }
        var exponent = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let x = Int(s[s.index(after: e)...]) else { return nil }
            exponent = x
            s = s[..<e]
        }
        var digits = ""
        var seenPoint = false
        for c in s {
            if c == "." {
                if seenPoint { return nil }
                seenPoint = true
            } else if c.isASCII, c.isNumber {
                digits.append(c)
                if seenPoint { exponent -= 1 }
            } else {
                return nil
            }
        }
        guard !digits.isEmpty, digits.count <= 34 else { return nil }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for d in digits.utf8 {
            // (hi, lo) = (hi, lo) * 10 + d
            let (l10, lo_over) = lo.multipliedFullWidth(by: 10)
            hi = hi &* 10 &+ l10
            lo = lo_over
            let (sum, carry) = lo.addingReportingOverflow(UInt64(d - 48))
            lo = sum
            if carry { hi &+= 1 }
        }
        let biased = exponent + 6176
        guard (0...12287).contains(biased) else { return nil }
        high = (negative ? 1 << 63 : 0) | (UInt64(biased) << 49) | (hi & 0x1_FFFF_FFFF_FFFF)
        low = lo
    }

    public var description: String {
        let negative = high >> 63 == 1
        let combination = (high >> 58) & 0x1F
        if combination == 0x1F { return "NaN" }
        if combination == 0x1E { return negative ? "-Infinity" : "Infinity" }
        let exponent = Int((high >> 49) & 0x3FFF) - 6176
        var hi = high & 0x1_FFFF_FFFF_FFFF
        var lo = low
        var digits: [Character] = []
        repeat {
            // divide (hi, lo) by 10
            let qHi = hi / 10
            let rHi = hi % 10
            let (qLo, rLo) = (10 as UInt64).dividingFullWidth((rHi, lo))
            hi = qHi
            lo = qLo
            digits.insert(Character(String(rLo)), at: 0)
        } while hi != 0 || lo != 0
        var s = String(digits)
        if exponent < 0 {
            let point = s.count + exponent
            if point > 0 {
                s.insert(".", at: s.index(s.startIndex, offsetBy: point))
            } else {
                s = "0." + String(repeating: "0", count: -point) + s
            }
        } else if exponent > 0 {
            s += "E+\(exponent)"
        }
        return (negative ? "-" : "") + s
    }
}

public indirect enum BSONValue: Sendable, Hashable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(subtype: UInt8, Data)
    case undefined
    case objectId(ObjectID)
    case bool(Bool)
    /// Milliseconds since the Unix epoch.
    case date(Int64)
    case null
    case regex(pattern: String, options: String)
    case javascript(String)
    case int32(Int32)
    case timestamp(UInt64)
    case int64(Int64)
    case decimal128(Decimal128)
    case minKey
    case maxKey

    public var document: BSONDocument? { if case .document(let d) = self { d } else { nil } }
    public var array: [BSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }

    /// Numeric value as Int64 when it is an integer type (or an integral double).
    public var int: Int64? {
        switch self {
        case .int32(let v): Int64(v)
        case .int64(let v): v
        case .double(let v) where v.rounded() == v && abs(v) < 9e18: Int64(v)
        default: nil
        }
    }

    public var typeName: String {
        switch self {
        case .double: "double"
        case .string: "string"
        case .document: "object"
        case .array: "array"
        case .binary: "binData"
        case .undefined: "undefined"
        case .objectId: "objectId"
        case .bool: "bool"
        case .date: "date"
        case .null: "null"
        case .regex: "regex"
        case .javascript: "javascript"
        case .int32: "int"
        case .timestamp: "timestamp"
        case .int64: "long"
        case .decimal128: "decimal"
        case .minKey: "minKey"
        case .maxKey: "maxKey"
        }
    }
}

/// An ordered BSON document (key order matters to MongoDB commands).
public struct BSONDocument: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    public struct Element: Sendable, Hashable {
        public var key: String
        public var value: BSONValue
    }

    public var elements: [Element]

    public init() { elements = [] }
    public init(_ pairs: [(String, BSONValue)]) { elements = pairs.map { Element(key: $0.0, value: $0.1) } }
    public init(dictionaryLiteral pairs: (String, BSONValue)...) { self.init(pairs) }

    public var keys: [String] { elements.map(\.key) }
    public var isEmpty: Bool { elements.isEmpty }

    public subscript(key: String) -> BSONValue? {
        get { elements.first { $0.key == key }?.value }
        set {
            if let i = elements.firstIndex(where: { $0.key == key }) {
                if let newValue { elements[i].value = newValue } else { elements.remove(at: i) }
            } else if let newValue {
                elements.append(Element(key: key, value: newValue))
            }
        }
    }
}

// MARK: - Encoding

public enum BSON {
    public static func encode(_ doc: BSONDocument) -> [UInt8] {
        var body: [UInt8] = []
        for e in doc.elements { appendElement(&body, e.key, e.value) }
        body.append(0)
        return int32LE(Int32(body.count + 4)) + body
    }

    private static func int32LE(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
    }

    private static func int64LE(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    private static func cString(_ s: String) -> [UInt8] { Array(s.utf8).filter { $0 != 0 } + [0] }

    private static func appendElement(_ out: inout [UInt8], _ key: String, _ value: BSONValue) {
        func head(_ type: UInt8) {
            out.append(type)
            out += cString(key)
        }
        switch value {
        case .double(let d): head(0x01); out += int64LE(d.bitPattern)
        case .string(let s), .javascript(let s):
            head(value == .javascript(s) ? 0x0D : 0x02)
            let bytes = Array(s.utf8)
            out += int32LE(Int32(bytes.count + 1)) + bytes + [0]
        case .document(let d): head(0x03); out += encode(d)
        case .array(let a):
            head(0x04)
            out += encode(BSONDocument(a.enumerated().map { (String($0.offset), $0.element) }))
        case .binary(let subtype, let data):
            head(0x05)
            out += int32LE(Int32(data.count)) + [subtype] + [UInt8](data)
        case .undefined: head(0x06)
        case .objectId(let id): head(0x07); out += id.bytes
        case .bool(let b): head(0x08); out.append(b ? 1 : 0)
        case .date(let ms): head(0x09); out += int64LE(UInt64(bitPattern: ms))
        case .null: head(0x0A)
        case .regex(let p, let o): head(0x0B); out += cString(p) + cString(String(o.sorted()))
        case .int32(let v): head(0x10); out += int32LE(v)
        case .timestamp(let v): head(0x11); out += int64LE(v)
        case .int64(let v): head(0x12); out += int64LE(UInt64(bitPattern: v))
        case .decimal128(let d): head(0x13); out += int64LE(d.low) + int64LE(d.high)
        case .minKey: head(0xFF)
        case .maxKey: head(0x7F)
        }
    }

    // MARK: Decoding

    public static func decode(_ bytes: [UInt8]) throws -> BSONDocument {
        var r = ByteReader(bytes)
        return try readDocument(&r)
    }

    static func readDocument(_ r: inout ByteReader) throws -> BSONDocument {
        let start = r.index
        let length = Int(Int32(bitPattern: UInt32(try r.uintLE(4))))
        guard length >= 5, start + length <= r.bytes.count else { throw DatabaseError("Malformed BSON document") }
        let end = start + length - 1
        var doc = BSONDocument()
        while r.index < end {
            let type = try r.u8()
            let key = try r.cString()
            doc.elements.append(.init(key: key, value: try readValue(type, &r)))
        }
        guard try r.u8() == 0 else { throw DatabaseError("Malformed BSON document (terminator)") }
        return doc
    }

    private static func readValue(_ type: UInt8, _ r: inout ByteReader) throws -> BSONValue {
        switch type {
        case 0x01: return .double(Double(bitPattern: try r.uintLE(8)))
        case 0x02, 0x0D, 0x0E:
            let n = Int(Int32(bitPattern: UInt32(try r.uintLE(4))))
            guard n >= 1 else { throw DatabaseError("Malformed BSON string") }
            let s = String(decoding: try r.take(n - 1), as: UTF8.self)
            try r.skip(1)
            return type == 0x0D ? .javascript(s) : .string(s)
        case 0x03: return .document(try readDocument(&r))
        case 0x04: return .array(try readDocument(&r).elements.map(\.value))
        case 0x05:
            let n = Int(Int32(bitPattern: UInt32(try r.uintLE(4))))
            let subtype = try r.u8()
            return .binary(subtype: subtype, Data(try r.take(n)))
        case 0x06: return .undefined
        case 0x07: return .objectId(ObjectID(bytes: try r.take(12)))
        case 0x08: return .bool(try r.u8() != 0)
        case 0x09: return .date(Int64(bitPattern: try r.uintLE(8)))
        case 0x0A: return .null
        case 0x0B:
            let p = try r.cString()
            return .regex(pattern: p, options: try r.cString())
        case 0x0C:  // DBPointer (deprecated)
            let n = Int(Int32(bitPattern: UInt32(try r.uintLE(4))))
            try r.skip(n + 12)
            return .undefined
        case 0x0F:  // code with scope (deprecated)
            let n = Int(Int32(bitPattern: UInt32(try r.uintLE(4))))
            try r.skip(n - 4)
            return .javascript("<code with scope>")
        case 0x10: return .int32(Int32(bitPattern: UInt32(try r.uintLE(4))))
        case 0x11: return .timestamp(try r.uintLE(8))
        case 0x12: return .int64(Int64(bitPattern: try r.uintLE(8)))
        case 0x13:
            let low = try r.uintLE(8)
            return .decimal128(Decimal128(low: low, high: try r.uintLE(8)))
        case 0xFF: return .minKey
        case 0x7F: return .maxKey
        default: throw DatabaseError("Unsupported BSON type 0x\(String(type, radix: 16))")
        }
    }
}

// MARK: - Shell-style text (mongosh notation)

extension BSONValue {
    /// One-line mongosh-style rendering, e.g. `{ _id: ObjectId('…'), n: 1 }`.
    public var shellString: String { BSONFormatter.format(self, indent: nil) }

    /// Multi-line rendering with two-space indentation.
    public var prettyString: String { BSONFormatter.format(self, indent: "") }
}

extension BSONDocument {
    public var shellString: String { BSONValue.document(self).shellString }
    public var prettyString: String { BSONValue.document(self).prettyString }
}

enum BSONFormatter {
    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func dateString(_ ms: Int64) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func key(_ k: String) -> String {
        let simple = !k.isEmpty && k.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "$" }
            && !(k.first?.isNumber ?? false)
        return simple ? k : quote(k)
    }

    static func quote(_ s: String) -> String {
        var out = "'"
        for c in s.unicodeScalars {
            switch c {
            case "'": out += "\\'"
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "'"
    }

    static func number(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d.rounded() == d && abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    static func format(_ v: BSONValue, indent: String?) -> String {
        switch v {
        case .double(let d):
            let n = number(d)
            // Keep integral doubles distinguishable from ints when the text is parsed back.
            return d.isFinite && !n.contains(".") && !n.contains("e") ? n + ".0" : n
        case .string(let s): return quote(s)
        case .document(let doc):
            if doc.isEmpty { return "{}" }
            if let indent {
                let inner = indent + "  "
                let lines = doc.elements.map { "\(inner)\(key($0.key)): \(format($0.value, indent: inner))" }
                return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
            }
            return "{ " + doc.elements.map { "\(key($0.key)): \(format($0.value, indent: nil))" }.joined(separator: ", ") + " }"
        case .array(let a):
            if a.isEmpty { return "[]" }
            if let indent, a.contains(where: { $0.document != nil || $0.array != nil }) {
                let inner = indent + "  "
                return "[\n" + a.map { inner + format($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
            }
            return "[ " + a.map { format($0, indent: nil) }.joined(separator: ", ") + " ]"
        case .binary(let subtype, let data):
            if subtype == 4, data.count == 16 {
                let h = data.map { String(format: "%02x", $0) }.joined()
                let parts = [h.prefix(8), h.dropFirst(8).prefix(4), h.dropFirst(12).prefix(4), h.dropFirst(16).prefix(4), h.dropFirst(20)]
                return "UUID('\(parts.joined(separator: "-"))')"
            }
            return "Binary.createFromBase64('\(data.base64EncodedString())', \(subtype))"
        case .undefined: return "undefined"
        case .objectId(let id): return id.description
        case .bool(let b): return b ? "true" : "false"
        case .date(let ms): return "ISODate('\(dateString(ms))')"
        case .null: return "null"
        case .regex(let p, let o): return "/\(p)/\(o)"
        case .javascript(let s): return "Code(\(quote(s)))"
        case .int32(let v): return String(v)
        case .timestamp(let v): return "Timestamp({ t: \(v >> 32), i: \(v & 0xFFFF_FFFF) })"
        case .int64(let v): return "Long('\(v)')"
        case .decimal128(let d): return "Decimal128('\(d)')"
        case .minKey: return "MinKey()"
        case .maxKey: return "MaxKey()"
        }
    }
}
