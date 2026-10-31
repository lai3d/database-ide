import AppKit
import DBIDECore
import Foundation
import Observation

struct LogEntry: Identifiable {
    enum Kind { case statement, info, error }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
}

/// One result set shown in the console's result area.
struct ResultTab: Identifiable {
    let id = UUID()
    var title: String
    var result: QueryResult
}

/// Where in the editor the user asked to run.
enum RunScope { case caretOrSelection, all }

// MARK: - Console

@MainActor @Observable
final class ConsoleModel: Identifiable {
    let id: UUID
    var title: String
    let dataSourceID: UUID
    var text: String
    /// Current editor selection (UTF-16), kept in sync by the editor.
    var selection = NSRange(location: 0, length: 0)
    var currentSchema: String?
    var schemas: [String] = []

    private(set) var connection: (any DatabaseConnection)?
    private(set) var isRunning = false
    private(set) var isConnecting = false
    var results: [ResultTab] = []
    var selectedResultID: UUID?
    var log: [LogEntry] = []
    /// Range to flash in the editor after an error (UTF-16, in the editor's text).
    var errorRange: NSRange?
    /// Range of the statement currently executing, highlighted in the editor.
    var executingRange: NSRange?
    var maxRows = 500
    /// Manual mode opens a transaction before the first statement; Commit / Rollback end it.
    var autoCommit = true
    /// Mirrors the server's view after each statement (also catches a typed BEGIN).
    private(set) var inTransaction = false
    /// Bumped when completion metadata finished loading.
    var catalogVersion = 0
    @ObservationIgnored var loadingCatalog: Set<String> = []

    weak var app: AppModel?

    init(id: UUID = UUID(), title: String, dataSourceID: UUID, text: String = "", schema: String? = nil) {
        self.id = id
        self.title = title
        self.dataSourceID = dataSourceID
        self.text = text
        currentSchema = schema
    }

    var dataSource: DataSourceSession? { app?.session(for: dataSourceID) }
    var dialect: SQLDialect { dataSource?.config.dialect ?? .postgres }

    private func ensureConnection() async throws -> any DatabaseConnection {
        if let connection { return connection }
        guard let ds = dataSource else { throw DatabaseError("Data source was removed") }
        isConnecting = true
        defer { isConnecting = false }
        let conn = try await ds.config.connect(password: Keychain.password(for: ds.config.id) ?? "")
        connection = conn
        let tls = conn.securityDescription.map { ", 🔒 \($0)" } ?? ""
        log.append(LogEntry(kind: .info, text: "Connected to \(ds.config.displayName) (\(conn.serverVersion)\(tls))"))
        let intro = Introspector(conn)
        schemas = (try? await intro.schemas()) ?? []
        if let wanted = currentSchema, schemas.contains(wanted) {
            try? await applySchema(wanted, on: conn)
        } else {
            currentSchema = try? await intro.currentSchema()
        }
        return conn
    }

    /// Connect eagerly (used when a console opens) so the schema picker fills in.
    func prepare() async {
        do { _ = try await ensureConnection() } catch {
            log.append(LogEntry(kind: .error, text: error.localizedDescription))
        }
    }

    private func applySchema(_ schema: String, on conn: any DatabaseConnection) async throws {
        switch conn.dialect {
        case .postgres: _ = try await conn.execute("SET search_path TO \(conn.dialect.quote(schema))")
        case .mysql: _ = try await conn.execute("USE \(conn.dialect.quote(schema))")
        case .sqlite: break
        }
    }

    func switchSchema(_ schema: String) async {
        currentSchema = schema
        guard let connection else { return }
        do {
            try await applySchema(schema, on: connection)
            log.append(LogEntry(kind: .info, text: "Switched to schema \(schema)"))
        } catch {
            log.append(LogEntry(kind: .error, text: error.localizedDescription))
        }
    }

