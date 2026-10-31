import Foundation

/// Completion for the MongoDB shell console.
public enum MongoCompletion {
    static let dbMethods = [
        "getCollection", "getCollectionNames", "getCollectionInfos", "createCollection", "createView", "runCommand",
        "adminCommand", "stats", "dropDatabase", "serverStatus", "version", "getName", "getUsers", "currentOp", "hostInfo",
    ]
    static let collectionMethods = [
        "find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount", "distinct", "insertOne", "insertMany",
        "updateOne", "updateMany", "replaceOne", "deleteOne", "deleteMany", "createIndex", "dropIndex", "getIndexes",
        "drop", "renameCollection", "stats",
    ]
    static let cursorMethods = ["sort", "limit", "skip", "projection", "count", "explain", "hint", "collation", "maxTimeMS"]
    static let operators = [
        "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$exists", "$regex", "$and", "$or", "$not", "$nor",
        "$elemMatch", "$size", "$type", "$set", "$unset", "$inc", "$push", "$pull", "$addToSet", "$match", "$group",
        "$project", "$sort", "$limit", "$skip", "$unwind", "$lookup", "$count", "$sum", "$avg", "$min", "$max", "$first",
        "$last", "$addFields", "$facet", "$out", "$merge",
    ]

    public static func complete(text: String, caret: Int, catalog: CompletionCatalog) -> SQLCompletionResult {
        let ns = text as NSString
        let caret = min(max(0, caret), ns.length)
        var start = caret
        while start > 0, SQLCompletion.isWordChar(ns.character(at: start - 1)) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        var result = SQLCompletionResult(replaceRange: NSRange(location: start, length: caret - start), items: [])
        let before = ns.substring(to: start)
        let db = catalog.defaultSchema ?? ""

        func collections() -> [SQLCompletionItem] {
            guard let tables = catalog.tables[db] else {
                if !db.isEmpty { result.missingSchemas.insert(db) }
                return []
            }
            return tables.map { SQLCompletionItem(label: $0.name, kind: $0.kind == .table ? .table : .view, detail: db) }
        }
        func fields(_ coll: String) -> [SQLCompletionItem] {
            guard let t = catalog.table(schema: db, name: coll) else { return [] }
            guard let cols = catalog.columns[db + "." + t.name] else {
                result.missingTables.insert(t)
                return []
            }
            return cols.map { SQLCompletionItem(label: $0.name, kind: .column, detail: $0.type) }
        }
        func methods(_ names: [String]) -> [SQLCompletionItem] { names.map { SQLCompletionItem(label: $0, kind: .keyword) } }

        var items: [SQLCompletionItem] = []
        let statementStart = before.range(of: #"(^|[;\n])\s*(db\b|show\b|use\b)[^;\n]*$"#, options: .regularExpression)
        let current = statementStart.map { String(before[$0]) } ?? before
        let collection = Self.collectionName(in: current)
        let openBraces = current.filter { $0 == "{" }.count - current.filter { $0 == "}" }.count

        if before.hasSuffix("db.") {
            items = collections() + methods(dbMethods)
        } else if collection != nil, current.range(of: #"db(\.[A-Za-z_][\w]*|\.getCollection\(\s*['"][^'"]+['"]\s*\))\.$"#, options: .regularExpression) != nil {
            items = methods(collectionMethods)
        } else if before.hasSuffix(")."), collection != nil {
            items = methods(cursorMethods)
        } else if openBraces > 0, let collection {
            items = (prefix.hasPrefix("$") || before.hasSuffix("$") ? [] : fields(collection))
                + operators.map { SQLCompletionItem(label: $0, kind: .keyword) }
            if before.hasSuffix("$") {  // `$` is not a word char: include it in the replaced range
                result.replaceRange = NSRange(location: start - 1, length: caret - start + 1)
                items = operators.map { SQLCompletionItem(label: $0, kind: .keyword) }
                return finish(&result, items, prefix: "$" + prefix)
            }
        } else if before.range(of: #"(^|[;\n])\s*use\s+$"#, options: .regularExpression) != nil {
            items = catalog.schemas.map { SQLCompletionItem(label: $0, kind: .schema) }
        } else if !prefix.isEmpty {
            items = methods(["db", "show", "use"])
        }
        return finish(&result, items, prefix: prefix)
    }

    private static func finish(_ result: inout SQLCompletionResult, _ items: [SQLCompletionItem], prefix: String) -> SQLCompletionResult {
        let p = prefix.lowercased()
        var seen = Set<String>()
        result.items = items.filter {
            (p.isEmpty || $0.label.lowercased().hasPrefix(p)) && $0.label != prefix && seen.insert($0.label).inserted
        }
        return result
    }

    /// Collection named by `db.<name>.` or `db.getCollection('<name>')` in a statement prefix.
    public static func collectionName(in text: String) -> String? {
        if let r = text.range(of: #"db\.getCollection\(\s*['"]([^'"]+)['"]\s*\)"#, options: .regularExpression) {
            let m = String(text[r])
            return m.split(whereSeparator: { $0 == "'" || $0 == "\"" }).dropFirst().first.map(String.init)
        }
        if let r = text.range(of: #"db\.[A-Za-z_][\w]*\."#, options: .regularExpression) {
            let name = String(text[r].dropFirst(3).dropLast())
            return dbMethods.contains(name) ? nil : name
        }
        return nil
    }
}
