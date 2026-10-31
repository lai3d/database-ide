import Foundation

/// Converts documents into a grid result (top-level fields become columns).
public enum MongoResults {
    public static func result(_ docs: [BSONDocument], statement: String, truncated: Bool = false) -> QueryResult {
        var keys: [String] = []
        var seen = Set<String>()
        var types: [String: [String: Int]] = [:]
        for d in docs {
            for e in d.elements {
                if seen.insert(e.key).inserted { keys.append(e.key) }
                types[e.key, default: [:]][e.value.typeName, default: 0] += 1
            }
        }
        if let i = keys.firstIndex(of: "_id"), i > 0 { keys.insert(keys.remove(at: i), at: 0) }
        let columns = keys.map { k in
            ResultColumn(name: k, typeName: types[k]?.max { $0.value < $1.value }?.key ?? "")
        }
        let rows = docs.map { d in keys.map { k in d[k].map(cell) ?? .null } }
        return QueryResult(statement: statement, columns: columns, rows: rows, truncated: truncated, documents: docs)
    }

    /// Converts an edited grid value back to BSON, keeping the original field's type when possible.
    public static func bson(_ v: SQLValue, like original: BSONValue?) -> BSONValue {
        switch v {
        case .null: return .null
        case .integer(let i):
            if case .int32? = original, let i32 = Int32(exactly: i) { return .int32(i32) }
            if case .double? = original { return .double(Double(i)) }
            return Int32(exactly: i).map(BSONValue.int32) ?? .int64(i)
        case .real(let d): return .double(d)
        case .blob(let d): return .binary(subtype: 0, d)
        case .text(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            switch original {
            case .bool?: if t == "true" || t == "false" { return .bool(t == "true") }
            case .int32?: if let i = Int32(t) { return .int32(i) }
            case .int64?: if let i = Int64(t) { return .int64(i) }
            case .double?: if let d = Double(t) { return .double(d) }
            case .objectId?: if let id = ObjectID(hex: t) { return .objectId(id) }
            case .date?: if let ms = MongoShellParser.parseDate(t) { return .date(ms) }
            case .decimal128?: if let d = Decimal128(t) { return .decimal128(d) }
            case .document?, .array?: if let parsed = try? MongoShellParser.parseValue(s) { return parsed }
            default: break
            }
            return .string(s)
        }
    }

    public static func cell(_ v: BSONValue) -> SQLValue {
        switch v {
        case .int32(let i): .integer(Int64(i))
        case .int64(let i): .integer(i)
        case .double(let d): .real(d)
        case .string(let s): .text(s)
        case .bool(let b): .text(b ? "true" : "false")
        case .null, .undefined: .null
        case .objectId(let id): .text(id.hex)
        case .date(let ms): .text(BSONFormatter.dateString(ms))
        case .decimal128(let d): .text(d.description)
        default: .text(v.shellString)
        }
    }
}

extension MongoConnection: DatabaseConnection {
    public var dialect: SQLDialect { .mongodb }
    public var inTransaction: Bool { false }

    public func execute(_ text: String, maxRows: Int) async throws -> QueryResult {
        let statement = try MongoShellParser.parse(text)
        let tag = "dbide:" + UUID().uuidString
        setRunningTag(tag)
        defer { setRunningTag(nil) }
        let start = Date()
        var result = try await onWorker { [self] in try executeSync(statement, text: text, maxRows: maxRows, tag: tag) }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// Kills the running operation (found by its comment tag) from a second connection.
    public func cancel() {
        guard let tag = runningTag else { return }
        let (host, port, user, password, authSource, tls) = (host, port, user, password, authSource, tls)
        Task.detached {
            guard let killer = try? await MongoConnection.connect(
                host: host, port: port, user: user, password: password, database: "admin", authSource: authSource, tls: tls)
            else { return }
            if let ops = try? await killer.runCommand(["currentOp": .bool(true), "command.comment": .string(tag)], db: "admin"),
                let inprog = ops["inprog"]?.array
            {
                for op in inprog.compactMap(\.document) {
                    if let opid = op["opid"] { _ = try? await killer.runCommand(["killOp": .int32(1), "op": opid], db: "admin") }
                }
            }
            await killer.close()
        }
    }

    // MARK: Execution

    private func executeSync(_ st: MongoStatement, text: String, maxRows: Int, tag: String) throws -> QueryResult {
        func single(_ doc: BSONDocument) -> QueryResult { MongoResults.result([doc], statement: text) }
        func message(_ msg: String, affected: Int? = nil) -> QueryResult {
            QueryResult(statement: text, affectedRows: affected, message: msg)
        }
        let db = database
        switch st {
        case .use(let name):
            database = name
            return message("switched to db \(name)")
        case .show(let what):
            switch what {
            case "dbs", "databases":
                let r = try runSync(["listDatabases": .int32(1)], db: "admin")
                return MongoResults.result((r["databases"]?.array ?? []).compactMap(\.document), statement: text)
            case "collections", "tables":
                let docs = try cursorSync(["listCollections": .int32(1), "nameOnly": .bool(true)], db: db, limit: .max).docs
                return MongoResults.result(docs.map { ["name": $0["name"] ?? .null, "type": $0["type"] ?? .null] }.sorted {
                    ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "")
                }, statement: text)
            case "users":
                let r = try runSync(["usersInfo": .int32(1)], db: db)
                return MongoResults.result((r["users"]?.array ?? []).compactMap(\.document), statement: text)
            default:
                throw DatabaseError("Unsupported: show \(what)")
            }
        case .database(let method, let args):
            return try databaseMethod(method, args, text: text, db: db)
        case .collection(let coll, let method, let args, let modifiers):
            return try collectionMethod(coll, method, args, modifiers, text: text, db: db, maxRows: maxRows, tag: tag)
        }
    }

