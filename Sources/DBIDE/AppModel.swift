import AppKit
import DBIDECore
import Foundation
import Observation

/// Executed statements, newest first, persisted across launches.
@MainActor @Observable
final class QueryHistory {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var sql: String
        var dataSource: UUID
        var date: Date
    }

    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    func record(_ sql: String, dataSource: UUID) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.sql == trimmed && $0.dataSource == dataSource }
        entries.insert(Entry(sql: trimmed, dataSource: dataSource, date: Date()), at: 0)
        if entries.count > 1000 { entries.removeLast(entries.count - 1000) }
        onChange?()
    }

    func load(_ e: [Entry]) { entries = e }
    func clear() {
        entries = []
        onChange?()
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var dataSources: [DataSourceSession] = []
    private(set) var tabs: [EditorTab] = []
    var selectedTabID: UUID?
    let history = QueryHistory()

    /// Data source being edited in the sheet (nil = none; new config = add).
    var editingDataSource: DataSourceConfig?
    var editingIsNew = false
    var showHistory = false
    var showGoTo = false

    private let store = Store()
    private var saveTask: Task<Void, Never>?

    init() {
        let state = store.load()
        dataSources = state.dataSources.map(DataSourceSession.init)
        history.load(state.history)
        history.onChange = { [weak self] in self?.scheduleSave() }
        for c in state.consoles where session(for: c.dataSourceID) != nil {
            let m = ConsoleModel(id: c.id, title: c.title, dataSourceID: c.dataSourceID, text: c.text, schema: c.schema)
            m.app = self
            tabs.append(.console(m))
        }
        selectedTabID = state.selectedConsole.flatMap { id in tabs.first { $0.id == id }?.id } ?? tabs.first?.id
    }

    func session(for id: UUID) -> DataSourceSession? { dataSources.first { $0.config.id == id } }

    var selectedTab: EditorTab? { tabs.first { $0.id == selectedTabID } }

    /// Data source of the active tab, used by toolbar/menu commands.
    var activeDataSource: DataSourceSession? { selectedTab.flatMap { session(for: $0.dataSourceID) } }

    // MARK: Data sources

    func beginAddDataSource(_ dialect: SQLDialect = .postgres) {
        var c = DataSourceConfig(dialect: dialect)
        if dialect == .postgres { c.user = "postgres"; c.database = "postgres" }
        if dialect == .mysql { c.user = "root" }
        editingDataSource = c
        editingIsNew = true
    }

    func beginEdit(_ session: DataSourceSession) {
        editingDataSource = session.config
        editingIsNew = false
    }

    func saveDataSource(_ config: DataSourceConfig, password: String?) {
        if let password { Keychain.setPassword(password, for: config.id) }
        if let existing = session(for: config.id) {
            let changed = existing.config != config
            existing.config = config
            if changed { Task { await existing.disconnect() } }
        } else {
            let s = DataSourceSession(config: config)
            dataSources.append(s)
            Task { await s.connect() }
        }
        scheduleSave()
    }

    func deleteDataSource(_ session: DataSourceSession) {
        for tab in tabs where tab.dataSourceID == session.config.id { close(tab.id) }
        dataSources.removeAll { $0 === session }
        Keychain.delete(session.config.id)
        Task { await session.disconnect() }
        scheduleSave()
    }

    func duplicate(_ session: DataSourceSession) {
        var c = session.config
        c.id = UUID()
        c.name = session.config.displayName + " copy"
        if let pw = Keychain.password(for: session.config.id) { Keychain.setPassword(pw, for: c.id) }
        dataSources.append(DataSourceSession(config: c))
        scheduleSave()
    }

    func moveDataSources(from: IndexSet, to: Int) {
        dataSources.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    // MARK: Tabs

    @discardableResult
    func newConsole(for session: DataSourceSession, schema: String? = nil, text: String = "") -> ConsoleModel {
        let existing = tabs.filter { $0.dataSourceID == session.config.id }.compactMap {
            if case .console(let c) = $0 { c } else { nil }
        }
        let base = session.config.displayName
        let title = existing.isEmpty ? base : "\(base) [\(existing.count + 1)]"
        let m = ConsoleModel(title: title, dataSourceID: session.config.id, text: text, schema: schema)
        m.app = self
        tabs.append(.console(m))
        selectedTabID = m.id
        Task { await m.prepare() }
        scheduleSave()
        return m
    }

    /// Opens (or focuses) the default console for a data source.
    func openConsole(for session: DataSourceSession) {
        if let tab = tabs.first(where: {
            if case .console(let c) = $0 { return c.dataSourceID == session.config.id }
            return false
        }) {
            selectedTabID = tab.id
        } else {
            newConsole(for: session)
        }
    }

    func openTable(_ table: TableInfo, in session: DataSourceSession) {
        if let tab = tabs.first(where: {
            if case .table(let t) = $0 { return t.dataSourceID == session.config.id && t.table == table }
            return false
        }) {
            selectedTabID = tab.id
            return
        }
        let m = TableDataModel(dataSourceID: session.config.id, table: table)
        m.app = self
        tabs.append(.table(m))
        selectedTabID = m.id
        Task { await m.reload() }
    }

    func openDDL(_ table: TableInfo, in session: DataSourceSession) {
        let m = DDLModel(dataSourceID: session.config.id, table: table)
        tabs.append(.ddl(m))
        selectedTabID = m.id
        Task {
            do { m.text = try await session.ddl(for: table) } catch { m.text = "-- " + error.localizedDescription }
        }
    }

    /// Inserts `sql` into the active console for the data source (or a new one).
    func insertIntoConsole(_ sql: String, dataSource: UUID) {
        guard let session = session(for: dataSource) else { return }
        if case .console(let c) = selectedTab, c.dataSourceID == dataSource {
            c.text += (c.text.isEmpty || c.text.hasSuffix("\n") ? "" : "\n") + sql + "\n"
        } else {
            openConsole(for: session)
            if case .console(let c) = selectedTab {
                c.text += (c.text.isEmpty || c.text.hasSuffix("\n") ? "" : "\n") + sql + "\n"
            }
        }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if case .console(let c) = tabs[index], c.inTransaction {
            let alert = NSAlert()
            alert.messageText = "“\(c.title)” has an uncommitted transaction"
            alert.informativeText = "Commit or roll back before closing the console?"
            alert.addButton(withTitle: "Commit")
            alert.addButton(withTitle: "Rollback")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task {
                    await c.endTransaction(commit: true)
                    if !c.inTransaction { close(id) }
                }
                return
            case .alertSecondButtonReturn:
                Task {
                    await c.endTransaction(commit: false)
                    close(id)
                }
                return
            default:
                return
            }
        }
        let tab = tabs.remove(at: index)
        switch tab {
        case .console(let c): Task { await c.disconnect() }
        case .table(let t): Task { await t.close() }
        case .ddl: break
        }
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        scheduleSave()
    }

    func closeSelectedTab() {
        if let id = selectedTabID { close(id) }
    }

    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        let consoles: [Store.ConsoleState] = tabs.compactMap {
            guard case .console(let c) = $0 else { return nil }
            return Store.ConsoleState(id: c.id, title: c.title, dataSourceID: c.dataSourceID, text: c.text, schema: c.currentSchema)
        }
        store.save(
            Store.State(
                dataSources: dataSources.map(\.config), consoles: consoles,
                history: Array(history.entries.prefix(1000)), selectedConsole: selectedTabID))
    }
}

/// JSON state under ~/Library/Application Support/DBIDE.
struct Store {
    struct ConsoleState: Codable {
        var id: UUID
        var title: String
        var dataSourceID: UUID
        var text: String
        var schema: String?
    }

    struct State: Codable {
        var dataSources: [DataSourceConfig] = []
        var consoles: [ConsoleState] = []
        var history: [QueryHistory.Entry] = []
        var selectedConsole: UUID?
    }

    let url: URL = {
        if let override = ProcessInfo.processInfo.environment["DBIDE_STATE"] {
            return URL(fileURLWithPath: override)
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DBIDE", isDirectory: true)
        return dir.appendingPathComponent("state.json")
    }()

    func load() -> State {
        guard let data = try? Data(contentsOf: url) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    func save(_ state: State) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
