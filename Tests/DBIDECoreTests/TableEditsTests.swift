import Foundation
import Testing

@testable import DBIDECore

@Suite struct TableEditsTests {
    let table = TableInfo(schema: "public", name: "items", kind: .table)
    let columns = [
        ResultColumn(name: "id", typeName: "int"), ResultColumn(name: "name", typeName: "text"),
        ResultColumn(name: "note", typeName: "text"),
    ]
    let rows: [[SQLValue]] = [[.integer(1), .text("a"), .null], [.integer(2), .text("b'c"), .text("x")]]

    func sampleEdits() -> TableEdits {
        var e = TableEdits()
        e.set(.text("A"), row: 0, column: 1, original: rows[0][1])
        e.set(.null, row: 1, column: 2, original: rows[1][2])
        e.deletedRows.insert(1)
        e.insertedRows.append([.null, .text("new"), .null])
        e.insertedRows.append([.null, .null, .null])
        return e
    }

    @Test func postgresStatements() throws {
        let sql = try sampleEdits().statements(table: table, dialect: .postgres, columns: columns, rows: rows, primaryKey: ["id"])
        #expect(sql == [
            #"DELETE FROM "public"."items" WHERE "id" = 2"#,
            #"UPDATE "public"."items" SET "name" = 'A' WHERE "id" = 1"#,
            #"INSERT INTO "public"."items" ("name") VALUES ('new')"#,
            #"INSERT INTO "public"."items" DEFAULT VALUES"#,
        ])
    }

    @Test func mysqlStatementsAndEscaping() throws {
        var e = TableEdits()
        e.set(.text(#"it's \ ok"#), row: 1, column: 1, original: rows[1][1])
        e.insertedRows.append([.null, .null, .null])
        let sql = try e.statements(table: table, dialect: .mysql, columns: columns, rows: rows, primaryKey: ["id", "name"])
        #expect(sql == [
            #"UPDATE `public`.`items` SET `name` = 'it''s \\ ok' WHERE `id` = 2 AND `name` = 'b''c'"#,
            "INSERT INTO `public`.`items` () VALUES ()",
        ])
    }

    @Test func revertingACellDropsTheUpdate() {
        var e = TableEdits()
        e.set(.text("z"), row: 0, column: 1, original: .text("a"))
        e.set(.text("a"), row: 0, column: 1, original: .text("a"))
        #expect(e.isEmpty)
    }

    @Test func requiresPrimaryKey() {
        #expect(throws: DatabaseError.self) {
            try sampleEdits().statements(table: table, dialect: .sqlite, columns: columns, rows: rows, primaryKey: [])
        }
    }

    @Test func applyOnSQLite() async throws {
        let c = try SQLiteConnection(path: ":memory:")
        _ = try await c.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, note TEXT)")
        _ = try await c.execute("INSERT INTO items VALUES (1, 'a', NULL), (2, 'b''c', 'x')")
        let t = TableInfo(schema: "main", name: "items", kind: .table)
        let sql = try sampleEdits().statements(table: t, dialect: .sqlite, columns: columns, rows: rows, primaryKey: ["id"])
        try await TableEdits.apply(sql, on: c)
        let after = try await c.execute("SELECT id, name, note FROM items ORDER BY id")
        #expect(after.rows == [[.integer(1), .text("A"), .null], [.integer(2), .text("new"), .null], [.integer(3), .null, .null]])

        // A row that no longer matches rolls the whole batch back.
        var stale = TableEdits()
        stale.set(.text("zzz"), row: 0, column: 1, original: .text("A"))
        stale.deletedRows.insert(1)
        let staleRows: [[SQLValue]] = [[.integer(1), .text("A"), .null], [.integer(99), .text("gone"), .null]]
        let bad = try stale.statements(table: t, dialect: .sqlite, columns: columns, rows: staleRows, primaryKey: ["id"])
        await #expect(throws: DatabaseError.self) { try await TableEdits.apply(bad, on: c) }
        #expect(try await c.strings("SELECT name FROM items WHERE id = 1") == ["A"])
        await c.close()
    }
}
