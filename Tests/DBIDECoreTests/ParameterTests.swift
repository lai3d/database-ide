import Testing

@testable import DBIDECore

@Suite struct ParameterTests {
    @Test func postgres() {
        let sql = "select * from t where a = :id and b = $1 and c::int = :id and j ? 'k' and s = ':nope' -- :nope2"
        #expect(SQLParameters.names(in: sql, dialect: .postgres) == [":id", "$1"])
        let out = SQLParameters.substitute(sql, values: [":id": "42", "$1": "'x'"], dialect: .postgres)
        #expect(out == "select * from t where a = 42 and b = 'x' and c::int = 42 and j ? 'k' and s = ':nope' -- :nope2")
    }

    @Test func positionalAndMySQLVariables() {
        let sql = "select ?, ?, @v from t where x = :x"
        #expect(SQLParameters.names(in: sql, dialect: .mysql) == ["?1", "?2", ":x"])
        #expect(SQLParameters.substitute(sql, values: ["?1": "1", "?2": "NULL", ":x": "'a'"], dialect: .mysql)
            == "select 1, NULL, @v from t where x = 'a'")
    }

    @Test func none() {
        #expect(SQLParameters.names(in: "select 'a:b', $$ :x $$, arr[1:2]", dialect: .postgres).isEmpty)
    }
}
