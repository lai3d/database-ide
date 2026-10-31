import Foundation
import Testing

@testable import DBIDECore

@Suite struct TableDesignTests {
    func base() -> TableDesign {
        TableDesign(schema: "public", name: "items", columns: [
            .init(id: "id", name: "id", type: "integer", nullable: false, primaryKey: true),
            .init(id: "name", name: "name", type: "text"),
            .init(id: "qty", name: "qty", type: "integer", defaultValue: "0"),
        ])
    }

    @Test func createPostgres() {
        var d = base()
        d.comment = "things"
        d.columns[1].comment = "label"
        #expect(d.createStatements(dialect: .postgres) == [
            "CREATE TABLE \"public\".\"items\" (\n    \"id\" integer NOT NULL,\n    \"name\" text,\n    \"qty\" integer DEFAULT 0,\n    PRIMARY KEY (\"id\")\n)",
            "COMMENT ON TABLE \"public\".\"items\" IS 'things'",
            "COMMENT ON COLUMN \"public\".\"items\".\"name\" IS 'label'",
        ])
        #expect(base().createStatements(dialect: .sqlite)[0].contains("\"id\" integer PRIMARY KEY NOT NULL"))
    }

    @Test func alterPostgres() {
        let old = base()
        var new = old
        new.name = "products"
        new.columns[1].name = "title"          // rename
        new.columns[1].nullable = false         // set not null
        new.columns[2].type = "bigint"          // type change
        new.columns[2].defaultValue = ""        // drop default
        new.columns.append(.init(name: "sku", type: "text", nullable: false, defaultValue: "''"))
        #expect(new.alterStatements(from: old, dialect: .postgres) == [
            "ALTER TABLE \"public\".\"items\" RENAME TO \"products\"",
            "ALTER TABLE \"public\".\"products\" RENAME COLUMN \"name\" TO \"title\"",
            "ALTER TABLE \"public\".\"products\" ALTER COLUMN \"title\" SET NOT NULL",
            "ALTER TABLE \"public\".\"products\" ALTER COLUMN \"qty\" TYPE bigint USING \"qty\"::bigint",
            "ALTER TABLE \"public\".\"products\" ALTER COLUMN \"qty\" DROP DEFAULT",
            "ALTER TABLE \"public\".\"products\" ADD COLUMN \"sku\" text NOT NULL DEFAULT ''",
        ])
    }

    @Test func primaryKeyChangeAndValidation() {
        let old = base()
        var new = old
        new.columns[1].primaryKey = true
        let sql = new.alterStatements(from: old, dialect: .mysql)
        #expect(sql == ["ALTER TABLE `public`.`items` DROP PRIMARY KEY", "ALTER TABLE `public`.`items` ADD PRIMARY KEY (`id`, `name`)"])
        new.columns[2].name = "id"
        #expect(new.validate() == "Duplicate column id")
    }

    @Test func sqliteSimpleAndRebuild() async throws {
        let c = try SQLiteConnection(path: ":memory:")
        let t = TableInfo(schema: "main", name: "items", kind: .table)
        var d0 = base()
        d0.schema = "main"
        try await TableDesign.apply(d0.createStatements(dialect: .sqlite), on: c)
        _ = try await c.execute("CREATE INDEX items_name ON items(name)")
        _ = try await c.execute("INSERT INTO items (id, name, qty) VALUES (1, 'a', 5), (2, 'b', 7)")

        // Simple: rename + add → plain ALTERs.
        let loaded = try await TableDesign.load(t, from: c)
        var simple = loaded
        simple.columns[2].name = "quantity"
        simple.columns.append(.init(name: "note", type: "TEXT"))
        let s1 = simple.alterStatements(from: loaded, dialect: .sqlite)
        #expect(s1.allSatisfy { $0.hasPrefix("ALTER TABLE") })
        try await TableDesign.apply(s1, on: c)

        // Type / NOT NULL change → rebuild, data and index kept.
        let loaded2 = try await TableDesign.load(t, from: c)
        var rebuilt = loaded2
        rebuilt.columns[1].nullable = false
        rebuilt.columns.removeAll { $0.name == "note" }
        let s2 = rebuilt.alterStatements(from: loaded2, dialect: .sqlite)
        #expect(s2.contains { $0.hasPrefix("INSERT INTO") })
        try await TableDesign.apply(s2, on: c)
        let cols = try await Introspector(c).columns(schema: "main", table: "items")
        #expect(cols.map(\.name) == ["id", "name", "quantity"] && cols[1].nullable == false)
        #expect(try await c.strings("SELECT name || quantity FROM items ORDER BY id") == ["a5", "b7"])
        #expect(try await Introspector(c).indexes(schema: "main", table: "items").map(\.name) == ["items_name"])
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_PG") != nil)) func postgresLive() async throws {
        let e = ServerEnv.from("DBIDE_PG")!
        let c = try await PostgresConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        _ = try await c.execute("DROP TABLE IF EXISTS td_items, td_products")
        var d = base()
        d.name = "td_items"
        try await TableDesign.apply(d.createStatements(dialect: .postgres), on: c)
        let t = TableInfo(schema: "public", name: "td_items", kind: .table)
        let loaded = try await TableDesign.load(t, from: c)
        #expect(loaded.primaryKeyName == "td_items_pkey")
        var n = loaded
        n.name = "td_products"
        n.columns[2].type = "numeric(10,2)"
        n.columns[1].primaryKey = true
        n.columns[1].nullable = false
        try await TableDesign.apply(n.alterStatements(from: loaded, dialect: .postgres), on: c)
        let cols = try await Introspector(c).columns(schema: "public", table: "td_products")
        #expect(cols.map(\.type) == ["integer", "text", "numeric(10,2)"])
        #expect(cols.filter(\.isPrimaryKey).map(\.name) == ["id", "name"])
        // A failing statement rolls the whole change back (transactional DDL).
        var bad = n
        bad.columns.append(.init(name: "x", type: "no_such_type"))
        bad.columns[0].name = "ident"
        let reloaded = try await TableDesign.load(TableInfo(schema: "public", name: "td_products", kind: .table), from: c)
        await #expect(throws: DatabaseError.self) { try await TableDesign.apply(bad.alterStatements(from: reloaded, dialect: .postgres), on: c) }
        #expect(try await Introspector(c).columns(schema: "public", table: "td_products").first?.name == "id")
        _ = try await c.execute("DROP TABLE td_products")
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_MYSQL") != nil)) func mysqlLive() async throws {
        let e = ServerEnv.from("DBIDE_MYSQL")!
        let c = try await MySQLConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        _ = try await c.execute("DROP TABLE IF EXISTS td_items")
        var d = base()
        d.schema = e.database
        d.name = "td_items"
        d.columns[1].type = "varchar(50)"
        d.columns[1].defaultValue = "'x'"
        try await TableDesign.apply(d.createStatements(dialect: .mysql), on: c)
        let t = TableInfo(schema: e.database, name: "td_items", kind: .table)
        let loaded = try await TableDesign.load(t, from: c)
        #expect(loaded.columns[1].defaultValue == "'x'")
        var n = loaded
        n.columns[1].name = "title"
        n.columns[1].comment = "the title"
        n.columns[2].type = "bigint"
        try await TableDesign.apply(n.alterStatements(from: loaded, dialect: .mysql), on: c)
        let cols = try await Introspector(c).columns(schema: e.database, table: "td_items")
        #expect(cols.map(\.name) == ["id", "title", "qty"] && cols[1].comment == "the title" && cols[2].type == "bigint")
        #expect(cols[1].defaultValue == "x")
        _ = try await c.execute("DROP TABLE td_items")
        await c.close()
    }
}
