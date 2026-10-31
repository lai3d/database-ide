import Foundation

/// Tables, columns and indexes of one schema, for comparison.
public struct SchemaSnapshot: Sendable {
    public struct Table: Sendable {
        public var info: TableInfo
        public var columns: [ColumnInfo]
        public var indexes: [IndexInfo]
    }

    public var dialect: SQLDialect
    public var schema: String
    public var tables: [Table]

    public static func load(schema: String, from c: any DatabaseConnection) async throws -> SchemaSnapshot {
        let intro = Introspector(c)
        var tables: [Table] = []
        for t in try await intro.tables(schema: schema) where t.kind == .table {
            tables.append(Table(
                info: t,
                columns: try await intro.columns(schema: schema, table: t.name),
                indexes: (try? await intro.indexes(schema: schema, table: t.name)) ?? []))
        }
        return SchemaSnapshot(dialect: c.dialect, schema: schema, tables: tables)
    }

    func table(_ name: String) -> Table? { tables.first { $0.info.name.caseInsensitiveCompare(name) == .orderedSame } }
}

public struct SchemaDiff: Sendable {
    public enum Kind: String, Sendable { case added, removed, changed }

    public struct ColumnChange: Sendable, Equatable {
        public var name: String
        public var kind: Kind
        /// Human-readable differences, e.g. "type int → bigint".
        public var details: [String]
    }

    public struct TableChange: Sendable {
        public var name: String
        public var kind: Kind
        public var columns: [ColumnChange]
        public var indexes: [ColumnChange]
    }

    public var source: SchemaSnapshot
    public var target: SchemaSnapshot
    public var tables: [TableChange]

    public var isEmpty: Bool { tables.isEmpty }

