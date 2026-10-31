import Foundation
import Testing

@testable import DBIDECore

@Suite struct SchemaDiffTests {
    func converge(source: any DatabaseConnection, sourceSchema: String, target: any DatabaseConnection, targetSchema: String) async throws -> (SchemaDiff, [String]) {
        let diff = SchemaDiff.compare(
            source: try await SchemaSnapshot.load(schema: sourceSchema, from: source),
            target: try await SchemaSnapshot.load(schema: targetSchema, from: target))
        let sql = diff.migrationSQL()
        for statement in sql where !statement.hasPrefix("--") { _ = try await target.execute(statement) }
        let after = SchemaDiff.compare(
            source: try await SchemaSnapshot.load(schema: sourceSchema, from: source),
            target: try await SchemaSnapshot.load(schema: targetSchema, from: target))
        #expect(after.isEmpty, "remaining: \(after.tables.map { "\($0.name) \($0.kind) \($0.columns.map(\.details)) \($0.indexes.map(\.name))" })")
        return (diff, sql)
    }

    @Test func sqliteConverges() async throws {
        let dev = try SQLiteConnection(path: ":memory:"), prod = try SQLiteConnection(path: ":memory:")
        for sql in [
            "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL, name TEXT, created TEXT DEFAULT CURRENT_TIMESTAMP)",
            "CREATE INDEX users_email ON users(email)",
            "CREATE TABLE tags (id INTEGER PRIMARY KEY, label TEXT)",
        ] { _ = try await dev.execute(sql) }
        for sql in [
            "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, legacy INTEGER)",
            "CREATE INDEX users_legacy ON users(legacy)",
            "CREATE TABLE old_stuff (x INTEGER)",
            "INSERT INTO users (id, email) VALUES (1, 'a@x')",
        ] { _ = try await prod.execute(sql) }
        let (diff, _) = try await converge(source: dev, sourceSchema: "main", target: prod, targetSchema: "main")
        #expect(diff.tables.map { "\($0.name):\($0.kind)" } == ["tags:added", "users:changed", "old_stuff:removed"])
        let users = diff.tables[1]
        #expect(Set(users.columns.map { "\($0.name):\($0.kind)" }) == ["email:changed", "name:added", "created:added", "legacy:removed"])
        #expect(Set(users.indexes.map { "\($0.name):\($0.kind)" }) == ["users_email:added", "users_legacy:removed"])
        #expect(try await prod.strings("SELECT email FROM users") == ["a@x"])  // data survived the rebuild
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_PG") != nil)) func postgresConverges() async throws {
        let e = ServerEnv.from("DBIDE_PG")!
        let c = try await PostgresConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        for sql in [
            "DROP SCHEMA IF EXISTS diff_a CASCADE", "DROP SCHEMA IF EXISTS diff_b CASCADE", "CREATE SCHEMA diff_a", "CREATE SCHEMA diff_b",
            "CREATE TABLE diff_a.items (id bigint PRIMARY KEY, name text NOT NULL, price numeric(10,2) DEFAULT 0, sku varchar(20))",
            "CREATE UNIQUE INDEX items_sku ON diff_a.items (sku)",
            "CREATE TABLE diff_a.audit (id serial PRIMARY KEY, at timestamptz)",
            "CREATE TABLE diff_b.items (id integer PRIMARY KEY, name text, price numeric(8,2), obsolete boolean)",
            "CREATE INDEX items_name ON diff_b.items (name)",
        ] { _ = try await c.execute(sql) }
        let (diff, sql) = try await converge(source: c, sourceSchema: "diff_a", target: c, targetSchema: "diff_b")
        #expect(diff.tables.map(\.name) == ["audit", "items"])
        #expect(sql.contains { $0.contains("ALTER COLUMN \"id\" TYPE bigint") })
        _ = try await c.execute("DROP SCHEMA diff_a CASCADE")
        _ = try await c.execute("DROP SCHEMA diff_b CASCADE")
        await c.close()
    }
}
