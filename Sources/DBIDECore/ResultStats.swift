import Foundation

/// Aggregates shown for a selection of grid cells.
public struct ResultStats: Sendable, Equatable {
    public var count: Int
    public var nonNull: Int
    public var numeric: Int
    public var sum: Double?
    public var min: Double?
    public var max: Double?
    public var avg: Double? { numeric > 0 ? sum.map { $0 / Double(numeric) } : nil }

    public init(_ values: [SQLValue]) {
        count = values.count
        nonNull = values.filter { !$0.isNull }.count
        let nums: [Double] = values.compactMap {
            switch $0 {
            case .integer(let i): Double(i)
            case .real(let d): d
            case .text(let t): Double(t.trimmingCharacters(in: .whitespaces))  // decimal / numeric come as text
            default: nil
            }
        }
        numeric = nums.count
        sum = nums.isEmpty ? nil : nums.reduce(0, +)
        min = nums.min()
        max = nums.max()
    }

    public var summary: String {
        var parts = ["\(count) selected"]
        if nonNull < count { parts.append("\(count - nonNull) null") }
        if numeric > 0, let sum, let min, let max, let avg {
            func f(_ d: Double) -> String {
                if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
                var s = String(format: "%.4f", d)
                while s.hasSuffix("0") { s.removeLast() }
                return s
            }
            parts += ["sum \(f(sum))", "avg \(f(avg))", "min \(f(min))", "max \(f(max))"]
        }
        return parts.joined(separator: " · ")
    }
}