    private func databaseMethod(_ method: String, _ args: [BSONValue], text: String, db: String) throws -> QueryResult {
        func single(_ doc: BSONDocument) -> QueryResult { MongoResults.result([doc], statement: text) }
        switch method {
        case "runCommand", "adminCommand":
            let cmd: BSONDocument
            if let d = args.first?.document { cmd = d } else if let s = args.first?.string { cmd = [s: .int32(1)] } else {
                throw DatabaseError("\(method) needs a command document")
            }
            return single(try runSync(cmd, db: method == "adminCommand" ? "admin" : db))
        case "getCollectionNames":
            let docs = try cursorSync(["listCollections": .int32(1), "nameOnly": .bool(true)], db: db, limit: .max).docs
            return MongoResults.result(docs.compactMap { $0["name"] }.map { ["name": $0] }, statement: text)
        case "getCollectionInfos":
            var cmd: BSONDocument = ["listCollections": .int32(1)]
            if let f = args.first?.document { cmd["filter"] = .document(f) }
            return MongoResults.result(try cursorSync(cmd, db: db, limit: .max).docs, statement: text)
        case "createCollection":
            guard let name = args.first?.string else { throw DatabaseError("createCollection needs a name") }
            var cmd: BSONDocument = ["create": .string(name)]
            for e in args.dropFirst().first?.document?.elements ?? [] { cmd[e.key] = e.value }
            _ = try runSync(cmd, db: db)
            return QueryResult(statement: text, message: "created collection \(name)")
        case "createView":
            guard args.count >= 3, let name = args[0].string, let source = args[1].string else {
                throw DatabaseError("createView(name, source, pipeline)")
            }
            _ = try runSync(["create": .string(name), "viewOn": .string(source), "pipeline": args[2]], db: db)
            return QueryResult(statement: text, message: "created view \(name)")
        case "dropDatabase":
            _ = try runSync(["dropDatabase": .int32(1)], db: db)
            return QueryResult(statement: text, message: "dropped database \(db)")
        case "stats": return single(try runSync(["dbStats": .int32(1)], db: db))
        case "serverStatus": return single(try runSync(["serverStatus": .int32(1)], db: "admin"))
        case "hostInfo": return single(try runSync(["hostInfo": .int32(1)], db: "admin"))
        case "currentOp": return single(try runSync(["currentOp": .int32(1)], db: "admin"))
        case "getUsers":
            let r = try runSync(["usersInfo": .int32(1)], db: db)
            return MongoResults.result((r["users"]?.array ?? []).compactMap(\.document), statement: text)
        case "version":
            return single(["version": try runSync(["buildInfo": .int32(1)], db: "admin")["version"] ?? .null])
        case "getName":
            return single(["name": .string(db)])
        default:
            throw DatabaseError("Unsupported database method db.\(method)()")
        }
    }