    /// Statements to run for the current caret / selection.
    func statementsToRun(_ scope: RunScope) -> [SQLStatement] {
        let ns = text as NSString
        switch scope {
        case .all:
            return SQLSplitter.split(text, dialect: dialect)
        case .caretOrSelection:
            if selection.length > 0, NSMaxRange(selection) <= ns.length {
                let sub = ns.substring(with: selection)
                return SQLSplitter.split(sub, dialect: dialect).map {
                    SQLStatement(text: $0.text, range: NSRange(location: $0.range.location + selection.location, length: $0.range.length))
                }
            }
            return SQLSplitter.statement(at: min(selection.location, ns.length), in: text, dialect: dialect).map { [$0] } ?? []
        }
    }

    func run(_ scope: RunScope) {
        guard !isRunning else { return }
        let statements = statementsToRun(scope)
        guard !statements.isEmpty else {
            log.append(LogEntry(kind: .info, text: "Nothing to execute at the caret"))
            selectedResultID = nil
            return
        }
        Task { await execute(statements) }
    }

    func execute(_ statements: [SQLStatement]) async {
        isRunning = true
        errorRange = nil
        defer {
            isRunning = false
            executingRange = nil
        }
        let conn: any DatabaseConnection
        do {
            conn = try await ensureConnection()
        } catch {
            log.append(LogEntry(kind: .error, text: error.localizedDescription))
            return
        }
        var newResults: [ResultTab] = []
        for st in statements {
            executingRange = st.range
            if !autoCommit, !conn.inTransaction, !isTransactionControl(st.text) {
                do {
                    _ = try await conn.execute(dialect == .mysql ? "START TRANSACTION" : "BEGIN")
                    log.append(LogEntry(kind: .info, text: "Transaction started (manual commit mode)"))
                } catch {
                    log.append(LogEntry(kind: .error, text: error.localizedDescription))
                    break
                }
            }
            defer { inTransaction = conn.inTransaction }
            log.append(LogEntry(kind: .statement, text: st.text))
            app?.history.record(st.text, dataSource: dataSourceID)
            do {
                let res = try await conn.execute(st.text, maxRows: maxRows)
                log.append(LogEntry(kind: .info, text: res.summary))
                if res.hasResultSet {
                    newResults.append(ResultTab(title: resultTitle(st.text, index: newResults.count), result: res))
                }
                if dialect == .mysql, let schema = useTarget(st.text) { currentSchema = schema }
            } catch {
                log.append(LogEntry(kind: .error, text: error.localizedDescription))
                if let e = error as? DatabaseError, let pos = e.position {
                    errorRange = NSRange(location: st.range.location + min(pos, st.range.length), length: 1)
                } else {
                    errorRange = st.range
                }
                break
            }
        }
        if !newResults.isEmpty {
            results = newResults
            selectedResultID = newResults.first?.id
        } else if selectedResultID == nil || results.isEmpty {
            selectedResultID = nil
        }
        if statements.contains(where: { isDDL($0.text) }) { await dataSource?.refreshAfterDDL() }
    }

    private func isTransactionControl(_ sql: String) -> Bool {
        let kw = SQLLexer.leadingKeywords(sql, count: 1).uppercased()
        return ["BEGIN", "START", "COMMIT", "ROLLBACK", "END", "SAVEPOINT", "RELEASE", "SET", "SHOW", "USE"].contains(kw)
    }

    /// COMMIT or ROLLBACK the open transaction.
    func endTransaction(commit: Bool) async {
        guard let conn = connection, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let sql = commit ? "COMMIT" : "ROLLBACK"
        log.append(LogEntry(kind: .statement, text: sql))
        do {
            _ = try await conn.execute(sql)
            log.append(LogEntry(kind: .info, text: commit ? "Committed" : "Rolled back"))
        } catch {
            log.append(LogEntry(kind: .error, text: error.localizedDescription))
        }
        inTransaction = conn.inTransaction
    }

