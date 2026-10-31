import Foundation

extension MongoConnection {
    func introspectDatabases() async throws -> [String] {
        let r = try await runCommand(["listDatabases": .int32(1), "nameOnly": .bool(true)], db: "admin")
        let names = (r["databases"]?.array ?? []).compactMap { $0.document?["name"]?.string }
            .filter { !["config", "local"].contains($0) }
        return names.sorted { ($0 == "admin" ? 1 : 0, $0) < ($1 == "admin" ? 1 : 0, $1) }
    }

    func introspectCollections(_ db: String) async throws -> [TableInfo] {
        let docs = try await cursor(["listCollections": .int32(1), "authorizedCollections": .bool(true)], db: db)
        return docs.compactMap { d -> TableInfo? in
            guard let name = d["name"]?.string, !name.hasPrefix("system.") else { return nil }
            return TableInfo(schema: db, name: name, kind: d["type"]?.string == "view" ? .view : .table)
        }.sorted { $0.name < $1.name }
    }

    /// Fields seen in a sample of documents, with the most common type.
    func introspectFields(_ db: String, _ collection: String, sample: Int = 200) async throws -> [ColumnInfo] {
        let docs = try await cursor([
            "aggregate": .string(collection), "pipeline": .array([.document(["$sample": .document(["size": .int32(Int32(sample))])])]),
            "cursor": .document([:]),
        ], db: db, limit: sample)
        var order: [String] = []
        var counts: [String: Int] = [:]
        var types: [String: [String: Int]] = [:]
        for d in docs {
            for e in d.elements {
                if counts[e.key] == nil { order.append(e.key) }
                counts[e.key, default: 0] += 1
                types[e.key, default: [:]][e.value.typeName, default: 0] += 1
            }
        }
        if let i = order.firstIndex(of: "_id"), i > 0 { order.insert(order.remove(at: i), at: 0) }
        return order.map { k in
            let t = types[k]!.sorted { $0.value > $1.value }.map(\.key)
            return ColumnInfo(
                name: k, type: t.count > 1 ? t.prefix(3).joined(separator: "|") : (t.first ?? ""),
                nullable: counts[k]! < docs.count || types[k]!["null"] != nil, defaultValue: nil, isPrimaryKey: k == "_id")
        }
    }

    func introspectIndexes(_ db: String, _ collection: String) async throws -> [IndexInfo] {
        try await cursor(["listIndexes": .string(collection)], db: db).map { d in
            let key = d["key"]?.document ?? [:]
            return IndexInfo(
                name: d["name"]?.string ?? "?",
                columns: key.elements.map { "\($0.key) \($0.value.shellString)" },
                unique: d["unique"]?.bool ?? (d["name"]?.string == "_id_"),
                primary: d["name"]?.string == "_id_")
        }
    }

    /// Shell commands that recreate the collection and its indexes.
    func introspectDDL(_ t: TableInfo) async throws -> String {
        let info = try await cursor(["listCollections": .int32(1), "filter": .document(["name": .string(t.name)])], db: t.schema).first
        var out: [String] = []
        let options = info?["options"]?.document ?? [:]
        out.append(options.isEmpty
            ? "db.createCollection(\(BSONFormatter.quote(t.name)))"
            : "db.createCollection(\(BSONFormatter.quote(t.name)), \(options.prettyString))")
        if t.kind == .table {
            for d in try await cursor(["listIndexes": .string(t.name)], db: t.schema) where d["name"]?.string != "_id_" {
                var opts = d
                for k in ["v", "key", "ns"] { opts[k] = nil }
                out.append("db.getCollection(\(BSONFormatter.quote(t.name))).createIndex(\(d["key"]?.shellString ?? "{}"), \(opts.shellString))")
            }
        }
        return out.joined(separator: ";\n\n") + ";"
    }
}
