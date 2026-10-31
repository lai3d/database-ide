import Foundation

public enum ResultExport {
    public enum Format: String, CaseIterable, Sendable {
        case csv, tsv, json, markdown, sqlInsert

        public var title: String {
            switch self {
            case .csv: "CSV"
            case .tsv: "TSV"
            case .json: "JSON"
            case .markdown: "Markdown"
            case .sqlInsert: "SQL INSERT"
            }
        }

        public var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .tsv: "tsv"
            case .json: "json"
            case .markdown: "md"
            case .sqlInsert: "sql"
            }
        }
    }

    public static func render(
        columns: [ResultColumn], rows: [[SQLValue]], format: Format, includeHeader: Bool = true,
        dialect: SQLDialect = .postgres, tableName: String = "my_table"
    ) -> String {
        let names = columns.map(\.name)
        switch format {
        case .csv:
            var lines = includeHeader ? [names.map(csvField).joined(separator: ",")] : []
            lines += rows.map { $0.map { $0.isNull ? "" : csvField($0.exportString) }.joined(separator: ",") }
            return lines.joined(separator: "\n") + "\n"
        case .tsv:
            func clean(_ s: String) -> String {
                s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            }
            var lines = includeHeader ? [names.map(clean).joined(separator: "\t")] : []
            lines += rows.map { $0.map { clean($0.exportString) }.joined(separator: "\t") }
            return lines.joined(separator: "\n")
        case .json:
            let objects: [[String: Any]] = rows.map { row in
                var o: [String: Any] = [:]
                for (i, v) in row.enumerated() where i < names.count {
                    switch v {
                    case .null: o[names[i]] = NSNull()
                    case .integer(let x): o[names[i]] = x
                    case .real(let x): o[names[i]] = x
                    default: o[names[i]] = v.exportString
                    }
                }
                return o
            }
            let data = (try? JSONSerialization.data(
                withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        case .markdown:
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            }
            var lines = ["| " + names.map(esc).joined(separator: " | ") + " |"]
            lines.append("|" + names.map { _ in " --- " }.joined(separator: "|") + "|")
            lines += rows.map { "| " + $0.map { esc($0.displayString) }.joined(separator: " | ") + " |" }
            return lines.joined(separator: "\n") + "\n"
        case .sqlInsert:
            let cols = names.map { dialect.quote($0) }.joined(separator: ", ")
            return rows.map { row in
                let values = row.map { sqlLiteral($0, dialect: dialect) }.joined(separator: ", ")
                return "INSERT INTO \(tableName) (\(cols)) VALUES (\(values));"
            }.joined(separator: "\n") + "\n"
        }
    }

    public static func sqlLiteral(_ v: SQLValue, dialect: SQLDialect) -> String {
        switch v {
        case .null: return "NULL"
        case .integer(let x): return String(x)
        case .real(let x): return String(x)
        case .text(let s): return dialect.literal(s)
        case .blob(let d):
            let hex = d.map { String(format: "%02X", $0) }.joined()
            return dialect == .postgres ? "'\\x\(hex)'::bytea" : dialect == .sqlserver ? "0x\(hex)" : "X'\(hex)'"
        }
    }

    static func csvField(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
