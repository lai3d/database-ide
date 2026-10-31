import Foundation
import Testing

@testable import DBIDECore

@Suite struct BSONTests {
    @Test func roundTrip() throws {
        let id = ObjectID(hex: "65a1b2c3d4e5f60718293a4b")!
        let doc: BSONDocument = [
            "_id": .objectId(id), "s": .string("hé"), "i": .int32(-5), "l": .int64(1 << 40), "d": .double(2.5),
            "b": .bool(true), "n": .null, "dt": .date(1_700_000_000_123),
            "a": .array([.int32(1), .document(["x": .string("y")])]), "re": .regex(pattern: "^a", options: "i"),
            "bin": .binary(subtype: 0, Data([1, 2, 3])), "dec": .decimal128(Decimal128("123.4500")!),
        ]
        let back = try BSON.decode(BSON.encode(doc))
        #expect(back == doc)
        #expect(back.keys.first == "_id")  // order preserved
    }

    @Test func decimal128() {
        for s in ["0", "1", "-1", "123.45", "0.001", "1E+3", "12345678901234567890123456789012.34"] {
            #expect(Decimal128(s)?.description == s, "\(s)")
        }
        #expect(Decimal128("abc") == nil)
    }

    @Test func shellFormatting() {
        let doc: BSONDocument = ["_id": .objectId(ObjectID(hex: "65a1b2c3d4e5f60718293a4b")!), "name": .string("it's"),
                                 "n": .int64(3), "tags": .array([.string("a")]), "dt": .date(0), "my key": .int32(1)]
        #expect(doc.shellString == "{ _id: ObjectId('65a1b2c3d4e5f60718293a4b'), name: 'it\\'s', n: Long('3'), tags: [ 'a' ], dt: ISODate('1970-01-01T00:00:00.000Z'), 'my key': 1 }")
        #expect(BSONValue.document(["a": .document(["b": .int32(1)])]).prettyString == "{\n  a: {\n    b: 1\n  }\n}")
    }
}

/// DBIDE_MONGO=host:port:user:password
struct MongoEnv {
    var host: String, port: Int, user: String, password: String
    static var current: MongoEnv? {
        guard let v = ProcessInfo.processInfo.environment["DBIDE_MONGO"] else { return nil }
        let p = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, let port = Int(p[1]) else { return nil }
        return MongoEnv(host: p[0], port: port, user: p[2], password: p[3])
    }
}

@Suite(.enabled(if: MongoEnv.current != nil), .serialized)
struct MongoDriverTests {
    let env = MongoEnv.current!

    func connect(db: String = "dbide_test") async throws -> MongoConnection {
        try await MongoConnection.connect(host: env.host, port: env.port, user: env.user, password: env.password, database: db)
    }

    @Test func authAndCommands() async throws {
        let c = try await connect()
        #expect(c.serverVersion.hasPrefix("MongoDB 7"))
        _ = try? await c.runCommand(["drop": .string("items")])
        let docs = (0..<2500).map { BSONValue.document(["n": .int32(Int32($0)), "even": .bool($0 % 2 == 0)]) }
        let ins = try await c.runCommand(["insert": .string("items"), "documents": .array(docs)])
        #expect(ins["n"]?.int == 2500)
        // Cursor across several getMore batches, truncated at the limit.
        let some = try await c.cursor(["find": .string("items"), "filter": .document(["even": .bool(true)]), "sort": .document(["n": .int32(1)]), "batchSize": .int32(101)], limit: 1200)
        #expect(some.count == 1200 && some.last?["n"]?.int == 2398)
        await #expect(throws: DatabaseError.self) { _ = try await c.runCommand(["nosuchcommand": .int32(1)]) }
        _ = try await c.runCommand(["drop": .string("items")])
        await c.close()
    }

    @Test func sha1User() async throws {
        let admin = try await connect(db: "admin")
        _ = try? await admin.runCommand(["dropUser": .string("legacy")], db: "admin")
        _ = try await admin.runCommand(["createUser": .string("legacy"), "pwd": .string("p@ss,w=rd"), "roles": .array([]), "mechanisms": .array([.string("SCRAM-SHA-1")])], db: "admin")
        let c = try await MongoConnection.connect(host: env.host, port: env.port, user: "legacy", password: "p@ss,w=rd", database: "admin")
        _ = try await c.runCommand(["ping": .int32(1)])
        await c.close()
        _ = try await admin.runCommand(["dropUser": .string("legacy")], db: "admin")
        await admin.close()
    }

    @Test func wrongPassword() async throws {
        await #expect(throws: DatabaseError.self) {
            _ = try await MongoConnection.connect(host: env.host, port: env.port, user: env.user, password: "nope", database: "x")
        }
    }
}

