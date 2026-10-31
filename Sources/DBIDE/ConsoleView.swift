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
                    completions: { text, range in console.completions(text: text, wordRange: range) }
                )
                .frame(minHeight: 120, idealHeight: 300)
                .onChange(of: console.text) { app.scheduleSave() }

                ResultsPanel(console: console)
                    .frame(minHeight: 120, idealHeight: 280)
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
                        title: r.title, systemImage: "tablecells",
                        selected: console.selectedResultID == r.id
                    ) { console.selectedResultID = r.id }
                }
                Spacer()
                if let r = console.results.first(where: { $0.id == console.selectedResultID }) {
                    Text(r.result.summary).font(.caption).foregroundStyle(.secondary)
                    ExportMenu(result: r.result, dialect: console.dialect, name: r.title)
                        .padding(.horizontal, 8)
                }
            }
            .frame(height: 26)
            .background(.bar)
            Divider()
            if let r = console.results.first(where: { $0.id == console.selectedResultID }) {
                ResultGridView(source: .readOnly(r.result, dialect: console.dialect, version: r.id.hashValue))
                    .id(r.id)
                if r.result.truncated {
                    Text("Showing first \(r.result.rows.count) rows — raise the row limit or add LIMIT/OFFSET to see more.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Keyword, table and column candidates for the word at `wordRange`.
    func completions(text: String, wordRange: NSRange) -> [String] {
        guard let ds = dataSource else { return [] }
        let ns = text as NSString
        guard NSMaxRange(wordRange) <= ns.length else { return [] }
        let prefix = ns.substring(with: wordRange)
        let statement = SQLSplitter.statement(at: wordRange.location, in: text, dialect: dialect)?.text ?? text
        let aliases = Self.tableAliases(in: statement, dialect: dialect)
        let schema = currentSchema ?? ds.defaultSchema

        func cachedColumns(_ table: String, schema s: String?) -> [String]? {
            guard let node = ds.schema(named: s ?? schema ?? "") else { return nil }
            if let info = node.tables?.first(where: { $0.name.caseInsensitiveCompare(table) == .orderedSame }) {
                if let cols = node.columns[info.name] { return cols.map(\.name) }
                Task { await ds.loadTable(info) }
            } else if node.tables == nil {
                Task { await ds.loadSchema(node) }
            }
            return nil
        }

        var candidates: [String] = []
        // After `qualifier.` → columns of that table/alias, or tables of that schema.
        if wordRange.location > 0, ns.character(at: wordRange.location - 1) == UInt16(UInt8(ascii: ".")) {
            var start = wordRange.location - 1
            while start > 0, let u = UnicodeScalar(ns.character(at: start - 1)),
                CharacterSet.alphanumerics.contains(u) || u == "_" || u == "\"" || u == "`"
            {
                start -= 1
            }
            let qualifier = ns.substring(with: NSRange(location: start, length: wordRange.location - 1 - start))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            if let schemaNode = ds.schemas.first(where: { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame }) {
                if let tables = schemaNode.tables {
                    candidates = tables.map(\.name)
                } else {
                    Task { await ds.loadSchema(schemaNode) }
                }
            } else {
                let target = aliases[qualifier.lowercased()] ?? (nil, qualifier)
                candidates = cachedColumns(target.1, schema: target.0) ?? []
            }
        } else {
            let upper = prefix.uppercased()
            let lower = prefix.first.map { $0.isLowercase } ?? false
            candidates += SQLKeywords.list.filter { $0.hasPrefix(upper) }.map { lower ? $0.lowercased() : $0 }
            if let node = ds.schema(named: schema ?? "") {
                if let tables = node.tables {
                    candidates += tables.map(\.name)
                } else {
                    Task { await ds.loadSchema(node) }
                }
            }
            var tables: [String: (String?, String)] = [:]
            for v in aliases.values { tables[(v.0 ?? "") + "." + v.1.lowercased()] = v }
            for (s, t) in tables.values { candidates += cachedColumns(t, schema: s) ?? [] }
            candidates += aliases.keys.filter { !$0.isEmpty }
        }
        var seen = Set<String>()
        let filtered = candidates.filter {
            (prefix.isEmpty || $0.lowercased().hasPrefix(prefix.lowercased())) && $0 != prefix && seen.insert($0).inserted
        }
        return filtered.sorted { a, b in
            let ka = SQLKeywords.all.contains(a.uppercased()), kb = SQLKeywords.all.contains(b.uppercased())
            return ka != kb ? !ka : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Maps alias (and bare table name) → (schema, table) for FROM / JOIN / UPDATE / INTO clauses.
    static func tableAliases(in sql: String, dialect: SQLDialect) -> [String: (String?, String)] {
        let ns = sql as NSString
        let tokens = SQLLexer.tokenize(sql, dialect: dialect).filter { $0.kind != .comment }
        func text(_ i: Int) -> String {
            ns.substring(with: tokens[i].range).trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
        }
        func isName(_ i: Int) -> Bool {
            i < tokens.count && (tokens[i].kind == .identifier || tokens[i].kind == .quotedIdentifier)
        }
        var out: [String: (String?, String)] = [:]
        var i = 0
        while i < tokens.count {
            let word = ns.substring(with: tokens[i].range).uppercased()
            if ["FROM", "JOIN", "UPDATE", "INTO"].contains(word) {
                var j = i + 1
                guard isName(j) else {
                    i += 1
                    continue
                }
                var schema: String?
                var table = text(j)
                if j + 2 < tokens.count, ns.substring(with: tokens[j + 1].range) == ".", isName(j + 2) {
                    schema = table
                    table = text(j + 2)
                    j += 2
                }
                out[table.lowercased()] = (schema, table)
                j += 1
                if j < tokens.count, ns.substring(with: tokens[j].range).uppercased() == "AS" { j += 1 }
                if isName(j) { out[text(j).lowercased()] = (schema, table) }
            }
            i += 1
        }
        return out
    }
}
