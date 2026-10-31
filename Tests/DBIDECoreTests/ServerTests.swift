import Foundation
import Testing

@testable import DBIDECore

/// Integration tests against real servers. Enabled when the env vars are set, e.g.
///   DBIDE_PG=localhost:55432:postgres:secret:dbide
///   DBIDE_MYSQL=localhost:53306:root:secret:dbide
/// (see scripts/test-servers.sh).
struct ServerEnv {
    var host: String, port: Int, user: String, password: String, database: String

    static func from(_ name: String) -> ServerEnv? {
        guard let v = ProcessInfo.processInfo.environment[name] else { return nil }
        let p = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 5, let port = Int(p[1]) else { return nil }
        return ServerEnv(host: p[0], port: port, user: p[2], password: p[3], database: p[4])
    }
}

@Suite(.enabled(if: ServerEnv.from("DBIDE_PG") != nil), .serialized)
struct PostgresTests {
    let env = ServerEnv.from("DBIDE_PG")!

    func connect() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            host: env.host, port: env.port, user: env.user, password: env.password, database: env.database)
    }

    @Test func queryTypesAndIntrospection() async throws {
        let c = try await connect()
        #expect(c.serverVersion.hasPrefix("PostgreSQL"))
        _ = try await c.execute("DROP SCHEMA IF EXISTS dbide_t CASCADE")
        _ = try await c.execute("CREATE SCHEMA dbide_t")
        _ = try await c.execute(
            """
            CREATE TABLE dbide_t.items (id serial PRIMARY KEY, name text NOT NULL, price numeric(8,2),
              qty int8 DEFAULT 0, ok bool, data bytea, tags text[])
            """)
        _ = try await c.execute("COMMENT ON TABLE dbide_t.items IS 'things'")
        _ = try await c.execute("CREATE INDEX items_name ON dbide_t.items (lower(name))")
        let ins = try await c.execute(
            "INSERT INTO dbide_t.items (name, price, qty, ok, data, tags) VALUES ('ä', 1.50, 3, true, '\\xCAFE', '{a,b}'), ('b', NULL, 4, false, NULL, NULL)"
        )
        #expect(ins.affectedRows == 2)
        #expect(ins.message == "INSERT 0 2")

        let r = try await c.execute("SELECT * FROM dbide_t.items ORDER BY id")
        #expect(r.columns.map(\.typeName) == ["int4", "text", "numeric", "int8", "bool", "bytea", "_text"])
        #expect(r.rows[0] == [.integer(1), .text("ä"), .text("1.50"), .integer(3), .text("true"), .blob(Data([0xCA, 0xFE])), .text("{a,b}")])
        #expect(r.rows[1][2] == .null)

        let intro = Introspector(c)
        #expect(try await intro.schemas().contains("dbide_t"))
        let tables = try await intro.tables(schema: "dbide_t")
        #expect(tables.map(\.name) == ["items"])
        #expect(tables[0].comment == "things")
        let cols = try await intro.columns(schema: "dbide_t", table: "items")
        #expect(cols.map(\.name) == ["id", "name", "price", "qty", "ok", "data", "tags"])
        #expect(cols[0].isPrimaryKey && !cols[1].nullable)
        let idx = try await intro.indexes(schema: "dbide_t", table: "items")
        #expect(idx.contains { $0.primary } && idx.contains { $0.name == "items_name" && $0.columns == ["lower(name)"] })
        let ddl = try await intro.ddl(for: tables[0])
        #expect(ddl.contains("CREATE TABLE \"dbide_t\".\"items\"") && ddl.contains("PRIMARY KEY (id)"))
        #expect(ddl.contains("CREATE INDEX items_name"))

        // Errors carry SQLSTATE and position; the session stays usable.
        do {
            _ = try await c.execute("SELECT nope FROM dbide_t.items")
            Issue.record("expected error")
        } catch let e as DatabaseError {
            #expect(e.code == "42703")
            #expect(e.position == 7)
        }
        #expect(try await c.strings("SELECT 41 + 1") == ["42"])
        _ = try await c.execute("DROP SCHEMA dbide_t CASCADE")
        await c.close()
    }

    @Test func cancelLongQuery() async throws {
        let c = try await connect()
        let task = Task { try await c.execute("SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(300))
        c.cancel()
        let start = Date()
        await #expect(throws: DatabaseError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try await c.strings("SELECT 1") == ["1"])
        await c.close()
    }

    @Test func wrongPassword() async throws {
        await #expect(throws: DatabaseError.self) {
            _ = try await PostgresConnection.connect(
                host: env.host, port: env.port, user: env.user, password: "wrong", database: env.database)
        }
    }
}

