import Foundation

public enum TableKind: String, Sendable, Hashable {
    case table, view, materializedView

    public var label: String {
        switch self {
        case .table: "table"
        case .view: "view"
        case .materializedView: "materialized view"
        }
    }
}

public struct TableInfo: Sendable, Hashable, Identifiable {
    public var schema: String
    public var name: String
    public var kind: TableKind
    public var comment: String?
    public var id: String { schema + "." + name }
}

public struct ColumnInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var type: String
    public var nullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var comment: String?
    public var id: String { name }
}

public struct IndexInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var columns: [String]
    public var unique: Bool
    public var primary: Bool
    public var id: String { name }
}

public struct ForeignKeyInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var schema: String
    public var table: String
    public var columns: [String]
    public var refSchema: String
    public var refTable: String
    public var refColumns: [String]
    public var id: String { schema + "." + table + "." + name }

    public init(name: String, schema: String, table: String, columns: [String], refSchema: String, refTable: String, refColumns: [String]) {
        self.name = name
        self.schema = schema
        self.table = table
        self.columns = columns
        self.refSchema = refSchema
        self.refTable = refTable
        self.refColumns = refColumns
    }
}

public struct RoutineInfo: Sendable, Hashable, Identifiable {
    public var schema: String
    public var name: String
    public var kind: String
    public var id: String { schema + "." + name + kind }
}

/// Reads catalog metadata using dialect-specific catalog queries.
public struct Introspector: Sendable {
    public let connection: any DatabaseConnection
    public var dialect: SQLDialect { connection.dialect }

    public init(_ connection: any DatabaseConnection) { self.connection = connection }

    private func lit(_ s: String) -> String { dialect.literal(s) }
    private var mongo: MongoConnection? { connection as? MongoConnection }

    // MARK: Schemas

