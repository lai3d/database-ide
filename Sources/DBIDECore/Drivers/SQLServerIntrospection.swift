import Foundation

struct SQLServerIntrospection: EngineIntrospection {
    let c: SQLServerConnection
    private func lit(_ s: String) -> String { SQLDialect.sqlserver.literal(s) }

    func schemas() async throws -> [String] {
        try await c.strings("""
            SELECT s.name FROM sys.schemas s
            WHERE s.name NOT IN ('guest', 'INFORMATION_SCHEMA', 'sys') AND s.name NOT LIKE 'db[_]%'
            ORDER BY CASE WHEN s.name = SCHEMA_NAME() THEN 0 ELSE 1 END, s.name
            """)
    }

    func currentSchema() async throws -> String? { try await c.strings("SELECT SCHEMA_NAME()").first }

    func tables(schema: String) async throws -> [TableInfo] {
        try await c.execute("""
            SELECT o.name, o.type, CAST(ep.value AS nvarchar(4000))
            FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
            LEFT JOIN sys.extended_properties ep ON ep.major_id = o.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
            WHERE s.name = \(lit(schema)) AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0
            ORDER BY o.name
            """).rows.map {
            TableInfo(schema: schema, name: $0[0].displayString, kind: $0[1].displayString.hasPrefix("V") ? .view : .table,
                      comment: $0[2].isNull ? nil : $0[2].displayString)
        }
    }

    func columns(schema: String, table: String) async throws -> [ColumnInfo] {
        try await c.execute("""
            SELECT c.name,
              CASE WHEN t.name IN ('varchar', 'char', 'varbinary', 'binary')
                     THEN t.name + '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS varchar(10)) END + ')'
                   WHEN t.name IN ('nvarchar', 'nchar')
                     THEN t.name + '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS varchar(10)) END + ')'
                   WHEN t.name IN ('decimal', 'numeric')
                     THEN t.name + '(' + CAST(c.precision AS varchar(5)) + ',' + CAST(c.scale AS varchar(5)) + ')'
                   WHEN t.name IN ('datetime2', 'time', 'datetimeoffset') AND c.scale <> 7
                     THEN t.name + '(' + CAST(c.scale AS varchar(5)) + ')'
                   ELSE t.name END
                + CASE WHEN c.is_identity = 1 THEN ' IDENTITY(' + CAST(ic.seed_value AS varchar(20)) + ',' + CAST(ic.increment_value AS varchar(20)) + ')' ELSE '' END,
              c.is_nullable, dc.definition,
              CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns x JOIN sys.indexes i ON i.object_id = x.object_id AND i.index_id = x.index_id
                                WHERE i.is_primary_key = 1 AND x.object_id = c.object_id AND x.column_id = c.column_id) THEN 1 ELSE 0 END,
              CAST(ep.value AS nvarchar(4000))
            FROM sys.columns c
            JOIN sys.types t ON t.user_type_id = c.user_type_id
            LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
            LEFT JOIN sys.extended_properties ep ON ep.major_id = c.object_id AND ep.minor_id = c.column_id AND ep.name = 'MS_Description'
            WHERE c.object_id = OBJECT_ID(\(lit(schema + "." + table)))
            ORDER BY c.column_id
            """).rows.map {
            ColumnInfo(
                name: $0[0].displayString, type: $0[1].displayString, nullable: $0[2].displayString == "true",
                defaultValue: $0[3].isNull ? nil : $0[3].displayString, isPrimaryKey: $0[4].displayString == "1",
                comment: $0[5].isNull ? nil : $0[5].displayString)
        }
    }

    func indexes(schema: String, table: String) async throws -> [IndexInfo] {
        try await c.execute("""
            SELECT i.name, i.is_unique, i.is_primary_key,
              (SELECT STRING_AGG(col.name, ',') WITHIN GROUP (ORDER BY x.key_ordinal)
               FROM sys.index_columns x JOIN sys.columns col ON col.object_id = x.object_id AND col.column_id = x.column_id
               WHERE x.object_id = i.object_id AND x.index_id = i.index_id AND x.is_included_column = 0)
            FROM sys.indexes i
            WHERE i.object_id = OBJECT_ID(\(lit(schema + "." + table))) AND i.type > 0
            ORDER BY i.is_primary_key DESC, i.name
            """).rows.map {
            IndexInfo(name: $0[0].displayString, columns: $0[3].displayString.split(separator: ",").map(String.init),
                      unique: $0[1].displayString == "true", primary: $0[2].displayString == "true")
        }
    }