@Suite(.enabled(if: ServerEnv.from("DBIDE_MYSQL") != nil), .serialized)
struct MySQLTests {
    let env = ServerEnv.from("DBIDE_MYSQL")!

    func connect(db: String? = nil) async throws -> MySQLConnection {
        try await MySQLConnection.connect(
            host: env.host, port: env.port, user: env.user, password: env.password, database: db ?? env.database)
    }

    @Test func queryTypesAndIntrospection() async throws {
        let c = try await connect()
        #expect(c.serverVersion.contains("8."))
        _ = try await c.execute("DROP TABLE IF EXISTS items")
        _ = try await c.execute(
            """
            CREATE TABLE items (id int unsigned AUTO_INCREMENT PRIMARY KEY, name varchar(20) NOT NULL COMMENT 'nm',
              price decimal(8,2), qty bigint DEFAULT 0, score double, data varbinary(10), note text,
              KEY items_name (name)) COMMENT 'things'
            """)
        let ins = try await c.execute(
            "INSERT INTO items (name, price, qty, score, data, note) VALUES ('ä', 1.50, 3, 2.5, x'CAFE', 'n'), ('b', NULL, 4, NULL, NULL, NULL)"
        )
        #expect(ins.affectedRows == 2)

        let r = try await c.execute("SELECT * FROM items ORDER BY id")
        #expect(r.rows[0] == [.integer(1), .text("ä"), .text("1.50"), .integer(3), .real(2.5), .blob(Data([0xCA, 0xFE])), .text("n")])
        #expect(r.rows[1][2] == .null)

        // Multi-statement text returns the last result set.
        let multi = try await c.execute("SELECT 1; SELECT 2 AS two")
        #expect(multi.columns.map(\.name) == ["two"])

        let intro = Introspector(c)
        #expect(try await intro.schemas().contains("dbide"))
        let tables = try await intro.tables(schema: "dbide")
        #expect(tables.first { $0.name == "items" }?.comment == "things")
        let cols = try await intro.columns(schema: "dbide", table: "items")
        #expect(cols[0].isPrimaryKey && cols[1].comment == "nm")
        let idx = try await intro.indexes(schema: "dbide", table: "items")
        #expect(idx.map(\.name) == ["PRIMARY", "items_name"])
        let ddl = try await intro.ddl(for: tables.first { $0.name == "items" }!)
        #expect(ddl.hasPrefix("CREATE TABLE `items`"))

        await #expect(throws: DatabaseError.self) { try await c.execute("SELEC 1") }
        #expect(try await c.strings("SELECT 41 + 1") == ["42"])
        _ = try await c.execute("DROP TABLE items")
        await c.close()
    }

    @Test func cancelLongQuery() async throws {
        let c = try await connect()
        let task = Task { try await c.execute("SELECT SLEEP(30)") }
        try await Task.sleep(for: .milliseconds(500))
        c.cancel()
        let start = Date()
        // KILL QUERY makes SLEEP return 1 (or an interrupted error) promptly.
        _ = try? await task.value
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try await c.strings("SELECT 1") == ["1"])
        await c.close()
    }

    @Test func wrongPassword() async throws {
        await #expect(throws: DatabaseError.self) {
            _ = try await MySQLConnection.connect(
                host: env.host, port: env.port, user: env.user, password: "wrong", database: "")
        }
    }
}
