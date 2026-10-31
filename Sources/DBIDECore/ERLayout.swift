import Foundation

/// Layered layout for ER diagrams: referenced ("parent") tables to the left,
/// tables that reference them in later columns. Cycles and self-references are tolerated.
public enum ERLayout {
    /// Column index for each table.
    public static func layers(tables: [String], foreignKeys: [(from: String, to: String)]) -> [String: Int] {
        let known = Set(tables)
        var parents: [String: Set<String>] = [:]
        for fk in foreignKeys where fk.from != fk.to && known.contains(fk.from) && known.contains(fk.to) {
            parents[fk.from, default: []].insert(fk.to)
        }
        var layer: [String: Int] = [:]
        var visiting = Set<String>()
        func depth(_ t: String) -> Int {
            if let l = layer[t] { return l }
            if visiting.contains(t) { return 0 }  // cycle: break it here
            visiting.insert(t)
            let d = (parents[t] ?? []).map { depth($0) + 1 }.max() ?? 0
            visiting.remove(t)
            layer[t] = d
            return d
        }
        for t in tables { _ = depth(t) }
        return layer
    }

    /// Grid placement: columns from `layers`, rows sorted by name; returns (column, row) per table.
    public static func grid(tables: [String], foreignKeys: [(from: String, to: String)]) -> [String: (column: Int, row: Int)] {
        let layers = layers(tables: tables, foreignKeys: foreignKeys)
        var rows: [Int: Int] = [:]
        var out: [String: (Int, Int)] = [:]
        for t in tables.sorted(by: { (layers[$0] ?? 0, $0) < (layers[$1] ?? 0, $1) }) {
            let c = layers[t] ?? 0
            out[t] = (c, rows[c, default: 0])
            rows[c, default: 0] += 1
        }
        return out
    }
}
