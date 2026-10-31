import AppKit
import DBIDECore
import SwiftUI
import UniformTypeIdentifiers

struct ConsoleView: View {
    @Environment(AppModel.self) private var app
    @Bindable var console: ConsoleModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VSplitView {
                SQLEditorView(
                    text: $console.text,
                    dialect: console.dialect,
                    executingRange: console.executingRange,
                    errorRange: console.errorRange,
                    onSelectionChange: { console.selection = $0 },
                    completer: { text, caret in console.complete(text: text, caret: caret) },
                    completionVersion: console.catalogVersion
                )
                .frame(minHeight: 120, idealHeight: 300)
                .onChange(of: console.text) { app.scheduleSave() }

                ResultsPanel(console: console)
                    .frame(minHeight: 120, idealHeight: 280)
            }
        }
        .sheet(item: $console.parameterRequest) { request in
            ParameterSheet(request: request) { result in
                request.finish(result)
                console.parameterRequest = nil
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                console.run(.caretOrSelection)
            } label: {
                Label("Execute", systemImage: "play.fill").foregroundStyle(.green)
            }
            .help("Execute statement at caret or selection (⌘↩)")
            .disabled(console.isRunning)
            Button {
                console.run(.all)
            } label: {
                Label("Run All", systemImage: "forward.fill")
            }
            .help("Execute the whole console (⇧⌘↩)")
            .disabled(console.isRunning)
            Button {
                console.cancel()
            } label: {
                Label("Cancel", systemImage: "stop.fill").foregroundStyle(console.isRunning ? .red : .secondary)
            }
            .help("Cancel running statement (⌘.)")
            .disabled(!console.isRunning)

            Divider().frame(height: 16)

            if let ds = console.dataSource {
                HStack(spacing: 4) {
                    DialectIcon(dialect: ds.config.dialect)
                    Text(ds.config.displayName).lineLimit(1)
                    if ds.config.confirmWrites {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
                            .help("Changes on this data source require confirmation")
                    }
                }
            }
            if console.dialect != .sqlite, !console.schemas.isEmpty {
                Picker("Schema", selection: Binding(
                    get: { console.currentSchema ?? "" },
                    set: { s in Task { await console.switchSchema(s) } })
                ) {
                    ForEach(console.schemas, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .help("Current schema")
            }
            if console.dialect.supportsTransactions {
            Divider().frame(height: 16)
            Picker("Transaction", selection: $console.autoCommit) {
                Text("Auto").tag(true)
                Text("Manual").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Transaction mode: Auto-commit, or Manual (open a transaction, then Commit / Rollback)")
            if console.inTransaction || !console.autoCommit {
                Button {
                    Task { await console.endTransaction(commit: true) }
                } label: {
                    Label("Commit", systemImage: "checkmark.circle")
                }
                .disabled(!console.inTransaction || console.isRunning)
                Button {
                    Task { await console.endTransaction(commit: false) }
                } label: {
                    Label("Rollback", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(!console.inTransaction || console.isRunning)
            }
            if console.inTransaction {
                Label("Transaction open", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Changes are not visible to other sessions until you commit")
            }
            }
            Spacer()
            if console.isRunning || console.isConnecting {
                ProgressView().controlSize(.small)
                Text(console.isConnecting ? "Connecting…" : "Running…").foregroundStyle(.secondary)
            }
            Picker("Limit", selection: $console.maxRows) {
                ForEach([100, 500, 1000, 5000, 50000], id: \.self) { Text("\($0) rows").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Maximum rows fetched per result")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if let c = console.dataSource.flatMap({ DataSourceColor.of($0.config) }) { c.opacity(0.12) }
        }
    }
}

/// Values for `:name` / `$1` / `?` placeholders, inserted as typed SQL.
private struct ParameterSheet: View {
    let request: ParameterRequest
    let done: ([String: String]?) -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parameters").font(.headline)
            Text("Values are inserted as SQL — quote text: 'abc'. Use NULL for null.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                ForEach(request.names, id: \.self) { name in
                    TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Execute") { done(values) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.names.contains { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear { values = request.values }
        .onDisappear { request.finish(nil) }  // no-op if already finished
    }
}

private struct ResultsPanel: View {
    @Bindable var console: ConsoleModel
    @State private var showJSON = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(title: "Output", systemImage: "text.alignleft", selected: console.selectedResultID == nil) {
                    console.selectedResultID = nil
                }
                ForEach(console.results) { r in
                    tabButton(
                        title: r.title, systemImage: r.pinned ? "pin.fill" : (r.plan != nil ? "chart.bar.doc.horizontal" : "tablecells"),
                        selected: console.selectedResultID == r.id
                    ) { console.selectedResultID = r.id }
                    .contextMenu {
                        Button(r.pinned ? "Unpin" : "Pin Tab") { console.togglePin(r.id) }
                        Button("Close") { console.closeResult(r.id) }
                        Button("Close Unpinned") { console.results.removeAll { !$0.pinned } ; console.selectedResultID = console.results.first?.id }
                    }
                }
                Spacer()
                if let r = console.results.first(where: { $0.id == console.selectedResultID }), r.plan == nil, r.result.documents != nil {
                    Picker("", selection: $showJSON) {
                        Text("Grid").tag(false)
                        Text("JSON").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                if let r = console.results.first(where: { $0.id == console.selectedResultID }), r.plan == nil {
                    Text(r.result.summary).font(.caption).foregroundStyle(.secondary)
                    ExportMenu(result: r.result, dialect: console.dialect, name: r.title)
                        .padding(.horizontal, 8)
                }
            }
            .frame(height: 26)
            .background(.bar)
            Divider()
            if let r = console.results.first(where: { $0.id == console.selectedResultID }), let plan = r.plan {
                PlanView(plan: plan).id(r.id)
            } else if let r = console.results.first(where: { $0.id == console.selectedResultID }), showJSON, let docs = r.result.documents {
                DocumentsView(documents: docs)
            } else if let r = console.results.first(where: { $0.id == console.selectedResultID }) {
                ResultArea(result: r.result, dialect: console.dialect, version: r.id.hashValue &+ r.result.rows.count)
                    .id(r.id)
                if r.result.truncated {
                    HStack(spacing: 10) {
                        Text("Showing first \(r.result.rows.count) rows.")
                        if SQLClassifier.isReadOnly(r.result.statement, dialect: console.dialect) {
                            Button("Load \(console.maxRows) more") {
                                console.loadMore(r.id, upTo: r.result.rows.count + console.maxRows)
                            }
                            Button("Load all") { console.loadMore(r.id, upTo: nil) }
                        } else {
                            Text("Add LIMIT/OFFSET to see more.")
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                    .disabled(console.isRunning)
                    .padding(4)
                }
            } else {
                OutputLog(entries: console.log)
            }
        }
    }

    private func tabButton(title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(selected ? Color.accentColor.opacity(0.15) : .clear)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Result grid with quick filter, record (transposed) view and selection aggregates.
struct ResultArea: View {
    let result: QueryResult
    let dialect: SQLDialect
    let version: Int
    @State private var filter = ""
    @State private var recordView = false
    @State private var selectedRows: [Int] = []
    @State private var column: Int?
    @State private var recordIndex = 0

    private var visibleCount: Int {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return result.rows.count }
        return result.rows.filter { $0.contains { $0.displayString.lowercased().contains(needle) } }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter rows", text: $filter)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 220)
                if !filter.isEmpty {
                    Text("\(visibleCount) of \(result.rows.count)").foregroundStyle(.secondary)
                }
                Spacer()
                if let stats { Text(stats.summary).foregroundStyle(.secondary).lineLimit(1) }
                Picker("", selection: $recordView) {
                    Image(systemName: "tablecells").tag(false)
                    Image(systemName: "list.bullet.rectangle").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Grid / record view (one row, transposed)")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            Divider()
            if recordView {
                recordBody
            } else {
                ResultGridView(source: gridSource)
            }
        }
    }

    private var gridSource: GridSource {
        var g = GridSource.readOnly(result, dialect: dialect, version: version)
        g.filter = filter
        g.onSelectionChange = { rows, col in
            selectedRows = rows
            column = col
            if let first = rows.first { recordIndex = first }
        }
        return g
    }

    private func transposedSource(_ r: QueryResult, index: Int) -> GridSource {
        var g = GridSource.readOnly(r, dialect: dialect, version: version &+ index &* 7919)
        g.filter = filter
        return g
    }

    private var stats: ResultStats? {
        guard selectedRows.count > 1, let c = column, c < result.columns.count else { return nil }
        return ResultStats(selectedRows.compactMap { $0 < result.rows.count ? result.rows[$0][c] : nil })
    }

    @ViewBuilder
    private var recordBody: some View {
        let index = min(recordIndex, max(0, result.rows.count - 1))
        HStack {
            Button { recordIndex = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
            Text(result.rows.isEmpty ? "No rows" : "Row \(index + 1) of \(result.rows.count)").monospacedDigit()
            Button { recordIndex = min(result.rows.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= result.rows.count - 1)
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        if !result.rows.isEmpty {
            let row = result.rows[index]
            let transposed = QueryResult(
                columns: [ResultColumn(name: "column", typeName: ""), ResultColumn(name: "type", typeName: ""), ResultColumn(name: "value", typeName: "")],
                rows: result.columns.enumerated().map { i, c in [.text(c.name), .text(c.typeName), i < row.count ? row[i] : .null] })
            ResultGridView(source: transposedSource(transposed, index: index))
        }
    }
}

/// MongoDB documents rendered as shell-style JSON.
struct DocumentsView: View {
    let documents: [BSONDocument]
    @State private var text = ""

    var body: some View {
        SQLEditorView(text: $text, dialect: .mongodb, isEditable: false)
            .onAppear { text = render() }
            .onChange(of: documents) { text = render() }
    }

    private func render() -> String {
        documents.prefix(2000).map(\.prettyString).joined(separator: ",\n")
            + (documents.count > 2000 ? "\n// … \(documents.count - 2000) more" : "")
    }
}

struct OutputLog: View {
    var entries: [LogEntry]
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.timeFormat.string(from: e.date)).foregroundStyle(.tertiary)
                            Text(e.kind == .statement ? "> " + e.text : e.text)
                                .foregroundStyle(e.kind == .error ? Color.red : e.kind == .statement ? .primary : .secondary)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .id(e.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: entries.count) {
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ExportMenu: View {
    var result: QueryResult
    var dialect: SQLDialect
    var name: String

    var body: some View {
        Menu {
            ForEach(ResultExport.Format.allCases, id: \.self) { f in
                Button("Export \(f.title)…") { export(f) }
            }
            Divider()
            ForEach(ResultExport.Format.allCases, id: \.self) { f in
                Button("Copy All as \(f.title)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(render(f), forType: .string)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export / copy result")
    }

    private func render(_ f: ResultExport.Format) -> String {
        ResultExport.render(
            columns: result.columns, rows: result.rows, format: f, dialect: dialect, tableName: dialect.quote(name))
    }

    private func export(_ f: ResultExport.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(f.fileExtension)"
        if let type = UTType(filenameExtension: f.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? render(f).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Completion

extension ConsoleModel {
    /// Completion at `caret`, using whatever catalog is loaded; anything missing is
    /// loaded in the background and `catalogVersion` bumps so an open popup refreshes.
    func complete(text: String, caret: Int) -> SQLCompletionResult {
        let empty = SQLCompletionResult(replaceRange: NSRange(location: caret, length: 0), items: [])
        guard let ds = dataSource else { return empty }
        if !ds.isConnected {
            if case .connecting = ds.state {} else {
                Task {
                    await ds.connect()
                    catalogVersion += 1
                }
            }
        }
        var catalog = CompletionCatalog(schemas: ds.schemas.map(\.name), defaultSchema: currentSchema ?? ds.defaultSchema)
        for node in ds.schemas {
            if let t = node.tables { catalog.tables[node.name] = t }
            for (table, cols) in node.columns { catalog.columns[node.name + "." + table] = cols }
        }
        let result = SQLCompletion.complete(text: text, caret: caret, dialect: dialect, catalog: catalog)
        for schema in result.missingSchemas {
            guard let node = ds.schema(named: schema), !loadingCatalog.contains("s:" + schema) else { continue }
            loadingCatalog.insert("s:" + schema)
            Task {
                await ds.loadSchema(node)
                loadingCatalog.remove("s:" + schema)
                catalogVersion += 1
            }
        }
        for table in result.missingTables where !loadingCatalog.contains("t:" + table.id) {
            loadingCatalog.insert("t:" + table.id)
            Task {
                await ds.loadTable(table)
                loadingCatalog.remove("t:" + table.id)
                catalogVersion += 1
            }
        }
        return result
    }
}
