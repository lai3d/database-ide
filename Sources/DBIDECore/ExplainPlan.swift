import Foundation

/// One operator of a query plan, normalized across dialects.
public struct PlanNode: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var title: String
    public var details: [String] = []
    public var totalCost: Double?
    public var planRows: Double?
    /// Milliseconds per loop (EXPLAIN ANALYZE).
    public var actualTime: Double?
    public var actualRows: Double?
    public var loops: Double?
    public var children: [PlanNode] = []

    public init(title: String, details: [String] = [], totalCost: Double? = nil, planRows: Double? = nil,
                actualTime: Double? = nil, actualRows: Double? = nil, loops: Double? = nil, children: [PlanNode] = []) {
        self.title = title
        self.details = details
        self.totalCost = totalCost
        self.planRows = planRows
        self.actualTime = actualTime
        self.actualRows = actualRows
        self.loops = loops
        self.children = children
    }

    /// Children as optional for SwiftUI `OutlineGroup`.
    public var childNodes: [PlanNode]? { children.isEmpty ? nil : children }

    /// Total time spent in this node across loops (ms).
    public var inclusiveTime: Double? { actualTime.map { $0 * (loops ?? 1) } }

    /// Time spent in this node minus its children (ms).
    public var exclusiveTime: Double? {
        guard let t = inclusiveTime else { return nil }
        return max(0, t - children.compactMap(\.inclusiveTime).reduce(0, +))
    }

    public var allNodes: [PlanNode] { [self] + children.flatMap(\.allNodes) }
}

public struct ExplainResult: Sendable {
    public var root: PlanNode
    public var analyzed: Bool
    public var planningTime: Double?
    public var executionTime: Double?
    /// Raw plan text / JSON as returned by the server.
    public var raw: String
}

public enum Explainer {
    /// Explains `sql`. With `analyze` the statement really runs; anything other than a
    /// plain query runs inside a transaction that is rolled back.
    public static func explain(_ sql: String, analyze: Bool, on c: any DatabaseConnection) async throws -> ExplainResult {
        let sql = sql.trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
        let readOnly = ["SELECT", "WITH", "VALUES", "TABLE"].contains(SQLLexer.leadingKeywords(sql, count: 1).uppercased())
        let wrap = analyze && !readOnly && c.dialect.supportsTransactions && c.dialect != .sqlite && !c.inTransaction
        if wrap { _ = try await c.execute(c.dialect.beginTransaction) }
        do {
            let result: ExplainResult
            switch c.dialect {
            case .mongodb:
                result = try await explainMongo(sql, analyze: analyze, on: c)
            case .redis:
                throw DatabaseError("Redis has no query plans")
            case .clickhouse:
                let text = try await c.strings("EXPLAIN indexes = 1 " + sql).joined(separator: "\n")
                result = parseIndentedTree(text, unit: 2)
            case .sqlserver:
                result = try await explainSQLServer(sql, analyze: analyze, on: c)
            case .postgres:
                let opts = analyze ? "FORMAT JSON, ANALYZE, BUFFERS" : "FORMAT JSON"
                let json = try await c.strings("EXPLAIN (\(opts)) \(sql)").joined()
                result = try parsePostgres(json, analyzed: analyze)
            case .mysql:
                let text = try await c.strings((analyze ? "EXPLAIN ANALYZE " : "EXPLAIN FORMAT=TREE ") + sql).joined(separator: "\n")
                result = parseMySQLTree(text, analyzed: analyze)
            case .sqlite:
                let rows = try await c.execute("EXPLAIN QUERY PLAN " + sql).rows
                result = parseSQLite(rows.map { (Int($0[0].displayString) ?? 0, Int($0[1].displayString) ?? 0, $0[3].displayString) })
            }
            if wrap { _ = try await c.execute("ROLLBACK") }
            return result
        } catch {
            if wrap { _ = try? await c.execute("ROLLBACK") }
            throw error
        }
    }

    // MARK: PostgreSQL JSON

