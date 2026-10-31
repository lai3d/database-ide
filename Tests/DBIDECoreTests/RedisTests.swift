import Foundation
import Testing

@testable import DBIDECore

@Suite struct RedisParsingTests {
    @Test func arguments() throws {
        let args = try RedisConnection.parseArguments(#"SET "my key" 'it\'s' "a\tb\x41" plain"#).map { String(decoding: $0, as: UTF8.self) }
        #expect(args == ["SET", "my key", "it's", "a\tbA", "plain"])
        #expect(throws: DatabaseError.self) { try RedisConnection.parseArguments(#"GET "open"#) }
    }

    @Test func splittingAndClassifying() {
        #expect(SQLSplitter.split("# comment\nSET a 1\n\n  GET a\n", dialect: .redis).map(\.text) == ["SET a 1", "GET a"])
        #expect(SQLClassifier.isReadOnly("GET a\nHGETALL h", dialect: .redis))
        #expect(!SQLClassifier.isReadOnly("GET a\nDEL a", dialect: .redis))
    }
}

/// DBIDE_REDIS=host:port:user:password (user may be empty)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DBIDE_REDIS"] != nil), .serialized)
struct RedisLiveTests {
    var env: (String, Int, String, String) {
        let p = ProcessInfo.processInfo.environment["DBIDE_REDIS"]!.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return (p[0], Int(p[1])!, p[2], p[3])
    }

    func connect(db: Int = 3) async throws -> RedisConnection {
        try await RedisConnection.connect(host: env.0, port: env.1, user: env.2, password: env.3, database: db)
    }

    @Test func commandsAndResults() async throws {
        let c = try await connect()
        #expect(c.serverVersion.hasPrefix("Redis 7"))
        _ = try await c.execute("FLUSHDB")
        var r = try await c.execute("SET greeting \"hello world\"")
        #expect(r.message == "OK")
        r = try await c.execute("GET greeting")
        #expect(r.rows == [[.text("hello world")]])
        r = try await c.execute("GET missing")
        #expect(r.message == "(nil)")
        _ = try await c.execute("HSET user:1 name Ann age 31")
        r = try await c.execute("HGETALL user:1")
        #expect(r.columns.map(\.name) == ["key", "value"] && r.rows.count == 2)
        _ = try await c.execute("ZADD scores 10 a 20 b 15 c")
        r = try await c.execute("ZRANGE scores 0 -1 WITHSCORES")
        #expect(r.rows == [[.text("a"), .real(10)], [.text("c"), .real(15)], [.text("b"), .real(20)]])
        _ = try await c.execute("RPUSH q x y z")
        r = try await c.execute("LRANGE q 0 -1", maxRows: 2)
        #expect(r.rows.count == 2 && r.truncated)
        r = try await c.execute("INCR counter")
        #expect(r.rows == [[.integer(1)]])
        await #expect(throws: DatabaseError.self) { _ = try await c.execute("HGET greeting x") }  // WRONGTYPE

        // Introspection
        let intro = Introspector(c)
        #expect(try await intro.schemas().contains("db3"))
        #expect(try await intro.currentSchema() == "db3")
        let keys = try await intro.tables(schema: "db3")
        #expect(keys.map(\.name) == ["counter", "greeting", "q", "scores", "user:1"])
        #expect(keys.first { $0.name == "user:1" }?.comment == "hash")
        #expect(try await intro.columns(schema: "db3", table: "scores").map(\.name) == ["item", "value"])
        let ddl = try await intro.ddl(for: keys.first { $0.name == "user:1" }!)
        #expect(ddl.contains("# type: hash") && ddl.contains("HSET \"user:1\""))

        // Table view command for a key in another database.
        let other = try await connect(db: 0)
        let page = try await other.execute(intro.selectSQL(keys.first { $0.name == "scores" }!, filter: "", orderBy: "", limit: 2, offset: 1))
        #expect(page.rows == [[.text("c"), .real(15)], [.text("b"), .real(20)]])
        await other.close()
        _ = try await c.execute("FLUSHDB")
        await c.close()
    }

    @Test func wrongPassword() async throws {
        await #expect(throws: DatabaseError.self) { _ = try await RedisConnection.connect(host: env.0, port: env.1, user: "", password: "nope") }
    }

    @Test func cancelBlockingCommand() async throws {
        let c = try await connect()
        let task = Task { try await c.execute("BLPOP never-filled 30") }
        try await Task.sleep(for: .milliseconds(400))
        c.cancel()
        let start = Date()
        await #expect(throws: DatabaseError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
        await c.close()
    }
}