    /// Reformats the selection, or the whole console when nothing is selected.
    func reformat() {
        let ns = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= ns.length {
            let formatted = SQLFormatter.format(ns.substring(with: selection), dialect: dialect)
            text = ns.replacingCharacters(in: selection, with: formatted)
            selection = NSRange(location: selection.location, length: (formatted as NSString).length)
        } else {
            text = SQLFormatter.format(text, dialect: dialect)
        }
    }

    private func resultTitle(_ sql: String, index: Int) -> String {
        let tokens = SQLLexer.tokenize(sql, dialect: dialect)
        let ns = sql as NSString
        // Use the first table after FROM as a title, like DataGrip.
        if let fromIndex = tokens.firstIndex(where: { ns.substring(with: $0.range).uppercased() == "FROM" }),
            fromIndex + 1 < tokens.count
        {
            let t = tokens[fromIndex + 1]
            if t.kind == .identifier || t.kind == .quotedIdentifier {
                return ns.substring(with: t.range).trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
            }
        }
        return "Result \(index + 1)"
    }

    private func useTarget(_ sql: String) -> String? {
        let parts = sql.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0].uppercased() == "USE" else { return nil }
        return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "`;"))
    }

    private func isDDL(_ sql: String) -> Bool {
        let kw = SQLLexer.leadingKeywords(sql, count: 1).uppercased()
        return ["CREATE", "DROP", "ALTER", "RENAME", "COMMENT"].contains(kw)
    }

    func cancel() {
        guard isRunning else { return }
        connection?.cancel()
        log.append(LogEntry(kind: .info, text: "Cancel requested"))
    }

    func disconnect() async {
        let c = connection
        connection = nil
        await c?.close()
    }
}

extension DataSourceSession {
    /// After DDL in a console, reload already-expanded schemas so the tree reflects it.
    func refreshAfterDDL() async {
        for node in schemas where node.tables != nil { await loadSchema(node, force: true) }
    }
}

// MARK: - Table data

@MainActor @Observable
final class TableDataModel: Identifiable {
    let id = UUID()
    let dataSourceID: UUID
    let table: TableInfo
    var filter = ""
    var orderBy = ""
    var pageSize = 500
    private(set) var offset = 0
    private(set) var result: QueryResult?
    private(set) var error: String?
    private(set) var isRunning = false
    private(set) var lastSQL = ""
    private(set) var totalCount: Int?
    private(set) var primaryKey: [String] = []
    private var connection: (any DatabaseConnection)?

    /// Pending edits (DataGrip-style: edit, then Submit).
    var pending = TableEdits()

    weak var app: AppModel?

    init(dataSourceID: UUID, table: TableInfo) {
        self.dataSourceID = dataSourceID
        self.table = table
    }

    var title: String { table.name }
    var dialect: SQLDialect { app?.session(for: dataSourceID)?.config.dialect ?? .postgres }
    var isEditable: Bool { !primaryKey.isEmpty && table.kind == .table }
    var hasPendingChanges: Bool { !pending.isEmpty }

    private func ensureConnection() async throws -> any DatabaseConnection {
        if let connection { return connection }
        guard let ds = app?.session(for: dataSourceID) else { throw DatabaseError("Data source was removed") }
        let conn = try await ds.config.connect(password: Keychain.password(for: ds.config.id) ?? "")
        connection = conn
        let cols = try await Introspector(conn).columns(schema: table.schema, table: table.name)
        primaryKey = cols.filter(\.isPrimaryKey).map(\.name)
        return conn
    }

