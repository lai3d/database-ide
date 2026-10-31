import Foundation
import Testing

@testable import DBIDECore

/// DBIDE_CLICKHOUSE=host:port:user:password:database
@Suite(.enabled(if: ServerEnv.from("DBIDE_CLICKHOUSE") != nil), .serialized)
struct ClickHouseTests {
    let env = ServerEnv.from("DBIDE_CLICKHOUSE")!

    func connect() async throws -> ClickHouseConnection {
        try await ClickHouseConnection.connect(host: env.host, port: env.port, user: env.user, password: env.password, database: env.database)
    }

    @Test func queriesTypesAndIntrospection() async throws {
        let c = try await connect()
        #expect(c.serverVersion.hasPrefix("ClickHouse 24"))
        _ = try await c.execute("DROP TABLE IF EXISTS events")
        _ = try await c.execute("""
            CREATE TABLE events (id UInt64, name String COMMENT 'label', price Decimal(10,2), score Nullable(Float64),
              tags Array(String), ts DateTime, INDEX name_idx name TYPE bloom_filter GRANULARITY 1)
            ENGINE = MergeTree ORDER BY (id) COMMENT 'things'
            """)
        let ins = try await c.execute("INSERT INTO events VALUES (1, 'a', 1.50, 2.5, ['x','y'], '2024-01-02 03:04:05'), (2, 'it''s', 3, NULL, [], now())")
        #expect(ins.affectedRows == 2)
        let r = try await c.execute("SELECT id, name, price, score, tags FROM events ORDER BY id")
        #expect(r.columns.map(\.typeName) == ["UInt64", "String", "Decimal(10, 2)", "Nullable(Float64)", "Array(String)"])
        #expect(r.rows[0] == [.integer(1), .text("a"), .real(1.5), .real(2.5), .text(#"["x","y"]"#)])
        #expect(r.rows[1][1] == .text("it's") && r.rows[1][3] == .null)

        let many = try await c.execute("SELECT number FROM numbers(100000)", maxRows: 500)
        #expect(many.rows.count == 500 && many.truncated)

        do {
            _ = try await c.execute("SELEC 1")
            Issue.record("expected error")
        } catch let e as DatabaseError {
            #expect(e.code == "62 SYNTAX_ERROR" && e.position == 0, "code=\(e.code ?? "nil") pos=\(e.position ?? -1) msg=\(e.message.suffix(60))")
        }

        // Session keeps USE.
        _ = try await c.execute("CREATE DATABASE IF NOT EXISTS other_db")
        _ = try await c.execute("USE other_db")
        #expect(try await c.strings("SELECT currentDatabase()") == ["other_db"])
        _ = try await c.execute("USE \(env.database)")

        let intro = Introspector(c)
        #expect(try await intro.schemas().contains(env.database))
        let tables = try await intro.tables(schema: env.database)
        let ev = try #require(tables.first { $0.name == "events" })
        #expect(ev.comment == "things")
        let cols = try await intro.columns(schema: env.database, table: "events")
        #expect(cols.first?.isPrimaryKey == true && cols[1].comment == "label" && cols[3].nullable)
        #expect(try await intro.indexes(schema: env.database, table: "events").map(\.name) == ["ORDER BY", "name_idx"])
        #expect(try await intro.ddl(for: ev).contains("ENGINE = MergeTree"))

        let plan = try await Explainer.explain("SELECT name, count() FROM events WHERE id > 0 GROUP BY name", analyze: false, on: c)
        #expect(plan.root.allNodes.contains { $0.title.hasPrefix("ReadFromMergeTree") })

        // Designer: create + alter.
        _ = try await c.execute("DROP TABLE IF EXISTS designed")
        var d = TableDesign(schema: env.database, name: "designed", columns: [
            .init(id: "id", name: "id", type: "UInt64", nullable: false, primaryKey: true),
            .init(id: "v", name: "v", type: "String"),
        ])
        try await TableDesign.apply(d.createStatements(dialect: .clickhouse), on: c)
        let loaded = try await TableDesign.load(TableInfo(schema: env.database, name: "designed", kind: .table), from: c)
        d = loaded
        d.columns[1].name = "value"
        d.columns.append(.init(name: "n", type: "Int32", nullable: false, defaultValue: "7"))
        try await TableDesign.apply(d.alterStatements(from: loaded, dialect: .clickhouse), on: c)
        #expect(try await intro.columns(schema: env.database, table: "designed").map(\.name) == ["id", "value", "n"])

        // CSV import.
        let csv = CSVImport(parsed: [["id", "value", "n"], ["1", "x", "3"], ["2", "", "4"]], firstRowIsHeader: true)
        let types = (0..<3).map(csv.inferType)
        let n = try await CSVImport.run(csv.insertStatements(schema: env.database, table: "designed", mapping: ["id", "value", "n"], types: types, emptyAsNull: false, dialect: .clickhouse), on: c)
        #expect(n == 2)
        _ = try await c.execute("DROP TABLE designed")
        _ = try await c.execute("DROP TABLE events")
        _ = try await c.execute("DROP DATABASE other_db")
        await c.close()
    }

    @Test func cancel() async throws {
        let c = try await connect()
        let task = Task { try await c.execute("SELECT sum(number) FROM numbers_mt(100000000000)") }
        try await Task.sleep(for: .milliseconds(600))
        c.cancel()
        let start = Date()
        await #expect(throws: DatabaseError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try await c.strings("SELECT 1") == ["1"])
        await c.close()
    }
}
