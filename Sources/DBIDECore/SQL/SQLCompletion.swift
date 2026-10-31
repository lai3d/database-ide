import Foundation

public struct SQLCompletionItem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case keyword, schema, table, view, column, alias }
    public var label: String
    public var kind: Kind
    /// Type for columns, owning table, etc.
    public var detail: String?
    /// Text actually inserted (quoted when needed).
    public var insertText: String

    public init(label: String, kind: Kind, detail: String? = nil, insertText: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.insertText = insertText ?? label
    }
}

/// Catalog snapshot used for completion. Missing entries are reported back so the
/// caller can load them and ask again.
public struct CompletionCatalog: Sendable {
    public var schemas: [String] = []
    public var defaultSchema: String?
    /// schema → tables (absent = not loaded yet)
    public var tables: [String: [TableInfo]] = [:]
    /// "schema.table" → columns (absent = not loaded yet)
    public var columns: [String: [ColumnInfo]] = [:]

    public init(schemas: [String] = [], defaultSchema: String? = nil, tables: [String: [TableInfo]] = [:], columns: [String: [ColumnInfo]] = [:]) {
        self.schemas = schemas
        self.defaultSchema = defaultSchema
        self.tables = tables
        self.columns = columns
    }

    func table(schema: String?, name: String) -> TableInfo? {
        let s = schema ?? defaultSchema ?? ""
        let candidates = tables[s] ?? []
        return candidates.first { $0.name == name } ?? candidates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct SQLCompletionResult: Sendable {
    /// UTF-16 range of the partial word that an accepted item replaces.
    public var replaceRange: NSRange
    public var items: [SQLCompletionItem]
    /// Schemas whose tables should be loaded.
    public var missingSchemas: Set<String> = []
    /// Tables whose columns should be loaded.
    public var missingTables: Set<TableInfo> = []

    public init(replaceRange: NSRange, items: [SQLCompletionItem]) {
        self.replaceRange = replaceRange
        self.items = items
    }
}

public enum SQLCompletion {
    public static func complete(
        text: String, caret: Int, dialect: SQLDialect, catalog: CompletionCatalog, limit: Int = 200
    ) -> SQLCompletionResult {
        if dialect == .mongodb { return MongoCompletion.complete(text: text, caret: caret, catalog: catalog) }
        if dialect == .redis { return redisComplete(text: text, caret: caret, catalog: catalog) }
        let ns = text as NSString
        let caret = min(max(0, caret), ns.length)
        // Partial word before the caret.
        var start = caret
        while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        var result = SQLCompletionResult(replaceRange: NSRange(location: start, length: caret - start), items: [])

        // No completion inside strings or comments.
        let tokens = SQLLexer.tokenize(text, dialect: dialect)
        if tokens.contains(where: {
            ($0.kind == .string || $0.kind == .comment) && $0.location < caret && caret <= NSMaxRange($0.range)
                && !(caret == NSMaxRange($0.range) && $0.kind == .string)
        }) {
            return result
        }

        let statement = SQLSplitter.statement(at: start, in: text, dialect: dialect)
        let stmtText = statement?.text ?? text
        let stmtOffset = statement?.range.location ?? 0
        let aliases = tableReferences(in: stmtText, dialect: dialect)

        func columns(of t: TableInfo) -> [ColumnInfo]? {
            if let cols = catalog.columns[t.schema + "." + t.name] { return cols }
            result.missingTables.insert(t)
            return nil
        }
        func tables(in schema: String) -> [TableInfo]? {
            if let t = catalog.tables[schema] { return t }
            result.missingSchemas.insert(schema)
            return nil
        }
        func tableItem(_ t: TableInfo) -> SQLCompletionItem {
            SQLCompletionItem(
                label: t.name, kind: t.kind == .table ? .table : .view, detail: t.schema,
                insertText: quoteIfNeeded(t.name, dialect: dialect))
        }
        func columnItems(_ t: TableInfo) -> [SQLCompletionItem] {
            (columns(of: t) ?? []).map {
                SQLCompletionItem(
                    label: $0.name, kind: .column, detail: "\($0.type) · \(t.name)",
                    insertText: quoteIfNeeded($0.name, dialect: dialect))
            }
        }

        var items: [SQLCompletionItem] = []
        // `qualifier.` → columns of a table / alias, or tables of a schema.
        if start > 0, ns.character(at: start - 1) == 46 /* . */ {
            let qualifier = identifier(endingAt: start - 1, in: ns)
            let key = qualifier.lowercased()
            if let ref = aliases[key] {
                if let t = catalog.table(schema: ref.schema, name: ref.table) {
                    items = columnItems(t)
                } else if let s = ref.schema ?? catalog.defaultSchema {
                    _ = tables(in: s)
                }
            } else if let schema = catalog.schemas.first(where: { $0.caseInsensitiveCompare(qualifier) == .orderedSame }) {
                items = (tables(in: schema) ?? []).map(tableItem)
            } else if let t = catalog.table(schema: nil, name: qualifier) {
                items = columnItems(t)
            }
        } else {
            let context = previousKeyword(tokens: tokens, before: start, in: ns, notBefore: stmtOffset)
            let wantsTables = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE", "DESCRIBE"].contains(context)
            var tableItems: [SQLCompletionItem] = []
            if let schema = catalog.defaultSchema {
                tableItems = (tables(in: schema) ?? []).map(tableItem)
            }
            let schemaItems = catalog.schemas.map { SQLCompletionItem(label: $0, kind: .schema, insertText: quoteIfNeeded($0, dialect: dialect)) }
            var columnList: [SQLCompletionItem] = []
            var seenTables = Set<String>()
            for ref in aliases.values {
                guard let t = catalog.table(schema: ref.schema, name: ref.table), seenTables.insert(t.id).inserted else { continue }
                columnList += columnItems(t)
            }
            let aliasItems = aliases.filter { $0.value.alias != nil }.map {
                SQLCompletionItem(label: $0.value.alias!, kind: .alias, detail: $0.value.table)
            }
            let upper = prefix.uppercased()
            let lowercaseKeywords = prefix.first?.isLowercase ?? false
            let keywordItems = SQLKeywords.list.filter { prefix.isEmpty ? false : $0.hasPrefix(upper) }.map {
                SQLCompletionItem(label: lowercaseKeywords ? $0.lowercased() : $0, kind: .keyword)
            }
            items = wantsTables
                ? tableItems + schemaItems + keywordItems
                : columnList + aliasItems + tableItems + keywordItems + schemaItems
            // Bare caret with nothing typed only offers catalog names in a useful context.
            if prefix.isEmpty && !wantsTables && columnList.isEmpty { items = [] }
        }

        // Rank: prefix matches, then substring matches; keep group order within each.
        let p = prefix.lowercased()
        var seen = Set<String>()
        var ranked: [(Int, Int, SQLCompletionItem)] = []
        for (i, item) in items.enumerated() {
            let l = item.label.lowercased()
            let score: Int
            if p.isEmpty || l.hasPrefix(p) { score = 0 } else if p.count >= 2, l.contains(p) { score = 1 } else { continue }
            if item.label == prefix { continue }
            guard seen.insert(item.label + "\u{1}\(item.kind)").inserted else { continue }
            ranked.append((score, i, item))
        }
        ranked.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        result.items = ranked.prefix(limit).map(\.2)
        return result
    }

    /// Redis: command names for the first word of a line, key names afterwards.
    static func redisComplete(text: String, caret: Int, catalog: CompletionCatalog) -> SQLCompletionResult {
        let ns = text as NSString
        let caret = min(max(0, caret), ns.length)
        var start = caret
        while start > 0, let u = UnicodeScalar(ns.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(u) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        var result = SQLCompletionResult(replaceRange: NSRange(location: start, length: caret - start), items: [])
        let lineStart = ns.substring(to: start).components(separatedBy: "\n").last ?? ""
        let isFirstWord = lineStart.trimmingCharacters(in: .whitespaces).isEmpty
        var items: [SQLCompletionItem]
        if isFirstWord {
            let lower = prefix.first?.isLowercase ?? false
            items = SQLKeywords.redisCommands.map { SQLCompletionItem(label: lower ? $0.lowercased() : $0, kind: .keyword) }
        } else {
            let schema = catalog.defaultSchema ?? ""
            if catalog.tables[schema] == nil, !schema.isEmpty { result.missingSchemas.insert(schema) }
            items = (catalog.tables[schema] ?? []).map {
                SQLCompletionItem(label: $0.name, kind: .table, detail: $0.comment, insertText: $0.name.contains(" ") ? SQLDialect.redis.literal($0.name) : $0.name)
            }
        }
        guard !prefix.isEmpty || !isFirstWord else { return result }
        let p = prefix.lowercased()
        result.items = Array(items.filter { p.isEmpty || $0.label.lowercased().hasPrefix(p) }.filter { $0.label != prefix }.prefix(200))
        return result
    }

    public struct TableRef: Sendable, Hashable {
        public var schema: String?
        public var table: String
        public var alias: String?
    }

    /// Tables referenced by FROM / JOIN / UPDATE / INTO, keyed by lowercase alias and table name.
    public static func tableReferences(in sql: String, dialect: SQLDialect) -> [String: TableRef] {
        let ns = sql as NSString
        let tokens = SQLLexer.tokenize(sql, dialect: dialect).filter { $0.kind != .comment }
        func text(_ i: Int) -> String {
            ns.substring(with: tokens[i].range).trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
        }
        func isName(_ i: Int) -> Bool {
            i < tokens.count && (tokens[i].kind == .identifier || tokens[i].kind == .quotedIdentifier)
        }
        func isDot(_ i: Int) -> Bool { i < tokens.count && ns.substring(with: tokens[i].range) == "." }
        var out: [String: TableRef] = [:]
        var i = 0
        var inFromList = false
        while i < tokens.count {
            let word = ns.substring(with: tokens[i].range).uppercased()
            let starts = ["FROM", "JOIN", "UPDATE", "INTO"].contains(word) || (inFromList && word == ",")
            if tokens[i].kind == .keyword, !["FROM", "JOIN", "UPDATE", "INTO", "AS"].contains(word) { inFromList = false }
            if starts, isName(i + 1) {
                var j = i + 1
                var schema: String?
                var table = text(j)
                if isDot(j + 1), !isName(j + 2) {  // incomplete `schema.` being typed
                    i = j + 2
                    continue
                }
                if isDot(j + 1), isName(j + 2) {
                    schema = table
                    table = text(j + 2)
                    j += 2
                }
                j += 1
                if j < tokens.count, ns.substring(with: tokens[j].range).uppercased() == "AS" { j += 1 }
                var alias: String?
                if isName(j) {
                    alias = text(j)
                    j += 1
                }
                let ref = TableRef(schema: schema, table: table, alias: alias)
                out[table.lowercased()] = ref
                if let alias { out[alias.lowercased()] = ref }
                inFromList = word == "FROM" || (inFromList && word == ",")
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    public static func quoteIfNeeded(_ name: String, dialect: SQLDialect) -> String {
        let simple = name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_"
        } && !(name.first?.isNumber ?? true)
        let caseOK = dialect != .postgres || name == name.lowercased()
        let reserved = SQLKeywords.all.contains(name.uppercased())
        return simple && caseOK && !reserved ? name : dialect.quote(name)
    }

    private static func previousKeyword(tokens: [SQLToken], before offset: Int, in ns: NSString, notBefore: Int) -> String? {
        for t in tokens.reversed() where NSMaxRange(t.range) <= offset && t.location >= notBefore {
            if t.kind == .keyword { return ns.substring(with: t.range).uppercased() }
            if t.kind == .semicolon { return nil }
        }
        return nil
    }

    private static func identifier(endingAt end: Int, in ns: NSString) -> String {
        var s = end
        while s > 0, isWordChar(ns.character(at: s - 1)) || ns.character(at: s - 1) == 34 || ns.character(at: s - 1) == 96 { s -= 1 }
        return ns.substring(with: NSRange(location: s, length: end - s)).trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
    }

    static func isWordChar(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 128
    }
}