    private func collectionMethod(
        _ coll: String, _ method: String, _ args: [BSONValue], _ modifiers: [MongoStatement.Modifier],
        text: String, db: String, maxRows: Int, tag: String
    ) throws -> QueryResult {
        func arg(_ i: Int) -> BSONDocument? { i < args.count ? args[i].document : nil }
        func written(_ r: BSONDocument, _ verb: String) -> QueryResult {
            let n = Int(r["n"]?.int ?? 0)
            return QueryResult(statement: text, affectedRows: n, message: "\(verb) \(n) document\(n == 1 ? "" : "s")")
        }
        func withComment(_ cmd: BSONDocument) -> BSONDocument {
            var c = cmd
            c["comment"] = .string(tag)
            return c
        }
        let modifier = { (name: String) in modifiers.last { $0.name == name } }

        switch method {
        case "find", "findOne":
            var cmd: BSONDocument = ["find": .string(coll), "filter": .document(arg(0) ?? [:])]
            if let p = arg(1) ?? modifier("projection")?.args.first?.document { cmd["projection"] = .document(p) }
            if let s = modifier("sort")?.args.first?.document { cmd["sort"] = .document(s) }
            if let s = modifier("skip")?.args.first?.int { cmd["skip"] = .int64(s) }
            if let h = modifier("hint")?.args.first { cmd["hint"] = h }
            if let c = modifier("collation")?.args.first { cmd["collation"] = c }
            if let t = modifier("maxTimeMS")?.args.first?.int { cmd["maxTimeMS"] = .int64(t) }
            var limit = Int(modifier("limit")?.args.first?.int ?? 0)
            if method == "findOne" { limit = 1 }
            if modifier("count") != nil || modifier("countDocuments") != nil {
                var count: BSONDocument = ["count": .string(coll), "query": cmd["filter"]!]
                if let s = cmd["skip"] { count["skip"] = s }
                if limit > 0 { count["limit"] = .int64(Int64(limit)) }
                return MongoResults.result([["count": try runSync(withComment(count), db: db)["n"] ?? .int32(0)]], statement: text)
            }
            if modifier("explain") != nil {
                let verbosity = modifier("explain")?.args.first?.string ?? "queryPlanner"
                if limit > 0 { cmd["limit"] = .int64(Int64(limit)) }
                return MongoResults.result([try runSync(["explain": .document(cmd), "verbosity": .string(verbosity)], db: db)], statement: text)
            }
            let cap = limit > 0 ? min(limit, maxRows) : maxRows
            if limit > 0 { cmd["limit"] = .int64(Int64(limit)) }
            cmd["batchSize"] = .int32(Int32(min(cap, 1000) + (cap < 1000 ? 1 : 0)))
            if method == "findOne" { cmd["singleBatch"] = .bool(true) }
            let (docs, truncated) = try cursorSync(withComment(cmd), db: db, limit: cap)
            return MongoResults.result(docs, statement: text, truncated: truncated && (limit == 0 || limit > maxRows))
        case "aggregate":
            let pipeline = args.first ?? .array([])
            var cmd: BSONDocument = ["aggregate": .string(coll), "pipeline": pipeline, "cursor": .document(["batchSize": .int32(Int32(min(maxRows, 1000)))])]
            for e in arg(1)?.elements ?? [] { cmd[e.key] = e.value }
            if modifier("explain") != nil {
                cmd["cursor"] = nil
                return MongoResults.result([try runSync(["explain": .document(cmd), "verbosity": .string("queryPlanner")], db: db)], statement: text)
            }
            let (docs, truncated) = try cursorSync(withComment(cmd), db: db, limit: maxRows)
            return MongoResults.result(docs, statement: text, truncated: truncated)
        case "countDocuments":
            let pipeline: BSONValue = .array([
                .document(["$match": .document(arg(0) ?? [:])]),
                .document(["$group": .document(["_id": .int32(1), "n": .document(["$sum": .int32(1)])])]),
            ])
            let docs = try cursorSync(withComment(["aggregate": .string(coll), "pipeline": pipeline, "cursor": .document([:])]), db: db, limit: 1).docs
            return MongoResults.result([["count": docs.first?["n"] ?? .int32(0)]], statement: text)
        case "estimatedDocumentCount", "count":
            var cmd: BSONDocument = ["count": .string(coll)]
            if let q = arg(0) { cmd["query"] = .document(q) }
            return MongoResults.result([["count": try runSync(withComment(cmd), db: db)["n"] ?? .int32(0)]], statement: text)
        case "distinct":
            guard let key = args.first?.string else { throw DatabaseError("distinct(field, filter)") }
            var cmd: BSONDocument = ["distinct": .string(coll), "key": .string(key)]
            if let q = arg(1) { cmd["query"] = .document(q) }
            let values = try runSync(withComment(cmd), db: db)["values"]?.array ?? []
            return MongoResults.result(values.map { [key: $0] }, statement: text)
        case "insertOne", "insert" where args.first?.document != nil:
            var doc = arg(0)!
            if doc["_id"] == nil { doc.elements.insert(.init(key: "_id", value: .objectId(.generate())), at: 0) }
            let r = try runSync(["insert": .string(coll), "documents": .array([.document(doc)])], db: db)
            var res = written(r, "inserted")
            res.message = "inserted 1 document, _id: \(doc["_id"]!.shellString)"
            return res
        case "insertMany", "insert":
            guard let items = args.first?.array else { throw DatabaseError("insertMany needs an array of documents") }
            let docs: [BSONValue] = items.map { v in
                guard var d = v.document else { return v }
                if d["_id"] == nil { d.elements.insert(.init(key: "_id", value: .objectId(.generate())), at: 0) }
                return .document(d)
            }
            var cmd: BSONDocument = ["insert": .string(coll), "documents": .array(docs)]
            if let ordered = arg(1)?["ordered"] { cmd["ordered"] = ordered }
            return written(try runSync(cmd, db: db), "inserted")
        case "updateOne", "updateMany", "replaceOne":
            guard args.count >= 2 else { throw DatabaseError("\(method)(filter, update, options)") }
            var spec: BSONDocument = ["q": .document(arg(0) ?? [:]), "u": args[1], "multi": .bool(method == "updateMany")]
            for e in arg(2)?.elements ?? [] where ["upsert", "arrayFilters", "collation", "hint"].contains(e.key) { spec[e.key] = e.value }
            let r = try runSync(withComment(["update": .string(coll), "updates": .array([.document(spec)])]), db: db)
            let matched = Int(r["n"]?.int ?? 0), modified = Int(r["nModified"]?.int ?? 0)
            let upserted = r["upserted"]?.array?.count ?? 0
            return QueryResult(
                statement: text, affectedRows: matched + upserted,
                message: "matched \(matched), modified \(modified)" + (upserted > 0 ? ", upserted \(upserted)" : ""))
        case "deleteOne", "deleteMany", "remove":
            let spec: BSONDocument = ["q": .document(arg(0) ?? [:]), "limit": .int32(method == "deleteOne" ? 1 : 0)]
            return written(try runSync(withComment(["delete": .string(coll), "deletes": .array([.document(spec)])]), db: db), "deleted")
        case "createIndex":
            guard let keys = arg(0) else { throw DatabaseError("createIndex(keys, options)") }
            var index: BSONDocument = ["key": .document(keys)]
            let options = arg(1) ?? [:]
            index["name"] = options["name"] ?? .string(keys.elements.map { "\($0.key)_\($0.value.int.map(String.init) ?? $0.value.string ?? "1")" }.joined(separator: "_"))
            for e in options.elements where e.key != "name" { index[e.key] = e.value }
            _ = try runSync(["createIndexes": .string(coll), "indexes": .array([.document(index)])], db: db)
            return QueryResult(statement: text, message: "created index \(index["name"]!.string ?? "")")
        case "dropIndex":
            guard let index = args.first else { throw DatabaseError("dropIndex(name or keys)") }
            _ = try runSync(["dropIndexes": .string(coll), "index": index], db: db)
            return QueryResult(statement: text, message: "dropped index")
        case "getIndexes":
            return MongoResults.result(try cursorSync(["listIndexes": .string(coll)], db: db, limit: .max).docs, statement: text)
        case "drop":
            _ = try runSync(["drop": .string(coll)], db: db)
            return QueryResult(statement: text, message: "dropped collection \(coll)")
        case "renameCollection":
            guard let to = args.first?.string else { throw DatabaseError("renameCollection(newName)") }
            _ = try runSync(["renameCollection": .string("\(db).\(coll)"), "to": .string("\(db).\(to)")], db: "admin")
            return QueryResult(statement: text, message: "renamed to \(to)")
        case "stats":
            return MongoResults.result(try cursorSync(["aggregate": .string(coll), "pipeline": .array([.document(["$collStats": .document(["storageStats": .document([:])])])]), "cursor": .document([:])], db: db, limit: 1).docs, statement: text)
        default:
            throw DatabaseError("Unsupported collection method \(method)()")
        }
    }
}
