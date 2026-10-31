import Foundation

/// Editable description of a table for the create / alter designer.
public struct TableDesign: Sendable, Equatable {
    public struct Column: Sendable, Equatable, Identifiable {
        /// Stable identity across renames (original name for existing columns).
        public var id: String
        public var name: String
        public var type: String
        public var nullable: Bool = true
        public var defaultValue: String = ""
        public var primaryKey: Bool = false
        public var comment: String = ""

        public init(id: String = UUID().uuidString, name: String, type: String, nullable: Bool = true,
                    defaultValue: String = "", primaryKey: Bool = false, comment: String = "") {
            self.id = id
            self.name = name
            self.type = type
            self.nullable = nullable
            self.defaultValue = defaultValue
            self.primaryKey = primaryKey
            self.comment = comment
        }
    }

    public var schema: String
    public var name: String
    public var columns: [Column]
    public var comment: String = ""
    /// Existing primary-key constraint name (PostgreSQL), needed to drop it.
    public var primaryKeyName: String?
    /// SQLite: CREATE INDEX / TRIGGER statements to replay after a table rebuild.
    public var dependentSQL: [String] = []

    public init(schema: String, name: String, columns: [Column], comment: String = "") {
        self.schema = schema
        self.name = name
        self.columns = columns
        self.comment = comment
    }

    /// Loads the current definition of an existing table.
    public static func load(_ table: TableInfo, from conn: any DatabaseConnection) async throws -> TableDesign {
        let intro = Introspector(conn)
        let cols = try await intro.columns(schema: table.schema, table: table.name)
        var d = TableDesign(
            schema: table.schema, name: table.name,
            columns: cols.map {
                Column(id: $0.name, name: $0.name, type: $0.type, nullable: $0.nullable, defaultValue: $0.defaultValue ?? "",
                       primaryKey: $0.isPrimaryKey, comment: $0.comment ?? "")
            },
            comment: table.comment ?? "")
        if conn.dialect == .mysql {
            // information_schema returns raw default values; make them SQL expressions.
            for i in d.columns.indices where !d.columns[i].defaultValue.isEmpty {
                let v = d.columns[i].defaultValue
                let isExpression = Double(v) != nil || v.uppercased().hasPrefix("CURRENT_") || v.hasPrefix("(") || v.uppercased() == "NULL"
                if !isExpression { d.columns[i].defaultValue = conn.dialect.literal(v) }
            }
        }
        switch conn.dialect {
        case .postgres:
            d.primaryKeyName = try await conn.strings(
                "SELECT conname FROM pg_constraint WHERE contype = 'p' AND conrelid = \(conn.dialect.literal(conn.dialect.qualified(schema: table.schema, name: table.name)))::regclass"
            ).first
        case .sqlite:
            d.dependentSQL = try await conn.strings(
                "SELECT sql FROM \(conn.dialect.quote(table.schema)).sqlite_master WHERE tbl_name = \(conn.dialect.literal(table.name)) AND type IN ('index', 'trigger') AND sql IS NOT NULL")
        default:
            break
        }
        return d
    }

    // MARK: Validation

