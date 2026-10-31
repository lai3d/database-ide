import Foundation

/// A parsed mongosh-style statement.
public enum MongoStatement: Sendable, Equatable {
    case show(String)
    case use(String)
    /// `db.method(args)`
    case database(method: String, args: [BSONValue])
    /// `db.coll.method(args).modifier(args)…`
    case collection(name: String, method: String, args: [BSONValue], modifiers: [Modifier])

    public struct Modifier: Sendable, Equatable {
        public var name: String
        public var args: [BSONValue]
    }
}

// MARK: - Parser

/// Recursive-descent parser for the subset of mongosh syntax a console needs:
/// JS object/array literals (unquoted keys, single or double quotes, trailing commas),
/// numbers, true/false/null, ObjectId / ISODate / new Date / NumberLong / NumberInt /
/// NumberDecimal / Decimal128 / UUID / Long / Int32 / Double, and /regex/flags.
public struct MongoShellParser {
    private let s: [Character]
    private var i = 0

    public init(_ text: String) { s = Array(text) }

    public static func parse(_ text: String) throws -> MongoStatement {
        var p = MongoShellParser(text)
        let st = try p.statement()
        p.skipSpace()
        if p.peek() == ";" { p.i += 1 }
        p.skipSpace()
        guard p.i >= p.s.count else { throw p.error("Unexpected '\(p.s[p.i])'") }
        return st
    }

    /// Parses a standalone value (used for filter / sort fields in the table view).
    public static func parseValue(_ text: String) throws -> BSONValue {
        var p = MongoShellParser(text)
        let v = try p.value()
        p.skipSpace()
        guard p.i >= p.s.count else { throw p.error("Unexpected '\(p.s[p.i])'") }
        return v
    }

    private func error(_ msg: String) -> DatabaseError {
        DatabaseError("Syntax error: \(msg)", position: i)
    }

    private func peek(_ offset: Int = 0) -> Character? { i + offset < s.count ? s[i + offset] : nil }

