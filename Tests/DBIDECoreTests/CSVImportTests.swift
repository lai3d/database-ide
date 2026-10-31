import Foundation
import Testing

@testable import DBIDECore

@Suite struct CSVParserTests {
    @Test func rfc4180() {
        let text = "\u{FEFF}id,name,note\r\n1,\"Smith, J\",\"said \"\"hi\"\"\"\r\n2,Ann,\"multi\nline\"\n\n3,,\n"
        let rows = CSVParser.parse(text, delimiter: ",")
        #expect(rows == [
            ["id", "name", "note"],
            ["1", "Smith, J", "said \"hi\""],
            ["2", "Ann", "multi\nline"],
            ["3", "", ""],
        ])
    }

    @Test func noTrailingNewlineAndQuoteInside() {
        #expect(CSVParser.parse("a;b\n5\"x;y", delimiter: ";") == [["a", "b"], ["5\"x", "y"]])
    }

    @Test func detectDelimiter() {
        #expect(CSVParser.detectDelimiter("a;b;c\n1;2;3\n") == ";")
        #expect(CSVParser.detectDelimiter("a\tb\n1\t2") == "\t")
        #expect(CSVParser.detectDelimiter("a,b\n1,2") == ",")
        #expect(CSVParser.detectDelimiter("single") == ",")
    }
}

@Suite struct CSVImportTests {
    let csv = CSVImport(parsed: [
        ["id", "price", "ok", "code", "name", "Name", ""],
        ["1", "2.5", "true", "007", "a", "x", ""],
        ["2", "", "false", "010", "it's", "y", ""],
        ["3", "1e3", "TRUE", "12", "", "z", ""],
    ], firstRowIsHeader: true)

    @Test func headerAndInference() {
        #expect(csv.header == ["id", "price", "ok", "code", "name", "Name_2", "column7"])
        #expect((0..<7).map(csv.inferType) == [.integer, .real, .boolean, .text, .text, .text, .text])
    }

    @Test func statements() {
        let types = (0..<7).map(csv.inferType)
        let sql = csv.insertStatements(
            schema: nil, table: "t", mapping: ["id", "price", "ok", "code", "name", nil, nil], types: types,
            emptyAsNull: true, dialect: .postgres, batchSize: 2)
        #expect(sql.count == 2)
        #expect(sql[0] == """
            INSERT INTO "t" ("id", "price", "ok", "code", "name") VALUES
            (1, 2.5, TRUE, '007', 'a'),
            (2, NULL, FALSE, '010', 'it''s')
            """)
        #expect(csv.createTableSQL(schema: "s", table: "t", types: types, dialect: .mysql).contains("`price` DOUBLE"))
    }

    @Test func importIntoSQLite() async throws {
        let c = try SQLiteConnection(path: ":memory:")
        let types = (0..<7).map(csv.inferType)
        _ = try await c.execute(csv.createTableSQL(schema: "main", table: "imp", types: types, dialect: .sqlite))
        let mapping = csv.autoMapping(to: csv.header)
        let n = try await CSVImport.run(
            csv.insertStatements(schema: "main", table: "imp", mapping: mapping, types: types, emptyAsNull: true, dialect: .sqlite),
            on: c)
        #expect(n == 3)
        let r = try await c.execute("SELECT id, price, ok, code FROM imp ORDER BY id")
        #expect(r.rows[0] == [.integer(1), .real(2.5), .integer(1), .text("007")])
        #expect(r.rows[1][1] == .null)
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_PG") != nil)) func importIntoPostgres() async throws {
        let e = ServerEnv.from("DBIDE_PG")!
        let c = try await PostgresConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        let types = (0..<7).map(csv.inferType)
        _ = try await c.execute("DROP TABLE IF EXISTS csv_imp")
        _ = try await c.execute(csv.createTableSQL(schema: nil, table: "csv_imp", types: types, dialect: .postgres))
        let stmts = csv.insertStatements(schema: nil, table: "csv_imp", mapping: csv.autoMapping(to: csv.header), types: types, emptyAsNull: true, dialect: .postgres)
        #expect(try await CSVImport.run(stmts, on: c) == 3)
        #expect(try await c.strings("SELECT ok::text || code FROM csv_imp ORDER BY id") == ["true007", "false010", "true12"])
        // A bad row rolls back the whole import.
        let bad = CSVImport(parsed: [["id"], ["4"], ["oops"]], firstRowIsHeader: true)
        await #expect(throws: DatabaseError.self) {
            _ = try await CSVImport.run(bad.insertStatements(schema: nil, table: "csv_imp", mapping: ["id"], emptyAsNull: true, dialect: .postgres, batchSize: 1), on: c)
        }
        #expect(try await c.strings("SELECT count(*) FROM csv_imp") == ["3"])
        _ = try await c.execute("DROP TABLE csv_imp")
        await c.close()
    }

    @Test(.enabled(if: ServerEnv.from("DBIDE_MYSQL") != nil)) func importIntoMySQL() async throws {
        let e = ServerEnv.from("DBIDE_MYSQL")!
        let c = try await MySQLConnection.connect(host: e.host, port: e.port, user: e.user, password: e.password, database: e.database)
        let types = (0..<7).map(csv.inferType)
        _ = try await c.execute("DROP TABLE IF EXISTS csv_imp")
        _ = try await c.execute(csv.createTableSQL(schema: nil, table: "csv_imp", types: types, dialect: .mysql))
        let stmts = csv.insertStatements(schema: nil, table: "csv_imp", mapping: csv.autoMapping(to: csv.header), types: types, emptyAsNull: true, dialect: .mysql)
        #expect(try await CSVImport.run(stmts, on: c) == 3)
        #expect(try await c.strings("SELECT CONCAT(ok, code, name) FROM csv_imp WHERE id = 2") == ["0010it's"])
        _ = try await c.execute("DROP TABLE csv_imp")
        await c.close()
    }
}
