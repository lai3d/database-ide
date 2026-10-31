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
