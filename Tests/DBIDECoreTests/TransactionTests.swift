import Foundation
import Testing

@testable import DBIDECore

/// Shared check: BEGIN → in transaction; failed statement keeps it open (PG: aborted); COMMIT/ROLLBACK → closed.
func checkTransactionTracking(_ c: any DatabaseConnection, begin: String = "BEGIN") async throws {
    #expect(!c.inTransaction)
    _ = try await c.execute(begin)
    #expect(c.inTransaction)
    _ = try await c.execute("SELECT 1")
    #expect(c.inTransaction)
    _ = try? await c.execute("SELECT * FROM no_such_table_xyz")
    #expect(c.inTransaction)
    _ = try await c.execute("ROLLBACK")
    #expect(!c.inTransaction)
    _ = try await c.execute(begin)
    _ = try await c.execute("COMMIT")
    #expect(!c.inTransaction)
}

@Suite struct TransactionTests {
    @Test func sqlite() async throws {
        let c = try SQLiteConnection(path: ":memory:")
        try await checkTransactionTracking(c)
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_PG") != nil)) func postgres() async throws {
        let e = ServerEnv.from("DBIDE_PG")!
        let c = try await PostgresConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        try await checkTransactionTracking(c)
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_MYSQL") != nil)) func mysql() async throws {
        let e = ServerEnv.from("DBIDE_MYSQL")!
        let c = try await MySQLConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        try await checkTransactionTracking(c, begin: "START TRANSACTION")
        await c.close()
    }
}