    private mutating func skipSpace() {
        while i < s.count {
            if s[i].isWhitespace {
                i += 1
            } else if s[i] == "/", peek(1) == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
            } else if s[i] == "/", peek(1) == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                i = min(s.count, i + 2)
            } else {
                return
            }
        }
    }

    private mutating func expect(_ c: Character) throws {
        skipSpace()
        guard peek() == c else { throw error("Expected '\(c)'") }
        i += 1
    }

    private mutating func identifier() throws -> String {
        skipSpace()
        let start = i
        while i < s.count, s[i].isLetter || s[i].isNumber || s[i] == "_" || s[i] == "$" { i += 1 }
        guard i > start else { throw error("Expected a name") }
        return String(s[start..<i])
    }

    private mutating func statement() throws -> MongoStatement {
        skipSpace()
        let save = i
        let word = (try? identifier()) ?? ""
        switch word {
        case "show":
            return .show(try identifier())
        case "use":
            skipSpace()
            let start = i
            while i < s.count, !s[i].isWhitespace, s[i] != ";" { i += 1 }
            return .use(String(s[start..<i]))
        case "db":
            break
        default:
            i = save
            throw error("Statements start with db., show or use")
        }
        // db.<name> … or db.getCollection('x') …
        try expect(".")
        var name = try identifier()
        var collection: String?
        skipSpace()
        if name == "getCollection" || name == "getSiblingDB" {
            let args = try arguments()
            guard let n = args.first?.string else { throw error("\(name) needs a name") }
            if name == "getSiblingDB" { throw error("getSiblingDB is not supported; use `use \(n)`") }
            collection = n
        } else if peek() == "(" {
            return .database(method: name, args: try arguments())
        } else if peek() == "[" {
            i += 1
            guard let n = try value().string else { throw error("Expected a collection name") }
            try expect("]")
            collection = n
        } else {
            collection = name
        }
        // Possibly dotted collection names: db.system.users.find()
        var parts: [String] = []
        while true {
            try expect(".")
            name = try identifier()
            skipSpace()
            if peek() == "(" { break }
            parts.append(name)
        }
        if !parts.isEmpty { collection = ([collection!] + parts).joined(separator: ".") }
        let args = try arguments()
        var modifiers: [MongoStatement.Modifier] = []
        skipSpace()
        while peek() == "." {
            i += 1
            let m = try identifier()
            modifiers.append(.init(name: m, args: try arguments()))
            skipSpace()
        }
        return .collection(name: collection!, method: name, args: args, modifiers: modifiers)
    }

    private mutating func arguments() throws -> [BSONValue] {
        try expect("(")
        var args: [BSONValue] = []
        skipSpace()
        if peek() == ")" {
            i += 1
            return args
        }
        while true {
            args.append(try value())
            skipSpace()
            if peek() == "," {
                i += 1
                skipSpace()
                if peek() == ")" { break }
                continue
            }
            break
        }
        try expect(")")
        return args
    }

    mutating func value() throws -> BSONValue {
        skipSpace()
        guard let c = peek() else { throw error("Unexpected end of input") }
        switch c {
        case "{": return .document(try object())
        case "[":
            i += 1
            var items: [BSONValue] = []
            skipSpace()
            while peek() != "]" {
                items.append(try value())
                skipSpace()
                if peek() == "," { i += 1; skipSpace() } else { break }
            }
            try expect("]")
            return .array(items)
        case "\"", "'": return .string(try string())
        case "/": return try regex()
        case "-", "+", "0"..."9", ".": return try number()
        default:
            let name = try identifier()
            switch name {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "undefined": return .undefined
            case "Infinity": return .double(.infinity)
            case "NaN": return .double(.nan)
            case "MinKey": _ = try? arguments(); return .minKey
            case "MaxKey": _ = try? arguments(); return .maxKey
            case "new":
                return try constructor(try identifier())
            default:
                return try constructor(name)
            }
        }
    }

    private mutating func constructor(_ name: String) throws -> BSONValue {
        skipSpace()
        let args = peek() == "(" ? try arguments() : []
        let first = args.first
        switch name {
        case "ObjectId", "ObjectID":
            guard let hex = first?.string else { return .objectId(.generate()) }
            guard let id = ObjectID(hex: hex) else { throw error("Invalid ObjectId '\(hex)'") }
            return .objectId(id)
        case "ISODate", "Date":
            if first == nil { return .date(Int64(Date().timeIntervalSince1970 * 1000)) }
            if let ms = first?.int { return .date(ms) }
            guard let text = first?.string, let ms = Self.parseDate(text) else { throw error("Invalid date") }
            return .date(ms)
        case "NumberLong", "Long":
            if let v = first?.int { return .int64(v) }
            if let t = first?.string, let v = Int64(t) { return .int64(v) }
            throw error("Invalid NumberLong")
        case "NumberInt", "Int32":
            if let v = first?.int ?? first?.string.flatMap({ Int64($0) }), let i32 = Int32(exactly: v) { return .int32(i32) }
            throw error("Invalid NumberInt")
        case "Double":
            if case .double(let d)? = first { return .double(d) }
            if let v = first?.int { return .double(Double(v)) }
            throw error("Invalid Double")
        case "NumberDecimal", "Decimal128":
            let text = first?.string ?? first.map { $0.shellString } ?? ""
            guard let d = Decimal128(text) else { throw error("Invalid decimal '\(text)'") }
            return .decimal128(d)
        case "UUID":
            let hex = (first?.string ?? UUID().uuidString).replacingOccurrences(of: "-", with: "")
            var bytes: [UInt8] = []
            var idx = hex.startIndex
            while idx < hex.endIndex, let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex),
                let b = UInt8(hex[idx..<next], radix: 16)
            {
                bytes.append(b)
                idx = next
            }
            guard bytes.count == 16, idx == hex.endIndex else { throw error("Invalid UUID") }
            return .binary(subtype: 4, Data(bytes))
        case "Timestamp":
            if let d = first?.document, let t = d["t"]?.int, let i = d["i"]?.int { return .timestamp(UInt64(t) << 32 | UInt64(i)) }
            if args.count == 2, let t = args[0].int, let i = args[1].int { return .timestamp(UInt64(t) << 32 | UInt64(i)) }
            throw error("Invalid Timestamp")
        default:
            throw error("Unknown value '\(name)'")
        }
    }

    static func parseDate(_ text: String) -> Int64? {
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate],
            [.withFullDate, .withDashSeparatorInDate],
        ] {
            iso.formatOptions = opts
            iso.timeZone = TimeZone(identifier: "UTC")
            if let d = iso.date(from: text) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        }
        return nil
    }

    private mutating func object() throws -> BSONDocument {
        try expect("{")
        var doc = BSONDocument()
        skipSpace()
        while peek() != "}" {
            skipSpace()
            let key: String
            if let c = peek(), c == "\"" || c == "'" {
                key = try string()
            } else {
                let start = i
                while i < s.count, s[i].isLetter || s[i].isNumber || s[i] == "_" || s[i] == "$" || s[i] == "." { i += 1 }
                guard i > start else { throw error("Expected a field name") }
                key = String(s[start..<i])
            }
            try expect(":")
            doc.elements.append(.init(key: key, value: try value()))
            skipSpace()
            if peek() == "," { i += 1; skipSpace() } else { break }
        }
        try expect("}")
        return doc
    }

    private mutating func string() throws -> String {
        let quote = s[i]
        i += 1
        var out = ""
        while i < s.count, s[i] != quote {
            if s[i] == "\\", i + 1 < s.count {
                i += 1
                switch s[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "u":
                    let hex = String(s[min(i + 1, s.count)..<min(i + 5, s.count)])
                    if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) {
                        out.unicodeScalars.append(u)
                        i += 4
                    }
                default: out.append(s[i])
                }
            } else {
                out.append(s[i])
            }
            i += 1
        }
        guard i < s.count else { throw error("Unterminated string") }
        i += 1
        return out
    }

    private mutating func regex() throws -> BSONValue {
        i += 1
        var pattern = ""
        while i < s.count, s[i] != "/" {
            if s[i] == "\\", i + 1 < s.count {
                pattern.append(s[i])
                i += 1
            }
            pattern.append(s[i])
            i += 1
        }
        guard i < s.count else { throw error("Unterminated regex") }
        i += 1
        var flags = ""
        while i < s.count, s[i].isLetter {
            flags.append(s[i])
            i += 1
        }
        return .regex(pattern: pattern, options: flags)
    }

    private mutating func number() throws -> BSONValue {
        let start = i
        if peek() == "-" || peek() == "+" { i += 1 }
        while i < s.count, s[i].isNumber || s[i] == "." || s[i] == "e" || s[i] == "E"
            || ((s[i] == "-" || s[i] == "+") && (s[i - 1] == "e" || s[i - 1] == "E"))
        {
            i += 1
        }
        let text = String(s[start..<i])
        if !text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let v = Int64(text) {
            return Int32(exactly: v).map(BSONValue.int32) ?? .int64(v)
        }
        guard let d = Double(text) else { throw error("Invalid number '\(text)'") }
        return .double(d)
    }
}

