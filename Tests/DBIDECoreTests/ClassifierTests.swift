import Testing

@testable import DBIDECore

@Suite struct ClassifierTests {
    @Test func reads() {
        for s in ["select * from t", "  -- c\nSELECT 1", "show tables", "explain select 1", "with x as (select 1) select * from x",
                  "SELECT * FROM t FOR UPDATE", "begin", "commit", "set search_path to a", "pragma table_info(t)", ""] {
            #expect(SQLClassifier.isReadOnly(s), "\(s)")
        }
    }

    @Test func writes() {
        for s in ["insert into t values (1)", "update t set a=1", "delete from t", "drop table t", "create index i on t(a)",
                  "with d as (delete from t returning *) select * from d", "select * into t2 from t",
                  "explain analyze delete from t", "truncate t", "call p()", "alter table t add c int", "vacuum"] {
            #expect(!SQLClassifier.isReadOnly(s), "\(s)")
        }
    }
}
