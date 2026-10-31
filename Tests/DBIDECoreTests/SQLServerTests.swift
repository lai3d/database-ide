import Foundation
import Testing

@testable import DBIDECore

/// DBIDE_MSSQL=host:port:user:password:database
@Suite(.enabled(if: ServerEnv.from("DBIDE_MSSQL") != nil), .serialized)
struct SQLServerTests {
    let env = ServerEnv.from("DBIDE_MSSQL")!

    func connect(_ db: String? = nil) async throws -> SQLServerConnection {
        try await SQLServerConnection.connect(host: env.host, port: env.port, user: env.user, password: env.password, database: db ?? "master")
    }

    func prepare() async throws -> SQLServerConnection {
        let m = try await connect()
        _ = try await m.execute("IF DB_ID('\(env.database)') IS NULL CREATE DATABASE [\(env.database)]")
        await m.close()
        return try await connect(env.database)
    }

    @Test func typesQueriesAndIntrospection() async throws {
        let c = try await prepare()
        #expect(c.serverVersion.hasPrefix("SQL Server 16"))
        #expect(c.database == env.database)
        _ = try await c.execute("DROP TABLE IF EXISTS dbo.orders; DROP TABLE IF EXISTS dbo.items")
        _ = try await c.execute("""
            CREATE TABLE dbo.items (
              id int IDENTITY(1,1) PRIMARY KEY, big bigint, flag bit, price decimal(10,2), cash money, ratio float,
              name nvarchar(50) NOT NULL, code varchar(10), data varbinary(max), uid uniqueidentifier,
              d date, ts datetime2(3), tz datetimeoffset(0), old datetime, note nvarchar(max))
            """)
        _ = try await c.execute("CREATE INDEX ix_items_name ON dbo.items(name)")
        _ = try await c.execute("CREATE TABLE dbo.orders (id int PRIMARY KEY, item_id int CONSTRAINT fk_order_item REFERENCES dbo.items(id))")
        let ins = try await c.execute("""
            INSERT INTO dbo.items (big, flag, price, cash, ratio, name, code, data, uid, d, ts, tz, old, note) VALUES
            (9000000000, 1, -12.34, 5.5, 0.25, N'Grüße 🚀', 'abc', 0xCAFE, '6F9619FF-8B86-D011-B42D-00C04FC964FF',
             '2024-02-29', '2024-02-29 13:45:06.789', '2024-02-29 13:45:06 +08:00', '2024-02-29 13:45:06.123', REPLICATE(CAST(N'x' AS nvarchar(max)), 10000)),
            (NULL, 0, NULL, NULL, NULL, N'b', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
            """)
        #expect(ins.affectedRows == 2)
        let r = try await c.execute("SELECT id, big, flag, price, cash, ratio, name, code, data, uid, d, ts, tz, old, LEN(note) AS notelen FROM dbo.items ORDER BY id")
        #expect(r.columns.map(\.typeName).prefix(9) == ["int", "bigint", "bit", "decimal(10,2)", "money", "float", "nvarchar(50)", "varchar(10)", "varbinary(max)"])
        #expect(r.rows[0] == [
            .integer(1), .integer(9_000_000_000), .text("true"), .text("-12.34"), .text("5.5000"), .real(0.25),
            .text("Grüße 🚀"), .text("abc"), .blob(Data([0xCA, 0xFE])), .text("6F9619FF-8B86-D011-B42D-00C04FC964FF"),
            .text("2024-02-29"), .text("2024-02-29 13:45:06.789"), .text("2024-02-29 05:45:06 +08:00 (UTC time)"),
            .text("2024-02-29 13:45:06.123"), .integer(10000),
        ])
        #expect(r.rows[1][1] == .null && r.rows[1][3] == .null && r.rows[1][8] == .null)

        // Many rows across packets; truncation.
        let many = try await c.execute("SELECT TOP 5000 a.object_id, a.name FROM sys.all_objects a CROSS JOIN sys.all_objects b", maxRows: 1000)
        #expect(many.rows.count == 1000 && many.truncated)

        // Errors carry number and line → position.
        do {
            _ = try await c.execute("SELECT 1\nSELECT nope FROM dbo.items")
            Issue.record("expected error")
        } catch let e as DatabaseError {
            #expect(e.code?.hasPrefix("207/") == true && e.position == 9)
        }

        // Transactions tracked from ENVCHANGE.
        _ = try await c.execute("BEGIN TRANSACTION")
        #expect(c.inTransaction)
        _ = try await c.execute("UPDATE dbo.items SET name = N'z' WHERE id = 2")
        _ = try await c.execute("ROLLBACK")
        #expect(!c.inTransaction)
        #expect(try await c.strings("SELECT name FROM dbo.items WHERE id = 2") == ["b"])

        let intro = Introspector(c)
        #expect(try await intro.schemas().first == "dbo")
        let tables = try await intro.tables(schema: "dbo")
        #expect(tables.map(\.name) == ["items", "orders"])
        let cols = try await intro.columns(schema: "dbo", table: "items")
        #expect(cols[0].type == "int IDENTITY(1,1)" && cols[0].isPrimaryKey && cols[6].type == "nvarchar(50)" && !cols[6].nullable)
        #expect(try await intro.indexes(schema: "dbo", table: "items").map(\.name).contains("ix_items_name"))
        let fks = try await intro.foreignKeys(schema: "dbo")
        #expect(fks.first?.name == "fk_order_item" && fks.first?.refTable == "items")
        let ddl = try await intro.ddl(for: tables[0])
        #expect(ddl.contains("CREATE TABLE [dbo].[items]") && ddl.contains("CREATE INDEX [ix_items_name]"))

        // Explain (estimated and actual).
        let plan = try await Explainer.explain("SELECT name FROM dbo.items WHERE name = N'b'", analyze: false, on: c)
        #expect(plan.root.allNodes.contains { $0.title.contains("Index Seek") || $0.title.contains("Scan") })
        let actual = try await Explainer.explain("SELECT COUNT(*) FROM dbo.items", analyze: true, on: c)
        #expect(actual.root.allNodes.contains { $0.actualRows != nil })

        // Table editing through TableEdits (BEGIN TRANSACTION).
        let page = try await c.execute(intro.selectSQL(tables[0], filter: "", orderBy: "id", limit: 10, offset: 0))
        var edits = TableEdits()
        edits.set(.text("edited"), row: 1, column: 6, original: page.rows[1][6])
        try await TableEdits.apply(try edits.statements(table: tables[0], dialect: .sqlserver, columns: page.columns, rows: page.rows, primaryKey: ["id"]), on: c)
        #expect(try await c.strings("SELECT name FROM dbo.items WHERE id = 2") == ["edited"])

        // Designer + CSV import.
        _ = try await c.execute("DROP TABLE IF EXISTS dbo.designed")
        var d = TableDesign(schema: "dbo", name: "designed", columns: [
            .init(id: "id", name: "id", type: "int", nullable: false, primaryKey: true), .init(id: "v", name: "v", type: "nvarchar(20)"),
        ])
        try await TableDesign.apply(d.createStatements(dialect: .sqlserver), on: c)
        let loaded = try await TableDesign.load(TableInfo(schema: "dbo", name: "designed", kind: .table), from: c)
        d = loaded
        d.columns[1].name = "value"
        d.columns[1].nullable = false
        d.columns.append(.init(name: "n", type: "int"))
        try await TableDesign.apply(d.alterStatements(from: loaded, dialect: .sqlserver), on: c)
        #expect(try await intro.columns(schema: "dbo", table: "designed").map(\.name) == ["id", "value", "n"])
        let csv = CSVImport(parsed: [["id", "value", "n"], ["1", "a", "3"], ["2", "b", ""]], firstRowIsHeader: true)
        let n = try await CSVImport.run(csv.insertStatements(schema: "dbo", table: "designed", mapping: ["id", "value", "n"], types: (0..<3).map(csv.inferType), emptyAsNull: true, dialect: .sqlserver), on: c)
        #expect(n == 2)

        _ = try await c.execute("DROP TABLE dbo.designed; DROP TABLE dbo.orders; DROP TABLE dbo.items")
        await c.close()
    }

    @Test func cancelWithAttention() async throws {
        let c = try await prepare()
        let task = Task { try await c.execute("WAITFOR DELAY '00:00:30'") }
        try await Task.sleep(for: .milliseconds(500))
        c.cancel()
        let start = Date()
        await #expect(throws: DatabaseError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(try await c.strings("SELECT 1") == ["1"])
        await c.close()
    }

    @Test func classicTLS() async throws {
        for mode in [SSLMode.require, .prefer] {
            let c = try await SQLServerConnection.connect(
                host: env.host, port: env.port, user: env.user, password: env.password, database: "master", tls: TLSOptions(mode: mode))
            #expect(c.securityDescription?.hasPrefix("TLSv1.") == true, "\(mode): \(c.securityDescription ?? "nil")")
            #expect(try await c.strings("SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID") == ["TRUE"])
            // Larger results flow through TLS records unchanged.
            let many = try await c.execute("SELECT TOP 3000 a.name FROM sys.all_objects a CROSS JOIN sys.all_objects b")
            #expect(many.rows.count == 3000)
            await c.close()
        }
        let plain = try await SQLServerConnection.connect(
            host: env.host, port: env.port, user: env.user, password: env.password, database: "master", tls: .disabled)
        #expect(plain.securityDescription == nil)
        #expect(try await plain.strings("SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID") == ["FALSE"])
        await plain.close()
    }

    @Test func wrongPassword() async throws {
        await #expect(throws: DatabaseError.self) {
            _ = try await SQLServerConnection.connect(host: env.host, port: env.port, user: env.user, password: "nope", database: "master")
        }
    }
}
