import Foundation

/// RFC 4180 CSV parsing: quoted fields, doubled quotes, newlines inside quotes, BOM.
public enum CSVParser {
    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var atFieldStart = true
        var chars = text.makeIterator()
        var pending: Character? = nil
        if text.first == "\u{FEFF}" { _ = chars.next() }

        func next() -> Character? {
            if let p = pending {
                pending = nil
                return p
            }
            return chars.next()
        }
        func endField() {
            row.append(field)
            field = ""
            atFieldStart = true
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }  // skip blank lines
            row = []
        }

        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = n
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where atFieldStart:
                inQuotes = true
                atFieldStart = false
            case delimiter:
                endField()
            case "\r\n", "\n", "\r":
                endRow()
            default:
                field.append(c)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Picks the delimiter that splits the first lines most consistently.
    public static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(whereSeparator: \.isNewline).prefix(10).map(String.init)
        var best: (Character, Int) = (",", 0)
        for d: Character in [",", ";", "\t", "|"] {
            let counts = sample.map { line in line.filter { $0 == d }.count }
            guard let first = counts.first, first > 0 else { continue }
            let consistent = counts.filter { $0 == first }.count
            let score = consistent * 100 + first
            if score > best.1 { best = (d, score) }
        }
        return best.0
    }
}

/// Plans and runs a CSV import into an existing or new table.
public struct CSVImport: Sendable {
    public enum ColumnType: String, Sendable, CaseIterable { case integer, real, boolean, text }

    public var header: [String]
    public var rows: [[String]]

    /// Splits parsed rows into header + data.
    public init(parsed: [[String]], firstRowIsHeader: Bool) {
        let width = parsed.map(\.count).max() ?? 0
        var data = parsed.map { $0 + Array(repeating: "", count: width - $0.count) }
        if firstRowIsHeader, !data.isEmpty {
            let h = data.removeFirst()
            var seen: [String: Int] = [:]
            header = h.enumerated().map { i, raw in
                var name = raw.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { name = "column\(i + 1)" }
                if let n = seen[name.lowercased()] {
                    seen[name.lowercased()] = n + 1
                    name += "_\(n + 1)"
                } else {
                    seen[name.lowercased()] = 1
                }
                return name
            }
        } else {
            header = (0..<width).map { "column\($0 + 1)" }
        }
        rows = data
    }

    /// Narrowest type that fits every non-empty value in column `i`.
    public func inferType(column i: Int) -> ColumnType {
        var type = ColumnType.integer
        var sawValue = false
        for row in rows where i < row.count {
            let v = row[i].trimmingCharacters(in: .whitespaces)
            if v.isEmpty { continue }
            sawValue = true
            // Codes like 007 / 02134 must keep their leading zeros.
            if Self.hasLeadingZero(v) { return .text }
            switch type {
            case .integer:
                if Int64(v) != nil { continue }
                type = Double(v) != nil ? .real : (Self.isBool(v) ? .boolean : .text)
            case .real:
                if Double(v) == nil { type = .text }
            case .boolean:
                if !Self.isBool(v) { type = .text }
            case .text:
                return .text
            }
        }
        return sawValue ? type : .text
    }

    static func isBool(_ v: String) -> Bool { ["true", "false"].contains(v.lowercased()) }

    static func hasLeadingZero(_ v: String) -> Bool {
        let digits = v.hasPrefix("-") ? v.dropFirst() : Substring(v)
        guard digits.count > 1, digits.first == "0" else { return false }
        return digits.dropFirst().first?.isNumber == true
    }

    public static func sqlType(_ t: ColumnType, dialect: SQLDialect) -> String {
        if dialect == .mongodb {
            return switch t {
            case .integer: "int/long"
            case .real: "double"
            case .boolean: "bool"
            case .text: "string"
            }
        }
        if dialect == .clickhouse {
            return switch t {
            case .integer: "Int64"
            case .real: "Float64"
            case .boolean: "Bool"
            case .text: "String"
            }
        }
        if dialect == .sqlserver {
            return switch t {
            case .integer: "bigint"
            case .real: "float"
            case .boolean: "bit"
            case .text: "nvarchar(max)"
            }
        }
        return switch (t, dialect) {
        case (.integer, .sqlite): "INTEGER"
        case (.integer, _): "BIGINT"
        case (.real, .postgres): "DOUBLE PRECISION"
        case (.real, .mysql): "DOUBLE"
        case (.real, .sqlite): "REAL"
        case (.boolean, .sqlite): "INTEGER"
        case (.boolean, _): "BOOLEAN"
        case (.text, .mysql): "TEXT"
        case (.text, _): "TEXT"
        default: ""
        }
    }

