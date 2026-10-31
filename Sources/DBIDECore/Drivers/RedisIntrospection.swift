import Foundation

struct RedisIntrospection: EngineIntrospection {
    let c: RedisConnection
    static let keyLimit = 2000

    func schemas() async throws -> [String] {
        let info = try await c.command(["INFO", "keyspace"]).text ?? ""
        var dbs = Set([c.currentDB])
        for line in info.split(separator: "\r\n") where line.hasPrefix("db") {
            if let n = Int(line.dropFirst(2).prefix { $0.isNumber }) { dbs.insert(n) }
        }
        return dbs.sorted().map { "db\($0)" }
    }

    func currentSchema() async throws -> String? { "db\(c.currentDB)" }

    /// Keys of a database (first `keyLimit` by SCAN) with their types as comments.
    func tables(schema: String) async throws -> [TableInfo] {
        let db = Int(schema.dropFirst(2)) ?? 0
        let limit = Self.keyLimit
        let keys: [(String, String)] = try await c.onWorker { [c] in
            let original = c.currentDB
            if db != original { _ = try c.commandSync([Data("SELECT".utf8), Data(String(db).utf8)]) }
            defer { if db != original { _ = try? c.commandSync([Data("SELECT".utf8), Data(String(original).utf8)]) } }
            var cursor = "0"
            var names: [String] = []
            repeat {
                let reply = try c.commandSync(["SCAN", cursor, "COUNT", "1000"].map { Data($0.utf8) })
                guard case .array(let parts) = reply, parts.count == 2 else { break }
                cursor = parts[0].text ?? "0"
                if case .array(let ks) = parts[1] { names += ks.compactMap(\.text) }
            } while cursor != "0" && names.count < limit
            names = Array(Set(names)).sorted().prefix(limit).map { $0 }
            let types = try c.pipelineSync(names.map { [Data("TYPE".utf8), Data($0.utf8)] })
            return zip(names, types.map { $0.text ?? "?" }).map { ($0, $1) }
        }
        return keys.map { TableInfo(schema: schema, name: $0.0, kind: .table, comment: $0.1) }
    }

    func columns(schema: String, table: String) async throws -> [ColumnInfo] {
        let type = try await c.onWorker { [c] in try Self.typeOf(table, in: schema, c) }
        let names: [String] =
            switch type {
            case "hash": ["key", "value"]
            case "zset", "stream": ["item", "value"]
            case "list", "set": ["#", "value"]
            default: ["value"]
            }
        return names.map { ColumnInfo(name: $0, type: type, nullable: false, isPrimaryKey: false) }
    }

    func indexes(schema: String, table: String) async throws -> [IndexInfo] { [] }

    /// Summary plus commands that recreate (the first 200 elements of) the value.
    func ddl(for table: TableInfo) async throws -> String {
        let key = table.name
        let schema = table.schema
        return try await c.onWorker { [c] in
            let db = Int(schema.dropFirst(2)) ?? 0
            let original = c.currentDB
            if db != original { _ = try c.commandSync([Data("SELECT".utf8), Data(String(db).utf8)]) }
            defer { if db != original { _ = try? c.commandSync([Data("SELECT".utf8), Data(String(original).utf8)]) } }
            func run(_ args: [String]) throws -> RedisValue { try c.commandSync(args.map { Data($0.utf8) }) }
            let type = try run(["TYPE", key]).text ?? "none"
            let ttl = try run(["TTL", key]).text ?? "?"
            let encoding = try run(["OBJECT", "ENCODING", key]).text ?? "?"
            let memory = try run(["MEMORY", "USAGE", key]).text ?? "?"
            let q = SQLDialect.redis.literal
            var lines = ["# type: \(type)", "# ttl: \(ttl)", "# encoding: \(encoding)", "# memory: \(memory) bytes"]
            func strings(_ v: RedisValue) -> [String] {
                switch v {
                case .array(let a), .set(let a): a.map { $0.text ?? $0.display }
                case .map(let m): m.flatMap { [$0.0.text ?? "", $0.1.text ?? ""] }
                default: []
                }
            }
            switch type {
            case "string": lines.append("SET \(q(key)) \(q(try run(["GET", key]).text ?? ""))")
            case "hash":
                let kv = strings(try run(["HGETALL", key])).prefix(400)
                lines.append("HSET \(q(key)) " + kv.map(q).joined(separator: " "))
            case "list": lines.append("RPUSH \(q(key)) " + strings(try run(["LRANGE", key, "0", "199"])).map(q).joined(separator: " "))
            case "set": lines.append("SADD \(q(key)) " + strings(try run(["SRANDMEMBER", key, "200"])).map(q).joined(separator: " "))
            case "zset":
                var parts: [String] = []
                if case .array(let items) = try run(["ZRANGE", key, "0", "199", "WITHSCORES"]) {
                    for item in items {
                        if case .array(let p) = item, p.count == 2 { parts += [p[1].text ?? "0", q(p[0].text ?? "")] }
                    }
                }
                lines.append("ZADD \(q(key)) " + parts.joined(separator: " "))
            default: break
            }
            if let t = Int(ttl), t > 0 { lines.append("EXPIRE \(q(key)) \(t)") }
            return lines.joined(separator: "\n")
        }
    }

    static func typeOf(_ key: String, in schema: String, _ c: RedisConnection) throws -> String {
        let db = Int(schema.dropFirst(2)) ?? 0
        let original = c.currentDB
        if db != original { _ = try c.commandSync([Data("SELECT".utf8), Data(String(db).utf8)]) }
        defer { if db != original { _ = try? c.commandSync([Data("SELECT".utf8), Data(String(original).utf8)]) } }
        return try c.commandSync([Data("TYPE".utf8), Data(key.utf8)]).text ?? "none"
    }

    /// Command(s) that show a key's value page; the type comes from the explorer listing.
    static func browseCommand(_ table: TableInfo, limit: Int, offset: Int) -> String {
        let key = SQLDialect.redis.literal(table.name)
        let select = "SELECT \(table.schema.dropFirst(2))\n"
        let last = offset + limit - 1
        switch table.comment ?? "" {
        case "hash": return select + "HGETALL \(key)"
        case "list": return select + "LRANGE \(key) \(offset) \(last)"
        case "set": return select + "SMEMBERS \(key)"
        case "zset": return select + "ZRANGE \(key) \(offset) \(last) WITHSCORES"
        case "stream": return select + "XRANGE \(key) - + COUNT \(limit)"
        default: return select + "GET \(key)"
        }
    }
}
