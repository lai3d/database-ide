import DBIDECore
import SwiftUI

/// ⌘O: fuzzy-find a table or view across all connected data sources.
struct GoToTableView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Candidate: Identifiable {
        let session: DataSourceSession
        let table: TableInfo
        let score: Int
        let id: String
    }

    private var candidates: [Candidate] {
        var out: [Candidate] = []
        for ds in app.dataSources where ds.isConnected {
            for schema in ds.schemas {
                for t in schema.tables ?? [] {
                    let qualified = schema.name + "." + t.name
                    // Match on the table name, or (slightly lower) on schema.table.
                    if let s = FuzzyMatch.score(query, name: t.name, qualifiedName: qualified) {
                        out.append(Candidate(session: ds, table: t, score: s, id: ds.config.id.uuidString + t.id))
                    }
                }
            }
        }
        return Array(out.sorted { ($0.score, $1.table.name) > ($1.score, $0.table.name) }.prefix(60))
    }

    var body: some View {
        let list = candidates
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to table or view", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(list, ddl: false) }
                    .onChange(of: query) { selection = 0 }
            }
            .padding(12)
            Divider()
            if list.isEmpty {
                Text(app.dataSources.contains(where: \.isConnected) ? "No matches" : "Connect a data source first")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(list.enumerated()), id: \.element.id) { index, c in
                        HStack(spacing: 8) {
                            Image(systemName: c.table.kind == .table ? "tablecells" : "eye")
                                .foregroundStyle(c.table.kind == .table ? .blue : .indigo)
                            Text(c.table.name).font(.system(.body, design: .monospaced))
                            Text(c.table.schema).foregroundStyle(.secondary)
                            Spacer()
                            DialectIcon(dialect: c.session.config.dialect)
                            Text(c.session.config.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(index == selection ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selection = index
                            open(list, ddl: false)
                        }
                        .onTapGesture { selection = index }
                        .id(index)
                    }
                    .listStyle(.plain)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
            Divider()
            HStack {
                Text("↩ open data   ⌥↩ show DDL   esc close").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(8)
        }
        .frame(width: 620, height: 420, alignment: .top)
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, list.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            open(list, ddl: true)
            return .handled
        }
        .onAppear { focused = true }
        .task {
            // Data sources in use (connected, or with open tabs): make sure their tables are listed.
            let used = app.dataSources.filter { ds in
                ds.isConnected || app.tabs.contains { $0.dataSourceID == ds.config.id }
            }
            for ds in used {
                await ds.connect()
                for node in ds.schemas where node.tables == nil { await ds.loadSchema(node) }
            }
        }
    }

    private func open(_ list: [Candidate], ddl: Bool) {
        guard list.indices.contains(selection) else { return }
        let c = list[selection]
        dismiss()
        if ddl { app.openDDL(c.table, in: c.session) } else { app.openTable(c.table, in: c.session) }
    }
}