    public func schemas() async throws -> [String] {
        if let m = mongo { return try await m.introspectDatabases() }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .sqlite:
            return try await connection.execute("PRAGMA database_list").rows.compactMap {
                $0.count > 1 ? $0[1].displayString : nil
            }
        case .postgres:
            return try await connection.strings(
                """
                SELECT nspname FROM pg_namespace
                WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
                ORDER BY nspname = 'public' DESC, nspname
                """)
        case .mysql:
            return try await connection.strings(
                """
                SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
                WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys')
                ORDER BY SCHEMA_NAME
                """)
        }
    }

    /// Schema the session uses by default.
    public func currentSchema() async throws -> String? {
        if let m = mongo { return m.database }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .sqlite: return "main"
        case .postgres: return try await connection.strings("SELECT current_schema()").first
        case .mysql: return try await connection.strings("SELECT DATABASE()").first
        }
    }

    // MARK: Tables

    public func tables(schema: String) async throws -> [TableInfo] {
        if let m = mongo { return try await m.introspectCollections(schema) }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .sqlite:
            let rows = try await connection.execute(
                """
                SELECT name, type FROM \(dialect.quote(schema)).sqlite_master
                WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
                ORDER BY name
                """
            ).rows
            return rows.map {
                TableInfo(schema: schema, name: $0[0].displayString, kind: $0[1].displayString == "view" ? .view : .table)
            }
        case .postgres:
            let rows = try await connection.execute(
                """
                SELECT c.relname, c.relkind::text, obj_description(c.oid, 'pg_class')
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(lit(schema)) AND c.relkind IN ('r','p','v','m','f')
                ORDER BY c.relname
                """
            ).rows
            return rows.map {
                let k = $0[1].displayString
                return TableInfo(
                    schema: schema, name: $0[0].displayString,
                    kind: k == "v" ? .view : k == "m" ? .materializedView : .table,
                    comment: $0[2].isNull ? nil : $0[2].displayString)
            }
        case .mysql:
            let rows = try await connection.execute(
                """
                SELECT TABLE_NAME, TABLE_TYPE, TABLE_COMMENT FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = \(lit(schema)) ORDER BY TABLE_NAME
                """
            ).rows
            return rows.map {
                let comment = $0[2].displayString
                return TableInfo(
                    schema: schema, name: $0[0].displayString,
                    kind: $0[1].displayString == "VIEW" ? .view : .table,
                    comment: $0[2].isNull || comment.isEmpty ? nil : comment)
            }
        }
    }

    // MARK: Columns

    public func columns(schema: String, table: String) async throws -> [ColumnInfo] {
        if let m = mongo { return try await m.introspectFields(schema, table) }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .sqlite:
            let rows = try await connection.execute(
                "PRAGMA \(dialect.quote(schema)).table_info(\(dialect.quote(table)))"
            ).rows
            // cid, name, type, notnull, dflt_value, pk
            return rows.map {
                ColumnInfo(
                    name: $0[1].displayString, type: $0[2].displayString,
                    nullable: $0[3].displayString == "0",
                    defaultValue: $0[4].isNull ? nil : $0[4].displayString,
                    isPrimaryKey: $0[5].displayString != "0")
            }
        case .postgres:
            let rows = try await connection.execute(
                """
                SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
                       pg_get_expr(d.adbin, d.adrelid),
                       EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
                               AND a.attnum = ANY(i.indkey)),
                       col_description(c.oid, a.attnum)
                FROM pg_attribute a
                JOIN pg_class c ON c.oid = a.attrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                WHERE n.nspname = \(lit(schema)) AND c.relname = \(lit(table))
                  AND a.attnum > 0 AND NOT a.attisdropped
                ORDER BY a.attnum
                """
            ).rows
            return rows.map {
                ColumnInfo(
                    name: $0[0].displayString, type: $0[1].displayString,
                    nullable: $0[2].displayString == "true",
                    defaultValue: $0[3].isNull ? nil : $0[3].displayString,
                    isPrimaryKey: $0[4].displayString == "true",
                    comment: $0[5].isNull ? nil : $0[5].displayString)
            }
        case .mysql:
            let rows = try await connection.execute(
                """
                SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, COLUMN_COMMENT
                FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = \(lit(schema)) AND TABLE_NAME = \(lit(table))
                ORDER BY ORDINAL_POSITION
                """
            ).rows
            return rows.map {
                let comment = $0[5].displayString
                return ColumnInfo(
                    name: $0[0].displayString, type: $0[1].displayString,
                    nullable: $0[2].displayString == "YES",
                    defaultValue: $0[3].isNull ? nil : $0[3].displayString,
                    isPrimaryKey: $0[4].displayString == "PRI",
                    comment: $0[5].isNull || comment.isEmpty ? nil : comment)
            }
        }
    }

    // MARK: Indexes

    public func indexes(schema: String, table: String) async throws -> [IndexInfo] {
        if let m = mongo { return try await m.introspectIndexes(schema, table) }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .sqlite:
            let list = try await connection.execute(
                "PRAGMA \(dialect.quote(schema)).index_list(\(dialect.quote(table)))"
            ).rows
            var result: [IndexInfo] = []
            // seq, name, unique, origin, partial
            for row in list {
                let name = row[1].displayString
                let cols = try await connection.execute(
                    "PRAGMA \(dialect.quote(schema)).index_info(\(dialect.quote(name)))"
                ).rows.map { $0[2].displayString }
                result.append(
                    IndexInfo(
                        name: name, columns: cols, unique: row[2].displayString == "1",
                        primary: row.count > 3 && row[3].displayString == "pk"))
            }
            return result
        case .postgres:
            let rows = try await connection.execute(
                """
                SELECT ic.relname, i.indisunique, i.indisprimary,
                       array_to_string(ARRAY(SELECT pg_get_indexdef(i.indexrelid, k + 1, true)
                                             FROM generate_subscripts(i.indkey, 1) AS k ORDER BY k), ',')
                FROM pg_index i
                JOIN pg_class ic ON ic.oid = i.indexrelid
                JOIN pg_class c ON c.oid = i.indrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(lit(schema)) AND c.relname = \(lit(table))
                ORDER BY i.indisprimary DESC, ic.relname
                """
            ).rows
            return rows.map {
                IndexInfo(
                    name: $0[0].displayString,
                    columns: $0[3].displayString.split(separator: ",").map(String.init),
                    unique: $0[1].displayString == "true", primary: $0[2].displayString == "true")
            }
        case .mysql:
            let rows = try await connection.execute(
                """
                SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)
                FROM information_schema.STATISTICS
                WHERE TABLE_SCHEMA = \(lit(schema)) AND TABLE_NAME = \(lit(table))
                GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME
                """
            ).rows
            return rows.map {
                IndexInfo(
                    name: $0[0].displayString,
                    columns: $0[2].displayString.split(separator: ",").map(String.init),
                    unique: $0[1].displayString == "0", primary: $0[0].displayString == "PRIMARY")
            }
        }
    }

    // MARK: Foreign keys

    /// All foreign keys declared by tables in `schema`.
    public func foreignKeys(schema: String) async throws -> [ForeignKeyInfo] {
        if mongo != nil { return [] }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .postgres:
            let cols = { (keys: String, rel: String) in
                """
                array_to_string(ARRAY(SELECT a.attname FROM unnest(c.\(keys)) WITH ORDINALITY k(n, o)
                  JOIN pg_attribute a ON a.attrelid = c.\(rel) AND a.attnum = k.n ORDER BY k.o), ',')
                """
            }
            return try await connection.execute(
                """
                SELECT c.conname, sc.relname, \(cols("conkey", "conrelid")), tn.nspname, tc.relname, \(cols("confkey", "confrelid"))
                FROM pg_constraint c
                JOIN pg_class sc ON sc.oid = c.conrelid JOIN pg_namespace sn ON sn.oid = sc.relnamespace
                JOIN pg_class tc ON tc.oid = c.confrelid JOIN pg_namespace tn ON tn.oid = tc.relnamespace
                WHERE c.contype = 'f' AND sn.nspname = \(lit(schema))
                ORDER BY sc.relname, c.conname
                """
            ).rows.map {
                ForeignKeyInfo(
                    name: $0[0].displayString, schema: schema, table: $0[1].displayString,
                    columns: $0[2].displayString.split(separator: ",").map(String.init),
                    refSchema: $0[3].displayString, refTable: $0[4].displayString,
                    refColumns: $0[5].displayString.split(separator: ",").map(String.init))
            }
        case .mysql:
            let rows = try await connection.execute(
                """
                SELECT CONSTRAINT_NAME, TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = \(lit(schema)) AND REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
                """
            ).rows
            var out: [ForeignKeyInfo] = []
            for r in rows {
                let (name, table) = (r[0].displayString, r[1].displayString)
                if let i = out.indices.last, out[i].name == name, out[i].table == table {
                    out[i].columns.append(r[2].displayString)
                    out[i].refColumns.append(r[5].displayString)
                } else {
                    out.append(ForeignKeyInfo(
                        name: name, schema: schema, table: table, columns: [r[2].displayString],
                        refSchema: r[3].displayString, refTable: r[4].displayString, refColumns: [r[5].displayString]))
                }
            }
            return out
        case .sqlite:
            var out: [ForeignKeyInfo] = []
            for t in try await tables(schema: schema) where t.kind == .table {
                // id, seq, table, from, to, on_update, on_delete, match
                let rows = try await connection.execute(
                    "PRAGMA \(dialect.quote(schema)).foreign_key_list(\(dialect.quote(t.name)))").rows
                var byID: [String: ForeignKeyInfo] = [:]
                var order: [String] = []
                for r in rows {
                    let id = r[0].displayString
                    if byID[id] == nil {
                        order.append(id)
                        byID[id] = ForeignKeyInfo(
                            name: "fk_\(t.name)_\(id)", schema: schema, table: t.name, columns: [],
                            refSchema: schema, refTable: r[2].displayString, refColumns: [])
                    }
                    byID[id]!.columns.append(r[3].displayString)
                    if !r[4].isNull { byID[id]!.refColumns.append(r[4].displayString) }
                }
                for id in order {
                    var fk = byID[id]!
                    if fk.refColumns.isEmpty {  // REFERENCES t without columns → its primary key
                        fk.refColumns = try await columns(schema: schema, table: fk.refTable).filter(\.isPrimaryKey).map(\.name)
                    }
                    out.append(fk)
                }
            }
            return out
        }
    }

    // MARK: Routines

    public func routines(schema: String) async throws -> [RoutineInfo] {
        if mongo != nil { return [] }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .sqlite:
            return []
        case .postgres:
            return try await connection.execute(
                """
                SELECT p.proname, CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate'
                                                 WHEN 'w' THEN 'window' ELSE 'function' END
                FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = \(lit(schema))
                  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
                ORDER BY p.proname
                """
            ).rows.map { RoutineInfo(schema: schema, name: $0[0].displayString, kind: $0[1].displayString) }
        case .mysql:
            return try await connection.execute(
                """
                SELECT ROUTINE_NAME, LOWER(ROUTINE_TYPE) FROM information_schema.ROUTINES
                WHERE ROUTINE_SCHEMA = \(lit(schema)) ORDER BY ROUTINE_NAME
                """
            ).rows.map { RoutineInfo(schema: schema, name: $0[0].displayString, kind: $0[1].displayString) }
        }
    }

    // MARK: DDL

    public func ddl(for table: TableInfo) async throws -> String {
        if let m = mongo { return try await m.introspectDDL(table) }
        switch dialect {
        case .mongodb: fatalError("handled above")
        case .sqlite:
            let sql = try await connection.strings(
                """
                SELECT sql || ';' FROM \(dialect.quote(table.schema)).sqlite_master
                WHERE tbl_name = \(lit(table.name)) AND sql IS NOT NULL
                ORDER BY type = 'table' DESC, type = 'view' DESC, name
                """)
            return sql.joined(separator: "\n\n")
        case .mysql:
            let res = try await connection.execute(
                "SHOW CREATE \(table.kind == .view ? "VIEW" : "TABLE") \(dialect.qualified(schema: table.schema, name: table.name))"
            )
            return (res.rows.first.map { $0[1].displayString } ?? "") + ";"
        case .postgres:
            return try await postgresDDL(table)
        }
    }

    private func postgresDDL(_ table: TableInfo) async throws -> String {
        let qname = dialect.qualified(schema: table.schema, name: table.name)
        let oid = "\(lit(qname))::regclass"
        if table.kind != .table {
            let def = try await connection.strings("SELECT pg_get_viewdef(\(oid), true)").first ?? ""
            let kw = table.kind == .materializedView ? "MATERIALIZED VIEW" : "OR REPLACE VIEW"
            return "CREATE \(kw) \(qname) AS\n\(def)"
        }
        let cols = try await columns(schema: table.schema, table: table.name)
        var lines = cols.map { c -> String in
            var l = "    \(dialect.quote(c.name)) \(c.type)"
            if let d = c.defaultValue { l += " DEFAULT \(d)" }
            if !c.nullable { l += " NOT NULL" }
            return l
        }
        let constraints = try await connection.execute(
            "SELECT conname, pg_get_constraintdef(oid, true) FROM pg_constraint WHERE conrelid = \(oid) ORDER BY contype = 'p' DESC, conname"
        ).rows
        lines += constraints.map { "    CONSTRAINT \(dialect.quote($0[0].displayString)) \($0[1].displayString)" }
        var out = "CREATE TABLE \(qname)\n(\n" + lines.joined(separator: ",\n") + "\n);"
        let indexes = try await connection.strings(
            """
            SELECT pg_get_indexdef(i.indexrelid) || ';' FROM pg_index i
            WHERE i.indrelid = \(oid)
              AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid)
            ORDER BY 1
            """)
        if !indexes.isEmpty { out += "\n\n" + indexes.joined(separator: "\n") }
        if let comment = table.comment {
            out += "\n\nCOMMENT ON TABLE \(qname) IS \(lit(comment));"
        }
        for c in cols where c.comment != nil {
            out += "\nCOMMENT ON COLUMN \(qname).\(dialect.quote(c.name)) IS \(lit(c.comment!));"
        }
        return out
    }

    // MARK: Data

    /// SELECT used by the table data editor.
    public func selectSQL(_ table: TableInfo, filter: String, orderBy: String, limit: Int, offset: Int) -> String {
        if dialect == .mongodb {
            let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            let o = orderBy.trimmingCharacters(in: .whitespacesAndNewlines)
            var cmd = "db.getCollection(\(BSONFormatter.quote(table.name))).find(\(f.isEmpty ? "{}" : f))"
            if !o.isEmpty { cmd += ".sort(\(o))" }
            if offset > 0 { cmd += ".skip(\(offset))" }
            return cmd + ".limit(\(limit))"
        }
        var sql = "SELECT * FROM \(dialect.qualified(schema: table.schema, name: table.name))"
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { sql += " WHERE \(f)" }
        let o = orderBy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { sql += " ORDER BY \(o)" }
        sql += " LIMIT \(limit)"
        if offset > 0 { sql += " OFFSET \(offset)" }
        return sql
    }
}