// MARK: - Splitting

extension MongoShellParser {
    /// Splits console text into statements: on `;` and on new lines that start a new
    /// statement (`db.` / `show ` / `use `) while no bracket is open.
    public static func split(_ text: String) -> [SQLStatement] {
        let u = Array(text.utf16)
        var out: [SQLStatement] = []
        var start = 0
        var depth = 0
        var i = 0
        func emit(_ end: Int) {
            var a = start, b = end
            while a < b, SQLLexer.isSpace(u[a]) { a += 1 }
            while b > a, SQLLexer.isSpace(u[b - 1]) { b -= 1 }
            guard a < b else { return }
            let piece = String(utf16CodeUnits: Array(u[a..<b]), count: b - a)
            // Skip comment-only pieces.
            let code = piece.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            guard !code.isEmpty else { return }
            out.append(SQLStatement(text: piece, range: NSRange(location: a, length: b - a)))
        }
        func startsStatement(at j: Int) -> Bool {
            var k = j
            while k < u.count, u[k] == 32 || u[k] == 9 { k += 1 }
            for word in ["db.", "db[", "show ", "use "] {
                let w = Array(word.utf16)
                if k + w.count <= u.count, Array(u[k..<k + w.count]) == w { return true }
            }
            return false
        }
        while i < u.count {
            let c = u[i]
            if c == 47, i + 1 < u.count, u[i + 1] == 47 {  // //
                while i < u.count, u[i] != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < u.count, u[i + 1] == 42 {  // /* */
                i += 2
                while i + 1 < u.count, !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
                i += 2
                continue
            }
            if c == 34 || c == 39 || c == 96 {  // quotes
                let q = c
                i += 1
                while i < u.count, u[i] != q {
                    if u[i] == 92 { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            switch c {
            case 123, 91, 40: depth += 1
            case 125, 93, 41: depth = max(0, depth - 1)
            case 59 where depth == 0:
                emit(i)
                start = i + 1
            case 10 where depth == 0 && startsStatement(at: i + 1):
                emit(i)
                start = i + 1
            default: break
            }
            i += 1
        }
        emit(min(i, u.count))
        return out
    }
}
