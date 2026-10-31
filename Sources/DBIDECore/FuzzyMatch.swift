import Foundation

/// Subsequence fuzzy matching for "Go to" pickers: "ordit" matches "order_items".
/// Higher scores are better; nil means no match.
public enum FuzzyMatch {
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().unicodeScalars).filter { $0 != " " }
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.unicodeScalars)
        let lower = Array(candidate.lowercased().unicodeScalars)
        guard lower.count == c.count else { return candidate.lowercased().contains(query.lowercased()) ? 1 : nil }
        var score = 0
        var qi = 0
        var previousMatch = -2
        for (i, ch) in lower.enumerated() where qi < q.count && ch == q[qi] {
            var s = 1
            if i == previousMatch + 1 { s += 5 }  // consecutive
            if i == 0 { s += 8 }  // start of name
            else {
                let prev = c[i - 1]
                if prev == "_" || prev == "." || prev == " " || prev == "-" { s += 6 }  // word boundary
                else if CharacterSet.uppercaseLetters.contains(c[i]) && CharacterSet.lowercaseLetters.contains(prev) { s += 6 }  // camelCase
            }
            score += s
            previousMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        if lower.count == q.count { score += 20 }  // exact
        return score - c.count / 4  // shorter names first on ties
    }

    /// Best score of `name` or (slightly penalized) `qualifiedName`, e.g. "public.orders".
    public static func score(_ query: String, name: String, qualifiedName: String) -> Int? {
        [score(query, name), score(query, qualifiedName).map { $0 - 5 }].compactMap { $0 }.max()
    }
}