@Suite struct MongoShellParserTests {
    @Test func statements() throws {
        let st = try MongoShellParser.parse("db.users.find({ age: { $gt: 30 }, name: /^a/i, 'x.y': \"q\" }, {name: 1,}).sort({age: -1}).limit(5);")
        guard case .collection(let coll, let method, let args, let mods) = st else { Issue.record("wrong kind"); return }
        #expect(coll == "users" && method == "find" && mods.map(\.name) == ["sort", "limit"])
        #expect(args[0].document?["age"]?.document?["$gt"] == .int32(30))
        #expect(args[0].document?["name"] == .regex(pattern: "^a", options: "i"))
        #expect(args[0].document?["x.y"] == .string("q"))
        #expect(mods[1].args == [.int32(5)])

        #expect(try MongoShellParser.parse("db.getCollection('my coll').countDocuments()")
            == .collection(name: "my coll", method: "countDocuments", args: [], modifiers: []))
        #expect(try MongoShellParser.parse("db.system.users.find()")
            == .collection(name: "system.users", method: "find", args: [], modifiers: []))
        #expect(try MongoShellParser.parse("show dbs") == .show("dbs"))
        #expect(try MongoShellParser.parse("use shop") == .use("shop"))
        #expect(try MongoShellParser.parse("db.runCommand({ ping: 1 })") == .database(method: "runCommand", args: [.document(["ping": .int32(1)])]))
    }

    @Test func values() throws {
        let v = try MongoShellParser.parseValue(
            "{ id: ObjectId('65a1b2c3d4e5f60718293a4b'), d: ISODate('2024-01-02T03:04:05Z'), n: NumberLong(5), big: 3000000000, f: 1.5, e: -2e3, dec: NumberDecimal('1.10'), u: UUID('123e4567-e89b-12d3-a456-426614174000'), b: true, z: null, s: 'it\\'s', arr: [1, 'a',] }")
        let d = v.document!
        #expect(d["id"] == .objectId(ObjectID(hex: "65a1b2c3d4e5f60718293a4b")!))
        #expect(d["d"] == .date(1_704_164_645_000))
        #expect(d["n"] == .int64(5) && d["big"] == .int64(3_000_000_000) && d["f"] == .double(1.5) && d["e"] == .double(-2000))
        #expect(d["dec"] == .decimal128(Decimal128("1.10")!))
        if case .binary(4, let data)? = d["u"] { #expect(data.count == 16) } else { Issue.record("uuid") }
        #expect(d["s"] == .string("it's") && d["arr"] == .array([.int32(1), .string("a")]))
        // Shell rendering parses back to the same value.
        do {
            #expect(try MongoShellParser.parseValue(v.shellString) == v)
        } catch {
            Issue.record("\(error) in \(v.shellString)")
        }
    }

    @Test func errors() {
        #expect(throws: DatabaseError.self) { try MongoShellParser.parse("select 1") }
        #expect(throws: DatabaseError.self) { try MongoShellParser.parse("db.x.find({a: })") }
        #expect(throws: DatabaseError.self) { try MongoShellParser.parse("db.x.find(ObjectId('zz'))") }
    }

    @Test func splitting() {
        let text = """
            // comment
            use shop
            db.a.find({
              x: 'semi;colon'
            })
            db.b.insertOne({ y: 1 }); db.c.drop()

            show collections
            """
        #expect(SQLSplitter.split(text, dialect: .mongodb).map(\.text) == [
            "use shop", "db.a.find({\n  x: 'semi;colon'\n})", "db.b.insertOne({ y: 1 })", "db.c.drop()", "show collections",
        ])
    }

    @Test func classifier() {
        #expect(SQLClassifier.isReadOnly("db.a.find({})", dialect: .mongodb))
        #expect(SQLClassifier.isReadOnly("db.a.aggregate([{ $match: {} }])", dialect: .mongodb))
        #expect(!SQLClassifier.isReadOnly("db.a.aggregate([{ $out: 'b' }])", dialect: .mongodb))
        #expect(!SQLClassifier.isReadOnly("db.a.deleteMany({})", dialect: .mongodb))
        #expect(!SQLClassifier.isReadOnly("db.dropDatabase()", dialect: .mongodb))
    }
}

@Suite(.enabled(if: MongoEnv.current != nil), .serialized)
struct MongoShellLiveTests {
    let env = MongoEnv.current!

