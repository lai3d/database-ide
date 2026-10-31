import Foundation
import Testing

@testable import DBIDECore

/// Pages through 1…total with a cursor and checks continuity, then that the connection is reusable.
func checkCursor(_ c: any CursorCapable, sql: String, total: Int, page: Int) async throws {
    let first = try await c.openCursor(sql, pageSize: page)
    #expect(first.rows.count == page && first.truncated && c.hasOpenCursor)
    var seen = first.rows.map { $0[0] }
    var more = true
    while more {
        let (rows, hasMore) = try await c.fetchMore(page)
        seen += rows.map { $0[0] }
        more = hasMore
    }
    #expect(seen.count == total)
    #expect(seen.enumerated().allSatisfy { $0.element == .integer(Int64($0.offset + 1)) })
    #expect(!c.hasOpenCursor)
    // A fresh cursor is closed by the next ordinary statement.
    _ = try await c.openCursor(sql, pageSize: page)
    #expect(c.hasOpenCursor)
}

@Suite struct CursorTests {
    @Test func sqlite() async throws {
        let c = try SQLiteConnection(path: ":memory:")
        _ = try await c.execute("CREATE TABLE t (n INTEGER)")
        _ = try await c.execute("WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 1234) INSERT INTO t SELECT n FROM s")
        try await checkCursor(c, sql: "SELECT n FROM t ORDER BY n", total: 1234, page: 500)
        #expect(try await c.strings("SELECT count(*) FROM t") == ["1234"])
        #expect(!c.hasOpenCursor)
        // Exactly one page: no more rows.
        let exact = try await c.openCursor("SELECT n FROM t WHERE n <= 10", pageSize: 10)
        #expect(exact.rows.count == 10 && !exact.truncated)
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_PG") != nil)) func postgres() async throws {
        let e = ServerEnv.from("DBIDE_PG")!
        let c = try await PostgresConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        try await checkCursor(c, sql: "SELECT n FROM generate_series(1, 2500) n", total: 2500, page: 1000)
        #expect(try await c.strings("SELECT 41 + 1") == ["42"])
        #expect(!c.hasOpenCursor)
        // Errors leave the session usable.
        await #expect(throws: DatabaseError.self) { _ = try await c.openCursor("SELECT nope", pageSize: 10) }
        #expect(try await c.strings("SELECT 1") == ["1"])
        // A 10-million-row query returns its first page without materializing everything.
        let start = Date()
        let big = try await c.openCursor("SELECT n FROM generate_series(1, 10000000) n", pageSize: 500)
        #expect(big.rows.count == 500 && big.truncated && Date().timeIntervalSince(start) < 3)
        await c.closeCursor()
        await c.close()
    }

    @Test(.enabled(if: MongoEnv.current != nil)) func mongo() async throws {
        let env = MongoEnv.current!
        let c = try await MongoConnection.connect(host: env.host, port: env.port, user: env.user, password: env.password, database: "dbide_cursor")
        _ = try await c.execute("db.dropDatabase()")
        let docs = (1...1500).map { "{ n: \($0) }" }.joined(separator: ", ")
        _ = try await c.execute("db.t.insertMany([\(docs)])")
        let first = try await c.openCursor("db.t.find({}, { _id: 0, n: 1 }).sort({ n: 1 })", pageSize: 400)
        #expect(first.rows.count == 400 && first.truncated && c.hasOpenCursor)
        var seen = first.rows.map { $0[0] }
        var more = true
        while more {
            let (rows, hasMore) = try await c.fetchMore(400)
            seen += rows.map { $0[0] }
            more = hasMore
        }
        #expect(seen.count == 1500 && seen.last == .integer(1500))
        _ = try await c.execute("db.dropDatabase()")
        await c.close()
    }
}