    static func parsePostgres(_ json: String, analyzed: Bool) throws -> ExplainResult {
        guard let data = json.data(using: .utf8),
            let top = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
            let first = top.first, let plan = first["Plan"] as? [String: Any]
        else { throw DatabaseError("Unexpected EXPLAIN output") }
        return ExplainResult(
            root: postgresNode(plan), analyzed: analyzed,
            planningTime: first["Planning Time"] as? Double, executionTime: first["Execution Time"] as? Double,
            raw: json)
    }

    private static func postgresNode(_ p: [String: Any]) -> PlanNode {
        func s(_ k: String) -> String? { p[k] as? String }
        func d(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
        var title = s("Node Type") ?? "?"
        if let join = s("Join Type"), title.contains("Join") || title == "Nested Loop" { title = "\(join) \(title)" }
        if let strategy = s("Strategy"), title == "Aggregate" { title = "\(strategy) \(title)" }
        if let rel = s("Relation Name") {
            title += " on \(rel)"
            if let alias = s("Alias"), alias != rel { title += " \(alias)" }
        } else if let cte = s("CTE Name") {
            title += " on \(cte)"
        } else if let fn = s("Function Name") {
            title += " on \(fn)()"
        }
        if let idx = s("Index Name") { title += " using \(idx)" }
        var details: [String] = []
        for key in ["Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter", "Sort Key", "Group Key", "Output"] {
            if let v = p[key] as? String { details.append("\(key): \(v)") }
            if let v = p[key] as? [String] { details.append("\(key): \(v.joined(separator: ", "))") }
        }
        if let removed = d("Rows Removed by Filter"), removed > 0 { details.append("Rows Removed by Filter: \(Int(removed))") }
        if let hit = d("Shared Hit Blocks"), let read = d("Shared Read Blocks"), hit + read > 0 {
            details.append("Buffers: shared hit=\(Int(hit)) read=\(Int(read))")
        }
        let children = (p["Plans"] as? [[String: Any]] ?? []).map(postgresNode)
        return PlanNode(
            title: title, details: details, totalCost: d("Total Cost"), planRows: d("Plan Rows"),
            actualTime: d("Actual Total Time"), actualRows: d("Actual Rows"), loops: d("Actual Loops"), children: children)
    }

    // MARK: MySQL TREE

    static func parseMySQLTree(_ text: String, analyzed: Bool) -> ExplainResult {
        var stack: [(indent: Int, node: PlanNode)] = []
        var roots: [PlanNode] = []

        func attach(_ node: PlanNode) {
            if stack.isEmpty {
                roots.append(node)
            } else {
                stack[stack.count - 1].node.children.append(node)
            }
        }
        func popTo(_ indent: Int) {
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
                attach(last.node)
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let arrow = line.range(of: "-> ") else {
                // Continuation lines belong to the current node.
                if !stack.isEmpty { stack[stack.count - 1].node.details.append(line.trimmingCharacters(in: .whitespaces)) }
                continue
            }
            let indent = line.distance(from: line.startIndex, to: arrow.lowerBound)
            let body = String(line[arrow.upperBound...])
            popTo(indent)
            stack.append((indent, mysqlNode(body)))
        }
        popTo(0)
        let root = roots.count == 1 ? roots[0] : PlanNode(title: "Plan", children: roots)
        return ExplainResult(
            root: root, analyzed: analyzed, planningTime: nil,
            executionTime: analyzed ? root.inclusiveTime : nil, raw: text)
    }

    private static func mysqlNode(_ body: String) -> PlanNode {
        var title = body
        if let r = body.range(of: "  (") ?? body.range(of: " (cost=") ?? body.range(of: " (actual") {
            title = String(body[..<r.lowerBound])
        }
        func number(_ pattern: String) -> Double? {
            guard let r = body.range(of: pattern, options: .regularExpression) else { return nil }
            let m = String(body[r])
            return Double(m.split(separator: "=").last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " )")) } ?? "")
        }
        var node = PlanNode(title: title, totalCost: number(#"cost=[0-9.e+]+"#), planRows: number(#"\(cost=[0-9.e+]+ rows=[0-9.e+]+"#))
        if let r = body.range(of: #"actual time=[0-9.]+\.\.[0-9.]+ rows=[0-9.e+]+ loops=[0-9]+"#, options: .regularExpression) {
            let parts = body[r].split(separator: " ")
            node.actualTime = parts[1].split(separator: "=").last.flatMap { $0.components(separatedBy: "..").last }.flatMap(Double.init)
            node.actualRows = parts[2].split(separator: "=").last.flatMap { Double($0) }
            node.loops = parts[3].split(separator: "=").last.flatMap { Double($0) }
        }
        return node
    }

    // MARK: ClickHouse

    /// Plans printed as indented lines (two spaces per level); deeper lines that are not
    /// operators (e.g. "Indexes:", "Keys:") become details of the node above.
    static func parseIndentedTree(_ text: String, unit: Int) -> ExplainResult {
        struct Frame { var depth: Int; var node: PlanNode }
        var stack: [Frame] = []
        var roots: [PlanNode] = []
        func attach(_ n: PlanNode) {
            if stack.isEmpty { roots.append(n) } else { stack[stack.count - 1].node.children.append(n) }
        }
        func pop(to depth: Int) {
            while let last = stack.last, last.depth >= depth {
                stack.removeLast()
                attach(last.node)
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            let depth = indent / max(unit, 1)
            // Operator lines start with a capitalized step name and are not "Key: value" details.
            let isOperator = body.first?.isUppercase == true && !body.contains(": ") && !body.hasSuffix(":")
            if isOperator || stack.isEmpty {
                pop(to: depth)
                stack.append(Frame(depth: depth, node: PlanNode(title: body)))
            } else {
                stack[stack.count - 1].node.details.append(body)
            }
        }
        pop(to: 0)
        let root = roots.count == 1 ? roots[0] : PlanNode(title: "Plan", children: roots)
        return ExplainResult(root: root, analyzed: false, planningTime: nil, executionTime: nil, raw: text)
    }

    // MARK: SQL Server

    static func explainSQLServer(_ sql: String, analyze: Bool, on c: any DatabaseConnection) async throws -> ExplainResult {
        let option = analyze ? "STATISTICS PROFILE" : "SHOWPLAN_ALL"
        _ = try await c.execute("SET \(option) ON")
        let r: QueryResult
        do {
            r = try await c.execute(sql)
            _ = try await c.execute("SET \(option) OFF")
        } catch {
            _ = try? await c.execute("SET \(option) OFF")
            throw error
        }
        return parseSQLServerPlan(r, analyzed: analyze)
    }

    static func parseSQLServerPlan(_ r: QueryResult, analyzed: Bool) -> ExplainResult {
        let names = r.columns.map { $0.name.lowercased() }
        func col(_ n: String) -> Int? { names.firstIndex(of: n.lowercased()) }
        func num(_ row: [SQLValue], _ n: String) -> Double? {
            guard let i = col(n), i < row.count else { return nil }
            switch row[i] {
            case .integer(let v): return Double(v)
            case .real(let v): return v
            case .text(let t): return Double(t)
            default: return nil
            }
        }
        func text(_ row: [SQLValue], _ n: String) -> String? {
            guard let i = col(n), i < row.count, !row[i].isNull else { return nil }
            return row[i].displayString
        }
        var nodes: [Int: PlanNode] = [:]
        var parents: [Int: Int] = [:]
        var order: [Int] = []
        for row in r.rows {
            guard let id = num(row, "NodeId").map(Int.init) else { continue }
            let op = text(row, "PhysicalOp") ?? text(row, "StmtText")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            var title = op
            if let logical = text(row, "LogicalOp"), logical != op { title += " (\(logical))" }
            var details: [String] = []
            if let arg = text(row, "Argument") { details.append(arg) }
            nodes[id] = PlanNode(
                title: title, details: details, totalCost: num(row, "TotalSubtreeCost"), planRows: num(row, "EstimateRows"),
                actualTime: nil, actualRows: num(row, "Rows").map { $0 / max(1, num(row, "Executes") ?? 1) },
                loops: num(row, "Executes"))
            parents[id] = num(row, "Parent").map(Int.init) ?? 0
            order.append(id)
        }
        func build(_ id: Int) -> PlanNode {
            var n = nodes[id]!
            n.children = order.filter { parents[$0] == id && $0 != id }.map(build)
            return n
        }
        let roots = order.filter { parents[$0] == 0 || nodes[parents[$0]!] == nil }.map(build)
        let root = roots.count == 1 ? roots[0] : PlanNode(title: "Plan", children: roots)
        let raw = r.rows.map { row in text(row, "StmtText") ?? "" }.joined(separator: "\n")
        return ExplainResult(root: root, analyzed: analyzed, planningTime: nil, executionTime: nil, raw: raw)
    }

    // MARK: MongoDB

    static func explainMongo(_ text: String, analyze: Bool, on c: any DatabaseConnection) async throws -> ExplainResult {
        guard case .collection(_, let method, _, let modifiers) = try MongoShellParser.parse(text),
            ["find", "findOne", "aggregate"].contains(method), !modifiers.contains(where: { $0.name == "explain" })
        else { throw DatabaseError("Explain works on find() and aggregate()") }
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
        let r = try await c.execute(body + ".explain('\(analyze ? "executionStats" : "queryPlanner")')")
        guard let doc = r.documents?.first else { throw DatabaseError("No explain output") }
        return parseMongoExplain(doc, analyzed: analyze)
    }

    static func parseMongoExplain(_ doc: BSONDocument, analyzed: Bool) -> ExplainResult {
        // find: queryPlanner / executionStats at the top; aggregate: inside stages[0].$cursor.
        var d = doc
        if let first = doc["stages"]?.array?.first?.document?["$cursor"]?.document { d = first }
        let planner = d["queryPlanner"]?.document ?? [:]
        var winning = planner["winningPlan"]?.document ?? [:]
        if let qp = winning["queryPlan"]?.document { winning = qp }  // slot-based engine
        let stats = d["executionStats"]?.document
        func node(_ s: BSONDocument, _ exec: BSONDocument?) -> PlanNode {
            var title = s["stage"]?.string ?? "?"
            if let idx = s["indexName"]?.string { title += " using \(idx)" }
            var details: [String] = []
            if let k = s["keyPattern"] { details.append("keys: \(k.shellString)") }
            if let f = s["filter"] { details.append("filter: \(f.shellString)") }
            if let b = s["indexBounds"] { details.append("bounds: \(b.shellString)") }
            if let e = exec {
                let examined = [e["keysExamined"].flatMap(\.int).map { "keys examined \($0)" }, e["docsExamined"].flatMap(\.int).map { "docs examined \($0)" }].compactMap { $0 }
                if !examined.isEmpty { details.append(examined.joined(separator: ", ")) }
            }
            let inputs = (s["inputStage"]?.document.map { [$0] } ?? []) + (s["inputStages"]?.array?.compactMap(\.document) ?? [])
            let execInputs = (exec?["inputStage"]?.document.map { [$0] } ?? []) + (exec?["inputStages"]?.array?.compactMap(\.document) ?? [])
            let children = inputs.enumerated().map { node($0.element, $0.offset < execInputs.count ? execInputs[$0.offset] : nil) }
            return PlanNode(
                title: title, details: details,
                actualTime: exec?["executionTimeMillisEstimate"].flatMap(\.int).map(Double.init),
                actualRows: exec?["nReturned"].flatMap(\.int).map(Double.init), loops: exec == nil ? nil : 1,
                children: children)
        }
        var root = node(winning, stats?["executionStages"]?.document)
        if let ns = planner["namespace"]?.string { root.details.insert("namespace: \(ns)", at: 0) }
        return ExplainResult(
            root: root, analyzed: analyzed && stats != nil, planningTime: nil,
            executionTime: stats?["executionTimeMillis"].flatMap(\.int).map(Double.init), raw: doc.prettyString)
    }

    // MARK: SQLite

    static func parseSQLite(_ rows: [(id: Int, parent: Int, detail: String)]) -> ExplainResult {
        func children(of parent: Int) -> [PlanNode] {
            rows.filter { $0.parent == parent }.map { PlanNode(title: $0.detail, children: children(of: $0.id)) }
        }
        let top = children(of: 0)
        let root = top.count == 1 ? top[0] : PlanNode(title: "QUERY PLAN", children: top)
        return ExplainResult(
            root: root, analyzed: false, planningTime: nil, executionTime: nil,
            raw: rows.map { "\($0.id)|\($0.parent)|\($0.detail)" }.joined(separator: "\n"))
    }
}
