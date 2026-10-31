import Foundation
import Testing

@testable import DBIDECore

@Suite struct SplitterTests {
    @Test func splitsOnSemicolons() {
        let s = SQLSplitter.split("select 1;\n  select 2 ;\n\nselect 3", dialect: .postgres)
        #expect(s.map(\.text) == ["select 1", "select 2", "select 3"])
    }

    @Test func ignoresSemicolonsInStringsAndComments() {
        let sql = """
            select 'a;b', "x;y" from t; -- c;d
            /* e; /* nested; */ f; */ select $$ g; $$, $tag$ h; $tag$;
            select E'it\\'s;';
            """
        let s = SQLSplitter.split(sql, dialect: .postgres)
        #expect(s.count == 3)
        #expect(s[0].text == #"select 'a;b', "x;y" from t"#)
        #expect(s[1].text.hasPrefix("-- c;d"))
        #expect(s[2].text == #"select E'it\'s;'"#)
    }

    @Test func dropsCommentOnlyPieces() {
        let s = SQLSplitter.split("select 1; -- trailing comment\n", dialect: .sqlite)
        #expect(s.map(\.text) == ["select 1"])
    }

    @Test func sqliteTriggerBody() {
        let sql = """
            CREATE TRIGGER t AFTER INSERT ON a BEGIN
              INSERT INTO log VALUES (CASE WHEN new.x > 0 THEN 1 ELSE 0 END);
              UPDATE b SET n = n + 1;
            END;
            SELECT 1;
            """
        let s = SQLSplitter.split(sql, dialect: .sqlite)
        #expect(s.count == 2)
        #expect(s[0].text.hasSuffix("END"))
    }

    @Test func mysqlDelimiter() {
        let sql = """
            DELIMITER $$
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$
            DELIMITER ;
            CALL p();
            SELECT 'x\\';y';
            """
        let s = SQLSplitter.split(sql, dialect: .mysql)
        #expect(s.map(\.text) == ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "CALL p()", #"SELECT 'x\';y'"#])
    }

    @Test func statementAtCaret() {
        let sql = "select 1;\nselect 2;\n\nselect 3"
        let ns = sql as NSString
        #expect(SQLSplitter.statement(at: 3, in: sql, dialect: .postgres)?.text == "select 1")
        // Caret right after `;` belongs to the statement it ends.
        #expect(SQLSplitter.statement(at: ns.range(of: "2;").location + 2, in: sql, dialect: .postgres)?.text == "select 2")
        #expect(SQLSplitter.statement(at: ns.length, in: sql, dialect: .postgres)?.text == "select 3")
        // Blank line between statements → next statement.
        #expect(SQLSplitter.statement(at: ns.range(of: "\n\n").location + 1, in: sql, dialect: .postgres)?.text == "select 3")
    }

    @Test func rangesAreUTF16() {
        let sql = "select '😀';select 2"
        let s = SQLSplitter.split(sql, dialect: .postgres)
        #expect((sql as NSString).substring(with: s[1].range) == "select 2")
    }
}

@Suite struct LexerTests {
    @Test func tokenKinds() {
        let sql = "SELECT a, \"B\", 'x''y', 1.5e3, $1, :name FROM t -- hi\nWHERE x::int > 0"
        let toks = SQLLexer.tokenize(sql, dialect: .postgres)
        let ns = sql as NSString
        func kind(of text: String) -> SQLTokenKind? {
            toks.first { ns.substring(with: $0.range) == text }?.kind
        }
        #expect(kind(of: "SELECT") == .keyword)
        #expect(kind(of: "a") == .identifier)
        #expect(kind(of: "\"B\"") == .quotedIdentifier)
        #expect(kind(of: "'x''y'") == .string)
        #expect(kind(of: "1.5e3") == .number)
        #expect(kind(of: "$1") == .parameter)
        #expect(kind(of: ":name") == .parameter)
        #expect(kind(of: "-- hi") == .comment)
        #expect(kind(of: "int") == .keyword)
    }

    @Test func leadingKeywords() {
        #expect(SQLLexer.leadingKeywords("/* x */ create table foo (a int)", count: 2) == "create table")
    }
}

@Suite struct ExportTests {
    let cols = [ResultColumn(name: "id", typeName: "int"), ResultColumn(name: "name", typeName: "text")]
    let rows: [[SQLValue]] = [[.integer(1), .text("a,\"b\"")], [.integer(2), .null]]

    @Test func csv() {
        #expect(ResultExport.render(columns: cols, rows: rows, format: .csv) == "id,name\n1,\"a,\"\"b\"\"\"\n2,\n")
    }

    @Test func inserts() {
        let out = ResultExport.render(columns: cols, rows: rows, format: .sqlInsert, dialect: .mysql, tableName: "t")
        #expect(out == "INSERT INTO t (`id`, `name`) VALUES (1, 'a,\"b\"');\nINSERT INTO t (`id`, `name`) VALUES (2, NULL);\n")
    }

    @Test func json() {
        let out = ResultExport.render(columns: cols, rows: rows, format: .json)
        let parsed = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?[1]["name"] is NSNull)
    }
}

@Suite struct AuthTests {
    /// RFC 7677 test vector.
    @Test func scramSHA256() throws {
        let c = SCRAMClient(password: "pencil", nonce: "rOprNGfwEbeRWgbNEkqO", user: "user")
        let final = try c.clientFinalMessage(
            serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(final == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try c.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }
}

@Suite struct SQLiteTests {
    @Test func roundTripAndIntrospection() async throws {
        let conn = try SQLiteConnection(path: ":memory:")
        _ = try await conn.execute(
            "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, avatar BLOB)")
        _ = try await conn.execute("CREATE INDEX users_name ON users(name)")
        let ins = try await conn.execute(
            "INSERT INTO users (name, score, avatar) VALUES ('ann', 1.5, x'CAFE'), ('bob', NULL, NULL)")
        #expect(ins.affectedRows == 2)
        #expect(ins.message == "INSERT INTO")

        let res = try await conn.execute("SELECT * FROM users ORDER BY id")
        #expect(res.columns.map(\.name) == ["id", "name", "score", "avatar"])
        #expect(res.rows[0] == [.integer(1), .text("ann"), .real(1.5), .blob(Data([0xCA, 0xFE]))])
        #expect(res.rows[1][2] == .null)

        let limited = try await conn.execute("SELECT * FROM users", maxRows: 1)
        #expect(limited.rows.count == 1 && limited.truncated)

        let intro = Introspector(conn)
        #expect(try await intro.schemas() == ["main"])
        let tables = try await intro.tables(schema: "main")
        #expect(tables.map(\.name) == ["users"])
        let cols = try await intro.columns(schema: "main", table: "users")
        #expect(cols.first?.isPrimaryKey == true)
        #expect(cols[1].nullable == false)
        let idx = try await intro.indexes(schema: "main", table: "users")
        #expect(idx.map(\.name) == ["users_name"])
        let ddl = try await intro.ddl(for: tables[0])
        #expect(ddl.contains("CREATE TABLE users") && ddl.contains("CREATE INDEX users_name"))

        await #expect(throws: DatabaseError.self) { try await conn.execute("SELEC 1") }
        await conn.close()
    }
}