    /// Differences that turn `target` into `source`.
    public static func compare(source: SchemaSnapshot, target: SchemaSnapshot) -> SchemaDiff {
        func norm(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        var changes: [TableChange] = []
        for s in source.tables.sorted(by: { $0.info.name < $1.info.name }) {
            guard let t = target.table(s.info.name) else {
                changes.append(TableChange(name: s.info.name, kind: .added, columns: [], indexes: []))
                continue
            }
            var cols: [ColumnChange] = []
            for sc in s.columns {
                guard let tc = t.columns.first(where: { $0.name.caseInsensitiveCompare(sc.name) == .orderedSame }) else {
                    cols.append(ColumnChange(name: sc.name, kind: .added, details: [sc.type]))
                    continue
                }
                var d: [String] = []
                if norm(sc.type) != norm(tc.type) { d.append("type \(tc.type) → \(sc.type)") }
                if sc.nullable != tc.nullable { d.append(sc.nullable ? "nullable" : "not null") }
                if norm(sc.defaultValue) != norm(tc.defaultValue) { d.append("default \(tc.defaultValue ?? "none") → \(sc.defaultValue ?? "none")") }
                if sc.isPrimaryKey != tc.isPrimaryKey { d.append(sc.isPrimaryKey ? "added to primary key" : "removed from primary key") }
                if !d.isEmpty { cols.append(ColumnChange(name: sc.name, kind: .changed, details: d)) }
            }
            for tc in t.columns where !s.columns.contains(where: { $0.name.caseInsensitiveCompare(tc.name) == .orderedSame }) {
                cols.append(ColumnChange(name: tc.name, kind: .removed, details: [tc.type]))
            }
            var idx: [ColumnChange] = []
            let sIdx = s.indexes.filter { !$0.primary }, tIdx = t.indexes.filter { !$0.primary }
            for si in sIdx {
                guard let ti = tIdx.first(where: { $0.name.caseInsensitiveCompare(si.name) == .orderedSame }) else {
                    idx.append(ColumnChange(name: si.name, kind: .added, details: ["(\(si.columns.joined(separator: ", ")))"]))
                    continue
                }
                if si.columns.map(norm) != ti.columns.map(norm) || si.unique != ti.unique {
                    idx.append(ColumnChange(name: si.name, kind: .changed, details: ["(\(ti.columns.joined(separator: ", "))) → (\(si.columns.joined(separator: ", ")))\(si.unique != ti.unique ? (si.unique ? " unique" : " non-unique") : "")"]))
                }
            }
            for ti in tIdx where !sIdx.contains(where: { $0.name.caseInsensitiveCompare(ti.name) == .orderedSame }) {
                idx.append(ColumnChange(name: ti.name, kind: .removed, details: []))
            }
            if !cols.isEmpty || !idx.isEmpty { changes.append(TableChange(name: s.info.name, kind: .changed, columns: cols, indexes: idx)) }
        }
        for t in target.tables.sorted(by: { $0.info.name < $1.info.name }) where source.table(t.info.name) == nil {
            changes.append(TableChange(name: t.info.name, kind: .removed, columns: [], indexes: []))
        }
        return SchemaDiff(source: source, target: target, tables: changes)
    }

    // MARK: Migration

    private static func design(_ t: SchemaSnapshot.Table, schema: String) -> TableDesign {
        TableDesign(schema: schema, name: t.info.name, columns: t.columns.map {
            .init(id: $0.name.lowercased(), name: $0.name, type: $0.type, nullable: $0.nullable,
                  defaultValue: $0.defaultValue ?? "", primaryKey: $0.isPrimaryKey, comment: $0.comment ?? "")
        }, comment: t.info.comment ?? "")
    }

    /// SQL that makes the target schema match the source (in the target's dialect).
    public func migrationSQL(dropRemoved: Bool = true) -> [String] {
        let d = target.dialect
        var out: [String] = []
        if source.dialect != d {
            out.append("-- Source is \(source.dialect.displayName), target is \(d.displayName): column types are copied verbatim, review them.")
        }
        func indexDDL(_ i: IndexInfo, table: String) -> String {
            let cols = i.columns.map { $0.contains("(") ? $0 : d.quote($0) }.joined(separator: ", ")
            let on = d.qualified(schema: target.schema, name: table)
            return "CREATE \(i.unique ? "UNIQUE " : "")INDEX \(d.quote(i.name)) ON \(on) (\(cols))"
        }
        func dropIndex(_ name: String, table: String) -> String {
            switch d {
            case .postgres: "DROP INDEX \(d.qualified(schema: target.schema, name: name))"
            case .mysql, .sqlserver: "DROP INDEX \(d.quote(name)) ON \(d.qualified(schema: target.schema, name: table))"
            case .clickhouse: "ALTER TABLE \(d.qualified(schema: target.schema, name: table)) DROP INDEX \(d.quote(name))"
            default: "DROP INDEX \(d.quote(name))"
            }
        }
        for change in tables {
            switch change.kind {
            case .added:
                guard let s = source.table(change.name) else { continue }
                out += Self.design(s, schema: target.schema).createStatements(dialect: d)
                if d != .clickhouse { out += s.indexes.filter { !$0.primary }.map { indexDDL($0, table: s.info.name) } }
            case .removed:
                if dropRemoved {
                    out.append("DROP TABLE \(d.qualified(schema: target.schema, name: change.name))")
                } else {
                    out.append("-- table \(change.name) exists only in the target")
                }
            case .changed:
                guard let s = source.table(change.name), let t = target.table(change.name) else { continue }
                var wanted = Self.design(s, schema: target.schema)
                wanted.name = t.info.name
                var current = Self.design(t, schema: target.schema)
                current.primaryKeyName = nil
                let alter = wanted.alterStatements(from: current, dialect: d)
                out += alter
                // A SQLite rebuild drops the table's indexes: recreate the source's set instead of diffing.
                if alter.contains(where: { $0.contains("_dbide_new_") }) {
                    out += s.indexes.filter { !$0.primary }.map { indexDDL($0, table: t.info.name) }
                    continue
                }
                for i in change.indexes {
                    switch i.kind {
                    case .removed: out.append(dropIndex(i.name, table: t.info.name))
                    case .added:
                        if let si = s.indexes.first(where: { $0.name.caseInsensitiveCompare(i.name) == .orderedSame }) {
                            out.append(indexDDL(si, table: t.info.name))
                        }
                    case .changed:
                        if let si = s.indexes.first(where: { $0.name.caseInsensitiveCompare(i.name) == .orderedSame }) {
                            out.append(dropIndex(i.name, table: t.info.name))
                            out.append(indexDDL(si, table: t.info.name))
                        }
                    }
                }
            }
        }
        return out
    }
}