    public func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Table name is empty" }
        if columns.isEmpty { return "Add at least one column" }
        var seen = Set<String>()
        for c in columns {
            if c.name.trimmingCharacters(in: .whitespaces).isEmpty { return "A column has no name" }
            if c.type.trimmingCharacters(in: .whitespaces).isEmpty { return "Column \(c.name) has no type" }
            if !seen.insert(c.name.lowercased()).inserted { return "Duplicate column \(c.name)" }
        }
        return nil
    }

    // MARK: CREATE

    public func createStatements(dialect: SQLDialect) -> [String] {
        let qt = dialect.qualified(schema: schema, name: name)
        let pk = columns.filter(\.primaryKey)
        var lines = columns.map { "    " + columnDefinition($0, dialect: dialect, inlinePK: dialect == .sqlite && pk.count == 1) }
        if !(dialect == .sqlite && pk.count == 1), !pk.isEmpty {
            lines.append("    PRIMARY KEY (\(pk.map { dialect.quote($0.name) }.joined(separator: ", ")))")
        }
        var create = "CREATE TABLE \(qt) (\n\(lines.joined(separator: ",\n"))\n)"
        if dialect == .mysql, !comment.isEmpty { create += " COMMENT \(dialect.literal(comment))" }
        var out = [create]
        if dialect == .postgres {
            if !comment.isEmpty { out.append("COMMENT ON TABLE \(qt) IS \(dialect.literal(comment))") }
            for c in columns where !c.comment.isEmpty {
                out.append("COMMENT ON COLUMN \(qt).\(dialect.quote(c.name)) IS \(dialect.literal(c.comment))")
            }
        }
        return out
    }

    func columnDefinition(_ c: Column, dialect: SQLDialect, inlinePK: Bool = false) -> String {
        var s = "\(dialect.quote(c.name)) \(c.type)"
        if inlinePK && c.primaryKey { s += " PRIMARY KEY" }
        if !c.nullable { s += " NOT NULL" }
        let d = c.defaultValue.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty { s += " DEFAULT \(d)" }
        if dialect == .mysql, !c.comment.isEmpty { s += " COMMENT \(dialect.literal(c.comment))" }
        return s
    }

    // MARK: ALTER

    /// Statements turning `original` into `self`.
    public func alterStatements(from original: TableDesign, dialect: SQLDialect) -> [String] {
        switch dialect {
        case .postgres: return postgresAlter(from: original)
        case .mysql: return mysqlAlter(from: original)
        case .sqlite: return sqliteAlter(from: original)
        case .mongodb: return []
        }
    }

    private func diff(_ original: TableDesign) -> (added: [Column], dropped: [Column], kept: [(old: Column, new: Column)]) {
        let old = Dictionary(uniqueKeysWithValues: original.columns.map { ($0.id, $0) })
        let newIDs = Set(columns.map(\.id))
        return (
            columns.filter { old[$0.id] == nil },
            original.columns.filter { !newIDs.contains($0.id) },
            columns.compactMap { c in old[c.id].map { ($0, c) } }
        )
    }

    private var pkNames: [String] { columns.filter(\.primaryKey).map(\.name) }
    private var pkIDs: Set<String> { Set(columns.filter(\.primaryKey).map(\.id)) }

    private func postgresAlter(from original: TableDesign) -> [String] {
        let d = SQLDialect.postgres
        var qt = d.qualified(schema: original.schema, name: original.name)
        var out: [String] = []
        if name != original.name {
            out.append("ALTER TABLE \(qt) RENAME TO \(d.quote(name))")
            qt = d.qualified(schema: schema, name: name)
        }
        let (added, dropped, kept) = diff(original)
        let pkChanged = original.pkIDs != pkIDs
        if pkChanged, !original.pkNames.isEmpty {
            out.append("ALTER TABLE \(qt) DROP CONSTRAINT \(d.quote(original.primaryKeyName ?? "\(original.name)_pkey"))")
        }
        for c in dropped { out.append("ALTER TABLE \(qt) DROP COLUMN \(d.quote(c.name))") }
        for (o, n) in kept {
            let col = d.quote(n.name)
            if o.name != n.name { out.append("ALTER TABLE \(qt) RENAME COLUMN \(d.quote(o.name)) TO \(col)") }
            if o.type != n.type { out.append("ALTER TABLE \(qt) ALTER COLUMN \(col) TYPE \(n.type) USING \(col)::\(n.type)") }
            if o.defaultValue != n.defaultValue {
                out.append(n.defaultValue.isEmpty
                    ? "ALTER TABLE \(qt) ALTER COLUMN \(col) DROP DEFAULT"
                    : "ALTER TABLE \(qt) ALTER COLUMN \(col) SET DEFAULT \(n.defaultValue)")
            }
            if o.nullable != n.nullable && !(n.primaryKey && !n.nullable) {
                out.append("ALTER TABLE \(qt) ALTER COLUMN \(col) \(n.nullable ? "DROP" : "SET") NOT NULL")
            }
            if o.comment != n.comment {
                out.append("COMMENT ON COLUMN \(qt).\(col) IS \(n.comment.isEmpty ? "NULL" : d.literal(n.comment))")
            }
        }
        for c in added {
            out.append("ALTER TABLE \(qt) ADD COLUMN \(columnDefinition(c, dialect: d))")
            if !c.comment.isEmpty { out.append("COMMENT ON COLUMN \(qt).\(d.quote(c.name)) IS \(d.literal(c.comment))") }
        }
        if pkChanged, !pkNames.isEmpty {
            out.append("ALTER TABLE \(qt) ADD PRIMARY KEY (\(pkNames.map { d.quote($0) }.joined(separator: ", ")))")
        }
        if comment != original.comment {
            out.append("COMMENT ON TABLE \(qt) IS \(comment.isEmpty ? "NULL" : d.literal(comment))")
        }
        return out
    }

    private func mysqlAlter(from original: TableDesign) -> [String] {
        let d = SQLDialect.mysql
        var qt = d.qualified(schema: original.schema, name: original.name)
        var out: [String] = []
        if name != original.name {
            out.append("ALTER TABLE \(qt) RENAME TO \(d.qualified(schema: schema, name: name))")
            qt = d.qualified(schema: schema, name: name)
        }
        let (added, dropped, kept) = diff(original)
        let pkChanged = original.pkIDs != pkIDs
        if pkChanged, !original.pkNames.isEmpty { out.append("ALTER TABLE \(qt) DROP PRIMARY KEY") }
        for c in dropped { out.append("ALTER TABLE \(qt) DROP COLUMN \(d.quote(c.name))") }
        for (o, n) in kept {
            var o2 = o
            o2.primaryKey = n.primaryKey
            if o.name != n.name { out.append("ALTER TABLE \(qt) RENAME COLUMN \(d.quote(o.name)) TO \(d.quote(n.name))") }
            var renamed = o2
            renamed.name = n.name
            if renamed != n { out.append("ALTER TABLE \(qt) MODIFY COLUMN \(columnDefinition(n, dialect: d))") }
        }
        for c in added { out.append("ALTER TABLE \(qt) ADD COLUMN \(columnDefinition(c, dialect: d))") }
        if pkChanged, !pkNames.isEmpty {
            out.append("ALTER TABLE \(qt) ADD PRIMARY KEY (\(pkNames.map { d.quote($0) }.joined(separator: ", ")))")
        }
        if comment != original.comment { out.append("ALTER TABLE \(qt) COMMENT = \(d.literal(comment))") }
        return out
    }

    private func sqliteAlter(from original: TableDesign) -> [String] {
        let d = SQLDialect.sqlite
        let (added, dropped, kept) = diff(original)
        let onlyRenamesDropsAdds = kept.allSatisfy { o, n in
            o.type == n.type && o.nullable == n.nullable && o.defaultValue == n.defaultValue && o.primaryKey == n.primaryKey
        } && added.allSatisfy { !$0.primaryKey && ($0.nullable || !$0.defaultValue.isEmpty) }
            && dropped.allSatisfy { !$0.primaryKey }
        if onlyRenamesDropsAdds {
            var qt = d.qualified(schema: original.schema, name: original.name)
            var out: [String] = []
            if name != original.name {
                out.append("ALTER TABLE \(qt) RENAME TO \(d.quote(name))")
                qt = d.qualified(schema: schema, name: name)
            }
            for (o, n) in kept where o.name != n.name {
                out.append("ALTER TABLE \(qt) RENAME COLUMN \(d.quote(o.name)) TO \(d.quote(n.name))")
            }
            for c in dropped { out.append("ALTER TABLE \(qt) DROP COLUMN \(d.quote(c.name))") }
            for c in added { out.append("ALTER TABLE \(qt) ADD COLUMN \(columnDefinition(c, dialect: d))") }
            return out
        }
        // Rebuild: SQLite cannot alter types, constraints or primary keys in place.
        let tmp = "_dbide_new_\(name)"
        var newDesign = self
        newDesign.name = tmp
        var out = newDesign.createStatements(dialect: d)
        let pairs = kept.map { (d.quote($0.old.name), d.quote($0.new.name)) }
        if !pairs.isEmpty {
            out.append(
                "INSERT INTO \(d.qualified(schema: schema, name: tmp)) (\(pairs.map(\.1).joined(separator: ", "))) SELECT \(pairs.map(\.0).joined(separator: ", ")) FROM \(d.qualified(schema: original.schema, name: original.name))")
        }
        out.append("DROP TABLE \(d.qualified(schema: original.schema, name: original.name))")
        out.append("ALTER TABLE \(d.qualified(schema: schema, name: tmp)) RENAME TO \(d.quote(name))")
        out += original.dependentSQL  // recreate indexes / triggers
        return out
    }

    /// Applies DDL; transactional where the database supports it (PostgreSQL, SQLite).
    public static func apply(_ statements: [String], on c: any DatabaseConnection) async throws {
        let transactional = c.dialect == .postgres || c.dialect == .sqlite
        // Must be outside a transaction to take effect (table rebuilds drop and recreate tables).
        if c.dialect == .sqlite { _ = try await c.execute("PRAGMA foreign_keys = OFF") }
        if transactional { _ = try await c.execute("BEGIN") }
        do {
            for sql in statements { _ = try await c.execute(sql) }
            if transactional { _ = try await c.execute("COMMIT") }
        } catch {
            if transactional { _ = try? await c.execute("ROLLBACK") }
            throw error
        }
    }

    /// Common column types offered in the designer.
    public static func suggestedTypes(_ dialect: SQLDialect) -> [String] {
        switch dialect {
        case .postgres:
            ["bigserial", "serial", "bigint", "integer", "smallint", "numeric(12,2)", "double precision", "boolean",
             "text", "varchar(255)", "uuid", "date", "timestamp", "timestamptz", "jsonb", "bytea"]
        case .mysql:
            ["bigint", "int", "tinyint(1)", "decimal(12,2)", "double", "varchar(255)", "text", "json", "date", "datetime",
             "timestamp", "blob"]
        case .sqlite:
            ["INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC"]
        case .mongodb:
            []
        }
    }
}