    @Test func crudThroughShell() async throws {
        let c = try await MongoConnection.connect(host: env.host, port: env.port, user: env.user, password: env.password, database: "dbide_shell")
        _ = try await c.execute("db.dropDatabase()")
        var r = try await c.execute("db.people.insertMany([{ name: 'Ann', age: 31, tags: ['a'] }, { name: 'Bob', age: 25 }, { name: 'Cy', age: 40, addr: { city: 'X' } }])")
        #expect(r.affectedRows == 3)
        r = try await c.execute("db.people.find({ age: { $gte: 30 } }).sort({ age: -1 })")
        #expect(r.columns.map(\.name) == ["_id", "name", "age", "addr", "tags"])
        #expect(r.rows.map { $0[1] } == [.text("Cy"), .text("Ann")])
        #expect(r.rows[0][3] == .text("{ city: 'X' }") && r.rows[1][3] == .null)
        #expect(r.documents?.count == 2)
        r = try await c.execute("db.people.updateMany({ age: { $lt: 35 } }, { $inc: { age: 1 } })")
        #expect(r.affectedRows == 2 && r.message == "matched 2, modified 2")
        r = try await c.execute("db.people.countDocuments({ age: 26 })")
        #expect(r.rows == [[.integer(1)]])
        r = try await c.execute("db.people.aggregate([{ $group: { _id: null, avg: { $avg: '$age' } } }])")
        if case .real(let avg)? = r.rows.first?[1] { #expect(abs(avg - 98.0 / 3) < 1e-9) } else { Issue.record("avg") }
        r = try await c.execute("db.people.find().limit(2)", maxRows: 500)
        #expect(r.rows.count == 2 && !r.truncated)
        r = try await c.execute("db.people.find()", maxRows: 2)
        #expect(r.rows.count == 2 && r.truncated)
        _ = try await c.execute("db.people.createIndex({ name: 1 }, { unique: true })")
        await #expect(throws: DatabaseError.self) { _ = try await c.execute("db.people.insertOne({ name: 'Ann' })") }
        r = try await c.execute("db.people.deleteOne({ name: 'Bob' })")
        #expect(r.affectedRows == 1)
        r = try await c.execute("show collections")
        #expect(r.rows.map { $0[0] } == [.text("people")])
        _ = try await c.execute("use other_db")
        #expect(c.database == "other_db")

        // Introspection
        let intro = Introspector(c)
        #expect(try await intro.schemas().contains("dbide_shell"))
        let tables = try await intro.tables(schema: "dbide_shell")
        #expect(tables.map(\.name) == ["people"])
        let fields = try await intro.columns(schema: "dbide_shell", table: "people")
        #expect(fields.first?.name == "_id" && fields.first?.isPrimaryKey == true)
        #expect(fields.first { $0.name == "addr" }?.nullable == true)
        #expect(try await intro.indexes(schema: "dbide_shell", table: "people").map(\.name) == ["_id_", "name_1"])
        let ddl = try await intro.ddl(for: tables[0])
        #expect(ddl.contains("createIndex({ name: 1 }, { name: 'name_1', unique: true })"), "\(ddl)")

        // Explain
        c.database = "dbide_shell"
        let plan = try await Explainer.explain("db.people.find({ name: 'Ann' })", analyze: true, on: c)
        #expect(plan.root.allNodes.contains { $0.title.contains("name_1") })

        // Table editing through TableEdits (updateOne by _id keeps types)
        let page = try await c.execute(intro.selectSQL(tables[0], filter: "{ name: 'Ann' }", orderBy: "", limit: 10, offset: 0))
        var edits = TableEdits()
        let ageCol = page.columns.firstIndex { $0.name == "age" }!
        edits.set(.integer(50), row: 0, column: ageCol, original: page.rows[0][ageCol])
        let stmts = try edits.statements(table: tables[0], dialect: .mongodb, columns: page.columns, rows: page.rows, primaryKey: ["_id"], documents: page.documents)
        try await TableEdits.apply(stmts, on: c)
        let after = try await c.execute("db.people.findOne({ name: 'Ann' })")
        #expect(after.documents?.first?["age"] == .int32(50))

        _ = try await c.execute("db.dropDatabase()")
        await c.close()
    }

    @Test func cancelLongOperation() async throws {
        let c = try await MongoConnection.connect(host: env.host, port: env.port, user: env.user, password: env.password, database: "dbide_cancel")
        _ = try await c.execute("db.t.insertOne({ x: 1 })")
        let task = Task { try await c.execute("db.t.find({ $where: 'sleep(30000) || true' })") }
        try await Task.sleep(for: .milliseconds(700))
        c.cancel()
        let start = Date()
        await #expect(throws: DatabaseError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 8)
        _ = try await c.execute("db.dropDatabase()")
        await c.close()
    }
}