    func reload(resetPage: Bool = false) async {
        if resetPage { offset = 0 }
        isRunning = true
        defer { isRunning = false }
        do {
            let conn = try await ensureConnection()
            let sql = Introspector(conn).selectSQL(table, filter: filter, orderBy: orderBy, limit: pageSize, offset: offset)
            lastSQL = sql
            result = try await conn.execute(sql)
            error = nil
            discardChanges()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func countRows() async {
        guard let conn = try? await ensureConnection() else { return }
        var sql = "SELECT COUNT(*) FROM \(dialect.qualified(schema: table.schema, name: table.name))"
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { sql += " WHERE \(f)" }
        totalCount = (try? await conn.strings(sql).first).flatMap { $0.flatMap { Int($0) } }
    }

    var canGoBack: Bool { offset > 0 }
    var canGoForward: Bool { (result?.rows.count ?? 0) >= pageSize }

    func nextPage() async {
        offset += pageSize
        await reload()
    }

    func previousPage() async {
        offset = max(0, offset - pageSize)
        await reload()
    }

    func cancel() { connection?.cancel() }

    // MARK: Editing

    /// Value displayed for a cell, including pending edits. Rows past the result are inserted rows.
    func value(row: Int, column: Int) -> SQLValue {
        guard let result else { return .null }
        if row >= result.rows.count { return pending.insertedRows[row - result.rows.count][column] }
        return pending.updates[row]?[column] ?? result.rows[row][column]
    }

    func setValue(_ value: SQLValue, row: Int, column: Int) {
        guard let result else { return }
        if row >= result.rows.count {
            pending.insertedRows[row - result.rows.count][column] = value
        } else {
            pending.set(value, row: row, column: column, original: result.rows[row][column])
        }
    }

    func addRow() {
        guard let result else { return }
        pending.insertedRows.append(Array(repeating: .null, count: result.columns.count))
    }

    func deleteRows(_ rows: IndexSet) {
        guard let result else { return }
        for r in rows.sorted(by: >) {
            if r >= result.rows.count {
                pending.insertedRows.remove(at: r - result.rows.count)
            } else {
                pending.deletedRows.insert(r)
            }
        }
    }

    func discardChanges() { pending = TableEdits() }

    /// SQL for the pending changes, in execution order.
    func pendingStatements() -> [String] {
        guard let result else { return [] }
        do {
            return try pending.statements(
                table: table, dialect: dialect, columns: result.columns, rows: result.rows, primaryKey: primaryKey)
        } catch {
            return ["-- " + error.localizedDescription]
        }
    }

    /// Applies pending changes in one transaction, then reloads.
    func submit() async {
        guard let result, !pending.isEmpty else { return }
        isRunning = true
        do {
            let statements = try pending.statements(
                table: table, dialect: dialect, columns: result.columns, rows: result.rows, primaryKey: primaryKey)
            let conn = try await ensureConnection()
            try await TableEdits.apply(statements, on: conn)
            for sql in statements { app?.history.record(sql, dataSource: dataSourceID) }
            error = nil
            isRunning = false
            await reload()
        } catch {
            isRunning = false
            self.error = error.localizedDescription
        }
    }

    func close() async {
        let c = connection
        connection = nil
        await c?.close()
    }
}

// MARK: - DDL

@MainActor @Observable
final class DDLModel: Identifiable {
    let id = UUID()
    let dataSourceID: UUID
    let table: TableInfo
    var text = "-- loading…"
    init(dataSourceID: UUID, table: TableInfo) {
        self.dataSourceID = dataSourceID
        self.table = table
    }
    var title: String { table.name + " DDL" }
}

// MARK: - Tab

enum EditorTab: Identifiable {
    case console(ConsoleModel)
    case table(TableDataModel)
    case ddl(DDLModel)

    var id: UUID {
        switch self {
        case .console(let m): m.id
        case .table(let m): m.id
        case .ddl(let m): m.id
        }
    }

    @MainActor var title: String {
        switch self {
        case .console(let m): m.title
        case .table(let m): m.title
        case .ddl(let m): m.title
        }
    }

    var icon: String {
        switch self {
        case .console: "terminal"
        case .table: "tablecells"
        case .ddl: "doc.text"
        }
    }

    var dataSourceID: UUID {
        switch self {
        case .console(let m): m.dataSourceID
        case .table(let m): m.dataSourceID
        case .ddl(let m): m.dataSourceID
        }
    }
}