    public func createTableSQL(schema: String?, table: String, types: [ColumnType], dialect: SQLDialect) -> String {
        if dialect == .mongodb { return "db.createCollection(\(BSONFormatter.quote(table)))" }
        let cols = header.enumerated().map { i, name in
            "    \(dialect.quote(name)) \(Self.sqlType(i < types.count ? types[i] : .text, dialect: dialect))"
        }
        return "CREATE TABLE \(dialect.qualified(schema: schema, name: table)) (\n\(cols.joined(separator: ",\n"))\n)"
    }

    /// Multi-row INSERTs. `mapping[i]` is the target column for CSV column i (nil = skip).
    public func insertStatements(
        schema: String?, table: String, mapping: [String?], types: [ColumnType]? = nil,
        emptyAsNull: Bool, dialect: SQLDialect, batchSize: Int = 500
    ) -> [String] {
        let used = mapping.enumerated().compactMap { i, target in target.map { (i, $0) } }
        guard !used.isEmpty else { return [] }
        if dialect == .mongodb {
            func value(_ raw: String, _ i: Int) -> BSONValue {
                let t = raw.trimmingCharacters(in: .whitespaces)
                if raw.isEmpty { return emptyAsNull ? .null : .string("") }
                switch types?[i] {
                case .integer?: if let v = Int64(t) { return Int32(exactly: v).map(BSONValue.int32) ?? .int64(v) }
                case .real?: if let d = Double(t) { return .double(d) }
                case .boolean?: if Self.isBool(t) { return .bool(t.lowercased() == "true") }
                default: break
                }
                return .string(raw)
            }
            var out: [String] = []
            var start = 0
            while start < rows.count {
                let chunk = rows[start..<min(rows.count, start + batchSize)]
                let docs = chunk.map { row in
                    BSONValue.document(BSONDocument(used.map { ($0.1, value($0.0 < row.count ? row[$0.0] : "", $0.0)) })).shellString
                }
                out.append("db.getCollection(\(BSONFormatter.quote(table))).insertMany([\n" + docs.joined(separator: ",\n") + "\n])")
                start += batchSize
            }
            return out
        }
        let qt = dialect.qualified(schema: schema, name: table)
        let cols = used.map { dialect.quote($0.1) }.joined(separator: ", ")
        func literal(_ raw: String, _ i: Int) -> String {
            if emptyAsNull && raw.isEmpty { return "NULL" }
            if let t = types?[i], t == .integer || t == .real, !raw.isEmpty, Double(raw.trimmingCharacters(in: .whitespaces)) != nil {
                return raw.trimmingCharacters(in: .whitespaces)
            }
            if let t = types?[i], t == .boolean, Self.isBool(raw) {
                let yes = raw.lowercased() == "true"
                return dialect == .sqlite || dialect == .sqlserver ? (yes ? "1" : "0") : (yes ? "TRUE" : "FALSE")
            }
            return dialect.literal(raw)
        }
        var out: [String] = []
        var start = 0
        while start < rows.count {
            let chunk = rows[start..<min(rows.count, start + batchSize)]
            let values = chunk.map { row in
                "(" + used.map { literal($0.0 < row.count ? row[$0.0] : "", $0.0) }.joined(separator: ", ") + ")"
            }
            out.append("INSERT INTO \(qt) (\(cols)) VALUES\n" + values.joined(separator: ",\n"))
            start += batchSize
        }
        return out
    }

    /// Runs `statements` in one transaction, reporting progress (0…1).
    public static func run(
        _ statements: [String], on c: any DatabaseConnection, progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Int {
        var inserted = 0
        if !c.dialect.supportsTransactions {  // MongoDB standalone, ClickHouse
            for (i, sql) in statements.enumerated() {
                inserted += try await c.execute(sql).affectedRows ?? 0
                await progress(Double(i + 1) / Double(statements.count))
            }
            return inserted
        }
        _ = try await c.execute(c.dialect.beginTransaction)
        do {
            for (i, sql) in statements.enumerated() {
                let r = try await c.execute(sql)
                inserted += r.affectedRows ?? 0
                await progress(Double(i + 1) / Double(statements.count))
            }
            _ = try await c.execute("COMMIT")
        } catch {
            _ = try? await c.execute("ROLLBACK")
            throw error
        }
        return inserted
    }

    /// Default mapping onto existing columns by case-insensitive name.
    public func autoMapping(to columns: [String]) -> [String?] {
        header.map { h in columns.first { $0.caseInsensitiveCompare(h) == .orderedSame } }
    }
}
