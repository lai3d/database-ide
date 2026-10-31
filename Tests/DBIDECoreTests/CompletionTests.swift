import Foundation
import Testing

@testable import DBIDECore

@Suite struct CompletionTests {
    let users = TableInfo(schema: "public", name: "users", kind: .table)
    let orders = TableInfo(schema: "public", name: "orders", kind: .table)
    let audit = TableInfo(schema: "ops", name: "audit_log", kind: .table)

    var catalog: CompletionCatalog {
        CompletionCatalog(
            schemas: ["public", "ops"], defaultSchema: "public",
            tables: ["public": [users, orders, TableInfo(schema: "public", name: "UserView", kind: .view)], "ops": [audit]],
            columns: [
                "public.users": [
                    ColumnInfo(name: "id", type: "int4", nullable: false, isPrimaryKey: true),
                    ColumnInfo(name: "email", type: "text", nullable: true, isPrimaryKey: false),
                ],
                "public.orders": [
                    ColumnInfo(name: "id", type: "int4", nullable: false, isPrimaryKey: true),
                    ColumnInfo(name: "user_id", type: "int4", nullable: false, isPrimaryKey: false),
                ],
            ])
    }

    /// `|` marks the caret.
    func complete(_ s: String, _ cat: CompletionCatalog? = nil, dialect: SQLDialect = .postgres) -> SQLCompletionResult {
        let caret = (s as NSString).range(of: "|").location
        let text = (s as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return SQLCompletion.complete(text: text, caret: caret, dialect: dialect, catalog: cat ?? catalog)
    }

    func labels(_ r: SQLCompletionResult) -> [String] { r.items.map(\.label) }

    @Test func tablesAfterFrom() {
        let r = complete("SELECT * FROM u|")
        #expect(labels(r).prefix(2) == ["users", "UserView"])
        #expect(r.replaceRange == NSRange(location: 14, length: 1))
        #expect(r.items[1].insertText == "\"UserView\"")  // mixed case needs quoting in PostgreSQL
    }

    @Test func columnsOfAliasAfterDot() {
        let r = complete("SELECT o.| FROM orders o JOIN users u ON u.id = o.user_id")
        #expect(labels(r) == ["id", "user_id"])
        #expect(r.items[1].detail == "int4 · orders")
    }

    @Test func columnsFirstInSelectList() {
        let r = complete("SELECT e| FROM users")
        #expect(labels(r).first == "email")
        #expect(labels(r).contains("end"))  // keywords still offered after catalog names, in the typed case
    }

    @Test func lowercaseKeywordsFollowTyping() {
        #expect(labels(complete("sel|")).first == "select")
        #expect(labels(complete("SEL|")).first == "SELECT")
    }

    @Test func schemaQualifiedTables() {
        let r = complete("SELECT * FROM ops.a|")
        #expect(labels(r) == ["audit_log"])
        let cols = complete("SELECT x.| FROM ops.audit_log x")
        #expect(cols.items.isEmpty && cols.missingTables == [audit])
    }

    @Test func reportsMissingCatalog() {
        var cat = catalog
        cat.tables["ops"] = nil
        let r = complete("SELECT * FROM ops.|", cat)
        #expect(r.items.isEmpty && r.missingSchemas == ["ops"])
    }

    @Test func nothingInsideStringsOrComments() {
        #expect(complete("SELECT 'us|'").items.isEmpty)
        #expect(complete("-- us|").items.isEmpty)
    }

    @Test func commaSeparatedFromList() {
        let refs = SQLCompletion.tableReferences(in: "SELECT * FROM users u, public.orders AS o WHERE 1", dialect: .postgres)
        #expect(refs["u"]?.table == "users")
        #expect(refs["o"]?.table == "orders" && refs["o"]?.schema == "public")
    }

    @Test func substringMatchesRankLast() {
        let r = complete("SELECT * FROM users WHERE ail|")
        #expect(labels(r) == ["email"])
    }

    @Test func quoting() {
        #expect(SQLCompletion.quoteIfNeeded("order_items", dialect: .postgres) == "order_items")
        #expect(SQLCompletion.quoteIfNeeded("Order", dialect: .postgres) == "\"Order\"")
        #expect(SQLCompletion.quoteIfNeeded("Order", dialect: .mysql) == "`Order`")  // reserved word
        #expect(SQLCompletion.quoteIfNeeded("CamelCase", dialect: .mysql) == "CamelCase")
        #expect(SQLCompletion.quoteIfNeeded("my col", dialect: .sqlite) == "\"my col\"")
    }
}
