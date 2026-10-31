import Foundation

/// Catalog queries for engines that are not plain SQL-standard catalogs.
protocol EngineIntrospection {
    func schemas() async throws -> [String]
    func currentSchema() async throws -> String?
    func tables(schema: String) async throws -> [TableInfo]
    func columns(schema: String, table: String) async throws -> [ColumnInfo]
    func indexes(schema: String, table: String) async throws -> [IndexInfo]
    func foreignKeys(schema: String) async throws -> [ForeignKeyInfo]
    func ddl(for table: TableInfo) async throws -> String
    func routines(schema: String) async throws -> [RoutineInfo]
}

extension EngineIntrospection {
    func foreignKeys(schema: String) async throws -> [ForeignKeyInfo] { [] }
    func routines(schema: String) async throws -> [RoutineInfo] { [] }
}

struct ClickHouseIntrospection: EngineIntrospection {
    let c: ClickHouseConnection
    private func lit(_ s: String) -> String { SQLDialect.clickhouse.literal(s) }

    func schemas() async throws -> [String] {
        try await c.strings("SELECT name FROM system.databases WHERE name NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema') ORDER BY name")
    }

    func currentSchema() async throws -> String? { c.database }

    func tables(schema: String) async throws -> [TableInfo] {
        try await c.execute("SELECT name, engine, comment FROM system.tables WHERE database = \(lit(schema)) AND NOT is_temporary ORDER BY name").rows.map {
            let engine = $0[1].displayString
            let comment = $0[2].displayString
            return TableInfo(
                schema: schema, name: $0[0].displayString,
                kind: engine == "MaterializedView" ? .materializedView : engine.hasSuffix("View") ? .view : .table,
                comment: comment.isEmpty ? nil : comment)
        }
    }

    func columns(schema: String, table: String) async throws -> [ColumnInfo] {
        try await c.execute("""
            SELECT name, type, default_expression, is_in_primary_key, comment FROM system.columns
            WHERE database = \(lit(schema)) AND table = \(lit(table)) ORDER BY position
            """).rows.map {
            let type = $0[1].displayString
            let def = $0[2].displayString, comment = $0[4].displayString
            return ColumnInfo(
                name: $0[0].displayString, type: type, nullable: type.hasPrefix("Nullable("),
                defaultValue: def.isEmpty ? nil : def, isPrimaryKey: $0[3].displayString == "1",
                comment: comment.isEmpty ? nil : comment)
        }
    }

    func indexes(schema: String, table: String) async throws -> [IndexInfo] {
        var out: [IndexInfo] = []
        if let row = try await c.execute("SELECT sorting_key, primary_key FROM system.tables WHERE database = \(lit(schema)) AND name = \(lit(table))").rows.first {
            let sorting = row[0].displayString
            if !sorting.isEmpty { out.append(IndexInfo(name: "ORDER BY", columns: sorting.components(separatedBy: ", "), unique: false, primary: true)) }
        }
        out += try await c.execute("SELECT name, expr, type FROM system.data_skipping_indices WHERE database = \(lit(schema)) AND table = \(lit(table))").rows.map {
            IndexInfo(name: $0[0].displayString, columns: ["\($0[1].displayString) \($0[2].displayString)"], unique: false, primary: false)
        }
        return out
    }

    func ddl(for table: TableInfo) async throws -> String {
        (try await c.strings("SHOW CREATE TABLE \(SQLDialect.clickhouse.qualified(schema: table.schema, name: table.name))").first ?? "") + ";"
    }
}
