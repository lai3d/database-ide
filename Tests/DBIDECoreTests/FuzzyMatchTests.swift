import Testing

@testable import DBIDECore

@Suite struct FuzzyMatchTests {
    @Test func matching() {
        #expect(FuzzyMatch.score("ordit", "order_items") != nil)
        #expect(FuzzyMatch.score("xyz", "order_items") == nil)
        #expect(FuzzyMatch.score("", "anything") == 0)
    }

    @Test func ranking() {
        func best(_ q: String, _ names: [String]) -> String? {
            names.compactMap { n in FuzzyMatch.score(q, n).map { (n, $0) } }.max { $0.1 < $1.1 }?.0
        }
        #expect(best("oi", ["product_options_index", "order_items", "audit_log"]) == "order_items")
        #expect(best("users", ["user_settings", "users", "users_archive"]) == "users")
        #expect(best("pr", ["product_reviews", "price_rules_proper", "products"]) == "products")
        #expect(best("uv", ["UserView", "audit_values"]) == "UserView")
    }

    @Test func nameOrQualifiedName() {
        #expect(FuzzyMatch.score("or", name: "orders", qualifiedName: "main.orders") != nil)
        #expect(FuzzyMatch.score("pub.ord", name: "orders", qualifiedName: "public.orders") != nil)  // only qualified matches
        #expect(FuzzyMatch.score("zz", name: "orders", qualifiedName: "public.orders") == nil)
    }
}