    func foreignKeys(schema: String) async throws -> [ForeignKeyInfo] {
        try await c.execute("""
            SELECT fk.name, OBJECT_NAME(fk.parent_object_id), SCHEMA_NAME(rt.schema_id), rt.name,
              (SELECT STRING_AGG(COL_NAME(k.parent_object_id, k.parent_column_id), ',') WITHIN GROUP (ORDER BY k.constraint_column_id)
               FROM sys.foreign_key_columns k WHERE k.constraint_object_id = fk.object_id),
              (SELECT STRING_AGG(COL_NAME(k.referenced_object_id, k.referenced_column_id), ',') WITHIN GROUP (ORDER BY k.constraint_column_id)
               FROM sys.foreign_key_columns k WHERE k.constraint_object_id = fk.object_id)
            FROM sys.foreign_keys fk JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
            WHERE SCHEMA_NAME(fk.schema_id) = \(lit(schema))
            ORDER BY 2, 1
            """).rows.map {
            ForeignKeyInfo(
                name: $0[0].displayString, schema: schema, table: $0[1].displayString,
                columns: $0[4].displayString.split(separator: ",").map(String.init),
                refSchema: $0[2].displayString, refTable: $0[3].displayString,
                refColumns: $0[5].displayString.split(separator: ",").map(String.init))
        }
    }

    func routines(schema: String) async throws -> [RoutineInfo] {
        try await c.execute("""
            SELECT o.name, CASE o.type WHEN 'P' THEN 'procedure' ELSE 'function' END
            FROM sys.objects o WHERE SCHEMA_NAME(o.schema_id) = \(lit(schema)) AND o.type IN ('P', 'FN', 'IF', 'TF') AND o.is_ms_shipped = 0
            ORDER BY o.name
            """).rows.map { RoutineInfo(schema: schema, name: $0[0].displayString, kind: $0[1].displayString) }
    }

    func ddl(for table: TableInfo) async throws -> String {
        let d = SQLDialect.sqlserver
        let qname = d.qualified(schema: table.schema, name: table.name)
        if table.kind != .table {
            return try await c.strings("SELECT OBJECT_DEFINITION(OBJECT_ID(\(lit(table.schema + "." + table.name))))").first ?? ""
        }
        let cols = try await columns(schema: table.schema, table: table.name)
        var lines = cols.map { col -> String in
            var l = "    \(d.quote(col.name)) \(col.type)\(col.nullable ? " NULL" : " NOT NULL")"
            if let def = col.defaultValue { l += " DEFAULT \(def)" }
            return l
        }
        let idx = try await indexes(schema: table.schema, table: table.name)
        if let pk = idx.first(where: \.primary) {
            lines.append("    CONSTRAINT \(d.quote(pk.name)) PRIMARY KEY (\(pk.columns.map { d.quote($0) }.joined(separator: ", ")))")
        }
        for fk in try await foreignKeys(schema: table.schema) where fk.table == table.name {
            lines.append("    CONSTRAINT \(d.quote(fk.name)) FOREIGN KEY (\(fk.columns.map { d.quote($0) }.joined(separator: ", "))) REFERENCES \(d.qualified(schema: fk.refSchema, name: fk.refTable)) (\(fk.refColumns.map { d.quote($0) }.joined(separator: ", ")))")
        }
        var out = "CREATE TABLE \(qname) (\n\(lines.joined(separator: ",\n"))\n);"
        for i in idx where !i.primary {
            out += "\nCREATE \(i.unique ? "UNIQUE " : "")INDEX \(d.quote(i.name)) ON \(qname) (\(i.columns.map { d.quote($0) }.joined(separator: ", ")));"
        }
        return out
    }
}
