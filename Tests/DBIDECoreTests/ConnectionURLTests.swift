import Testing

@testable import DBIDECore

@Suite struct ConnectionURLTests {
    @Test func postgresURL() throws {
        let p = try #require(ConnectionURL.parse("postgresql://alice:s3cr%40t@db.example.com:6543/shop?sslmode=verify-full&sslrootcert=/tmp/ca.pem"))
        #expect(p.config.dialect == .postgres)
        #expect(p.config.host == "db.example.com" && p.config.port == 6543)
        #expect(p.config.user == "alice" && p.password == "s3cr@t")
        #expect(p.config.database == "shop")
        #expect(p.config.sslMode == .verifyFull && p.config.sslRootCert == "/tmp/ca.pem")
    }

    @Test func unescapedPasswordAndDefaults() throws {
        let p = try #require(ConnectionURL.parse("  postgres://bob:p@ss:w/rd@localhost  "))
        #expect(p.config.user == "bob" && p.password == "p@ss:w/rd")
        #expect(p.config.port == 5432 && p.config.database == "")
    }

    @Test func jdbcMySQL() throws {
        let p = try #require(ConnectionURL.parse("jdbc:mysql://10.0.0.5/app?user=root&password=x%26y&useSSL=true"))
        #expect(p.config.dialect == .mysql && p.config.host == "10.0.0.5" && p.config.port == 3306)
        #expect(p.config.user == "root" && p.password == "x&y" && p.config.database == "app")
        #expect(p.config.sslMode == .require)
    }

    @Test func ipv6AndMultiHost() throws {
        let v6 = try #require(ConnectionURL.parse("postgres://u@[::1]:5433/d"))
        #expect(v6.config.host == "::1" && v6.config.port == 5433)
        let multi = try #require(ConnectionURL.parse("postgresql://u@h1:5432,h2:5432/d"))
        #expect(multi.config.host == "h1")
    }

    @Test func sqlitePaths() throws {
        #expect(ConnectionURL.parse("sqlite:///Users/me/app.db")?.config.filePath == "/Users/me/app.db")
        #expect(ConnectionURL.parse("~/data/x.sqlite3")?.config.dialect == .sqlite)
        #expect(ConnectionURL.parse("/etc/hosts") == nil)
        #expect(ConnectionURL.parse("redis://x") == nil)
        #expect(ConnectionURL.parse("hello") == nil)
    }
}
