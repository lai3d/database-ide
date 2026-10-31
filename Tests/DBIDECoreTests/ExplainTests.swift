import Foundation
import Testing

@testable import DBIDECore

@Suite struct ExplainTests {
    @Test func mysqlTreeParsing() {
        let text = """
            -> Limit: 5 row(s)  (cost=2.5 rows=5) (actual time=0.1..0.9 rows=5 loops=1)
                -> Nested loop inner join  (cost=2.5 rows=10) (actual time=0.1..0.8 rows=5 loops=1)
                    -> Table scan on p  (cost=1 rows=10) (actual time=0.05..0.3 rows=10 loops=1)
                    -> Single-row index lookup on r using PRIMARY (id=p.id)  (cost=0.1 rows=1) (actual time=0.02..0.02 rows=0.5 loops=10)
            """
        let r = Explainer.parseMySQLTree(text, analyzed: true)
        #expect(r.root.title == "Limit: 5 row(s)")
        #expect(r.root.totalCost == 2.5 && r.root.planRows == 5)
        let join = r.root.children[0]
        #expect(join.title == "Nested loop inner join" && join.children.count == 2)
        let lookup = join.children[1]
        #expect(lookup.title == "Single-row index lookup on r using PRIMARY (id=p.id)")
        #expect(lookup.actualTime == 0.02 && lookup.loops == 10 && lookup.actualRows == 0.5)
        #expect(abs((lookup.inclusiveTime ?? 0) - 0.2) < 1e-9)
        // join: 0.8 total minus children 0.3 + 0.2
        #expect(abs((join.exclusiveTime ?? 0) - 0.3) < 1e-9)
        #expect(r.root.allNodes.count == 4)
    }

    @Test func sqlitePlan() async throws {
        let c = try SQLiteConnection(path: ":memory:")
        _ = try await c.execute("CREATE TABLE a (id INTEGER PRIMARY KEY, x)")
        _ = try await c.execute("CREATE TABLE b (id INTEGER PRIMARY KEY, a_id)")
        let r = try await Explainer.explain("SELECT * FROM a JOIN b ON b.a_id = a.id WHERE a.x = 1 ORDER BY b.id", analyze: false, on: c)
        let titles = r.root.allNodes.map(\.title).joined(separator: " | ")
        #expect(titles.contains("SCAN") || titles.contains("SEARCH"))
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_PG") != nil)) func postgresPlan() async throws {
        let e = ServerEnv.from("DBIDE_PG")!
        let c = try await PostgresConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        _ = try await c.execute("CREATE TEMP TABLE ex (id int primary key, v int)")
        _ = try await c.execute("INSERT INTO ex SELECT g, g % 7 FROM generate_series(1, 1000) g")
        let plain = try await Explainer.explain("SELECT v, count(*) FROM ex WHERE id > 10 GROUP BY v ORDER BY 2 DESC;", analyze: false, on: c)
        #expect(plain.root.totalCost != nil && plain.root.actualTime == nil)
        #expect(plain.root.allNodes.contains { $0.title.contains("on ex") })

        let analyzed = try await Explainer.explain("SELECT * FROM ex WHERE v = 3", analyze: true, on: c)
        #expect(analyzed.executionTime != nil && analyzed.root.actualRows == 143)
        #expect(analyzed.root.details.contains { $0.hasPrefix("Filter:") })

        // ANALYZE of DML runs in a rolled-back transaction.
        _ = try await Explainer.explain("UPDATE ex SET v = 99", analyze: true, on: c)
        #expect(try await c.strings("SELECT count(*) FROM ex WHERE v = 99") == ["0"])
        #expect(!c.inTransaction)
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_MYSQL") != nil)) func mysqlPlan() async throws {
        let e = ServerEnv.from("DBIDE_MYSQL")!
        let c = try await MySQLConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        _ = try await c.execute("DROP TABLE IF EXISTS ex")
        _ = try await c.execute("CREATE TABLE ex (id int primary key, v int, KEY v_idx (v))")
        _ = try await c.execute("INSERT INTO ex VALUES (1,1),(2,2),(3,3),(4,3)")
        let plain = try await Explainer.explain("SELECT * FROM ex WHERE v = 3", analyze: false, on: c)
        #expect(plain.root.allNodes.contains { $0.title.contains("v_idx") })
        let analyzed = try await Explainer.explain("SELECT * FROM ex WHERE v = 3", analyze: true, on: c)
        #expect(analyzed.root.actualRows == 2)
        _ = try await c.execute("DROP TABLE ex")
        await c.close()
    }
}
