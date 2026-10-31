import Foundation
import Testing

@testable import DBIDECore

@Suite struct ERLayoutTests {
    @Test func layersParentsFirst() {
        let l = ERLayout.layers(
            tables: ["order_items", "orders", "customers", "products", "audit"],
            foreignKeys: [("orders", "customers"), ("order_items", "orders"), ("order_items", "products"), ("audit", "audit")])
        #expect(l["customers"] == 0 && l["products"] == 0 && l["audit"] == 0)
        #expect(l["orders"] == 1 && l["order_items"] == 2)
    }

    @Test func cyclesTerminate() {
        let l = ERLayout.layers(tables: ["a", "b", "c"], foreignKeys: [("a", "b"), ("b", "c"), ("c", "a")])
        #expect(l.count == 3)
        let g = ERLayout.grid(tables: ["a", "b", "c"], foreignKeys: [("a", "b")])
        #expect(g["b"]!.column == 0 && g["a"]!.column == 1)
    }
}

@Suite struct ForeignKeyTests {
    @Test func sqlite() async throws {
        let c = try SQLiteConnection(path: ":memory:")
        _ = try await c.execute("CREATE TABLE c (id INTEGER PRIMARY KEY)")
        _ = try await c.execute("CREATE TABLE p (a INT, b INT, PRIMARY KEY (a, b))")
        _ = try await c.execute("CREATE TABLE o (id INT, cid INT REFERENCES c, pa INT, pb INT, FOREIGN KEY (pa, pb) REFERENCES p(a, b))")
        let fks = try await Introspector(c).foreignKeys(schema: "main").sorted { $0.refTable < $1.refTable }
        #expect(fks.count == 2)
        #expect(fks[0].table == "o" && fks[0].columns == ["cid"] && fks[0].refTable == "c" && fks[0].refColumns == ["id"])
        #expect(fks[1].columns == ["pa", "pb"] && fks[1].refColumns == ["a", "b"])
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_PG") != nil)) func postgres() async throws {
        let e = ServerEnv.from("DBIDE_PG")!
        let c = try await PostgresConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        _ = try await c.execute("DROP SCHEMA IF EXISTS fk_t CASCADE")
        _ = try await c.execute("CREATE SCHEMA fk_t")
        _ = try await c.execute("CREATE TABLE fk_t.p (a int, b int, PRIMARY KEY (a, b))")
        _ = try await c.execute("CREATE TABLE fk_t.o (id int, pb int, pa int, CONSTRAINT o_p FOREIGN KEY (pa, pb) REFERENCES fk_t.p (a, b))")
        let fks = try await Introspector(c).foreignKeys(schema: "fk_t")
        #expect(fks == [ForeignKeyInfo(name: "o_p", schema: "fk_t", table: "o", columns: ["pa", "pb"], refSchema: "fk_t", refTable: "p", refColumns: ["a", "b"])])
        _ = try await c.execute("DROP SCHEMA fk_t CASCADE")
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_MYSQL") != nil)) func mysql() async throws {
        let e = ServerEnv.from("DBIDE_MYSQL")!
        let c = try await MySQLConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        _ = try await c.execute("DROP TABLE IF EXISTS fk_o, fk_p")
        _ = try await c.execute("CREATE TABLE fk_p (a int, b int, PRIMARY KEY (a, b))")
        _ = try await c.execute("CREATE TABLE fk_o (id int, pa int, pb int, CONSTRAINT o_p FOREIGN KEY (pa, pb) REFERENCES fk_p (a, b))")
        let fks = try await Introspector(c).foreignKeys(schema: e.database)
        #expect(fks.first { $0.name == "o_p" } == ForeignKeyInfo(name: "o_p", schema: e.database, table: "fk_o", columns: ["pa", "pb"], refSchema: e.database, refTable: "fk_p", refColumns: ["a", "b"]))
        _ = try await c.execute("DROP TABLE fk_o, fk_p")
        await c.close()
    }
}
