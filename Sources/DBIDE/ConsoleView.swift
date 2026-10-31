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
            } else if let r = console.results.first(where: { $0.id == console.selectedResultID }) {
                ResultGridView(source: .readOnly(r.result, dialect: console.dialect, version: r.id.hashValue &+ r.result.rows.count))
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
