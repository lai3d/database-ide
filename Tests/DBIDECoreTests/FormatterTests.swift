import Foundation
import Testing

@testable import DBIDECore

@Suite struct FormatterTests {
    func fmt(_ s: String, _ d: SQLDialect = .postgres) -> String { SQLFormatter.format(s, dialect: d) }

    @Test func basicSelect() {
        let out = fmt("select a, b,count(*) from t left join u on u.id=t.uid and u.x between 1 and 2 where t.x>=1 and t.y is not null or z group by a order by b desc limit 10")
        #expect(out == """
            SELECT a,
                   b,
                   count(*)
            FROM t
            LEFT JOIN u ON u.id=t.uid
              AND u.x BETWEEN 1 AND 2
            WHERE t.x>=1
              AND t.y IS NOT NULL
              OR z
            GROUP BY a
            ORDER BY b DESC
            LIMIT 10
            """)
    }

    @Test func subqueryAndFunctionParens() {
        let out = fmt("select * from (select id from t where extract(year from d) = 2024) s where id in (1,2)")
        #expect(out == """
            SELECT *
            FROM (
                SELECT id
                FROM t
                WHERE extract(year FROM d) = 2024
            ) s
            WHERE id IN (1, 2)
            """)
    }

    @Test func dmlAndScripts() {
        let out = fmt("insert into t (a,b) values (1,'x;y'); update t set a = 2 where b = 'x' returning *;\n")
        #expect(out == """
            INSERT INTO t (a, b)
            VALUES (1, 'x;y');

            UPDATE t
            SET a = 2
            WHERE b = 'x'
            RETURNING *;

            """)
    }

    @Test func keepsCommentsAndCasts() {
        let out = fmt("select a::int -- why\n, b from t /* c */ where j->>'k' = $1")
        #expect(out.contains("a::INT -- why\n"))
        #expect(out.contains("j->>'k' = $1"))
        #expect(out.contains("/* c */"))
    }

    @Test func idempotentAndTokenPreserving() {
        let samples = [
            "select a, b from t where x = 1 and y = 2",
            "with c as (select 1 as x) select * from c join d using (x) union all select 2, 3",
            "SELECT \"Mixed Col\", `m`, 'str''q', E'x\\'y' FROM s.t AS a CROSS JOIN b WHERE a.ts > now() - interval '1 day'",
            "create table t (id int primary key, ts timestamp with time zone default now())",
            "select count(*) over (partition by a order by b) from t for update",
        ]
        for s in samples {
            let once = fmt(s)
            #expect(fmt(once) == once, "not idempotent: \(s)")
            let a = SQLLexer.tokenize(s).map { (s as NSString).substring(with: $0.range).uppercased() }
            let b = SQLLexer.tokenize(once).map { (once as NSString).substring(with: $0.range).uppercased() }
            #expect(a == b, "tokens changed: \(s)")
        }
    }

    @Test func mysqlDelimiterScriptsUntouched() {
        let s = "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; END$$\nDELIMITER ;"
        #expect(fmt(s, .mysql) == s)
    }
}
