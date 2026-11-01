import Foundation
import Testing
@testable import DBIDECore

@Suite struct ConnectionLinkTests {
    @Test func parsesConnectLinks() throws {
        let link = try #require(ConnectionLink.make(url: "mysql://app:p@ss&w=rd+1@127.0.0.1:3307/shop", name: "Shop (.env)"))
        #expect(link.absoluteString.hasPrefix("dbide://connect?url="))
        let request = try #require(ConnectionLink.parse(link))
        #expect(request.name == "Shop (.env)")
        #expect(request.parsed.config.name == "Shop (.env)")
        #expect(request.parsed.config.dialect == .mysql)
        #expect(request.parsed.config.host == "127.0.0.1" && request.parsed.config.port == 3307)
        #expect(request.parsed.config.user == "app" && request.parsed.config.database == "shop")
        #expect(request.parsed.password == "p@ss&w=rd+1")

        let sqliteLink = try #require(URL(string: "dbide://connect?url=sqlite%3A%2F%2F%2Ftmp%2Fapp.sqlite"))
        let sqlite = try #require(ConnectionLink.parse(sqliteLink))
        #expect(sqlite.parsed.config.dialect == .sqlite && sqlite.parsed.config.filePath == "/tmp/app.sqlite")
        #expect(sqlite.name == nil)
    }

    @Test func rejectsOtherLinks() {
        #expect(ConnectionLink.parse(URL(string: "dbide://open?url=mysql%3A%2F%2Fh%2Fd")!) == nil)
        #expect(ConnectionLink.parse(URL(string: "http://connect?url=mysql%3A%2F%2Fh%2Fd")!) == nil)
        #expect(ConnectionLink.parse(URL(string: "dbide://connect")!) == nil)
        #expect(ConnectionLink.parse(URL(string: "dbide://connect?url=nonsense")!) == nil)
    }

    @Test func matchesSavedDataSources() throws {
        let saved = [
            DataSourceConfig(name: "other", dialect: .postgres, host: "localhost", port: 5432, user: "u", database: "other"),
            DataSourceConfig(name: "app", dialect: .postgres, host: "localhost", port: 5432, user: "u", database: "app"),
            DataSourceConfig(name: "file", dialect: .sqlite, filePath: "/tmp/x/../app.sqlite"),
        ]
        func request(_ url: String) throws -> ConnectionLink.Request {
            let link = try #require(ConnectionLink.make(url: url))
            return try #require(ConnectionLink.parse(link))
        }
        #expect(ConnectionLink.match(try request("postgresql://u:secret@127.0.0.1:5432/app"), in: saved)?.name == "app")
        #expect(ConnectionLink.match(try request("postgresql://127.0.0.1/app"), in: saved)?.name == "app")
        #expect(ConnectionLink.match(try request("postgresql://u@127.0.0.1:5433/app"), in: saved) == nil)
        #expect(ConnectionLink.match(try request("postgresql://v@localhost/app"), in: saved) == nil)
        #expect(ConnectionLink.match(try request("mysql://u@localhost:5432/app"), in: saved) == nil)
        #expect(ConnectionLink.match(try request("sqlite:///tmp/app.sqlite"), in: saved)?.name == "file")
    }
}
