import AppKit
import DBIDECore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            ExplorerView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 480)
        } detail: {
            VStack(spacing: 0) {
                TabStrip()
                Divider()
                if let tab = app.selectedTab {
                    tabContent(tab).id(tab.id)
                } else {
                    WelcomeView()
                }
            }
        }
        .sheet(item: $app.editingDataSource) { config in
            DataSourceEditor(config: config, isNew: app.editingIsNew)
        }
        .sheet(isPresented: $app.showGoTo) { GoToTableView() }
        .inspector(isPresented: $app.showHistory) {
            HistoryView().inspectorColumnWidth(min: 240, ideal: 320, max: 500)
        }
        .toolbar {
            ToolbarItem {
                Button { app.showHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("Query history")
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: EditorTab) -> some View {
        switch tab {
        case .console(let c): ConsoleView(console: c)
        case .table(let t): TableDataView(model: t)
        case .ddl(let d): DDLView(model: d, dialect: app.session(for: d.dataSourceID)?.config.dialect ?? .postgres)
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(app.tabs) { tab in
                    TabButton(tab: tab, selected: tab.id == app.selectedTabID)
                    Divider().frame(height: 18)
                }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var app
    let tab: EditorTab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let ds = app.session(for: tab.dataSourceID) {
                DialectIcon(dialect: ds.config.dialect).scaleEffect(0.8)
            }
            Image(systemName: tab.icon).font(.caption).foregroundStyle(.secondary)
            Text(tab.title).lineLimit(1).font(.callout)
            if case .console(let c) = tab, c.isRunning {
                ProgressView().controlSize(.mini)
            }
            Button {
                app.close(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(selected ? Color(nsColor: .textBackgroundColor) : .clear)
        .overlay(alignment: .bottom) {
            if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .top) {
            if let c = app.session(for: tab.dataSourceID).flatMap({ DataSourceColor.of($0.config) }) {
                Rectangle().fill(c).frame(height: 3)
            }
        }
        .background {
            if let c = app.session(for: tab.dataSourceID).flatMap({ DataSourceColor.of($0.config) }) {
                c.opacity(0.10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selectedTabID = tab.id }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close") { app.close(tab.id) }
            Button("Close Others") {
                for t in app.tabs where t.id != tab.id { app.close(t.id) }
            }
            if case .console(let c) = tab, let ds = app.session(for: c.dataSourceID) {
                Divider()
                Button("New Console for \(ds.config.displayName)") { app.newConsole(for: ds) }
            }
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("DBIDE").font(.largeTitle.weight(.semibold))
            Text("Add a data source, then double-click it to open a query console.\nDouble-click a table to browse and edit its data.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(SQLDialect.allCases, id: \.self) { d in
                    Button {
                        app.beginAddDataSource(d)
                    } label: {
                        HStack { DialectIcon(dialect: d); Text(d.displayName) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                shortcut("⌘↩", "Execute statement at caret / selection")
                shortcut("⇧⌘↩", "Execute whole console")
                shortcut("⌘.", "Cancel running query")
                shortcut("⌃Space / Esc", "Complete keywords, tables, columns")
                shortcut("⌘/", "Toggle line comment")
            }
            .padding(.top, 8)
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ key: String, _ text: String) -> some View {
        HStack {
            Text(key).font(.system(.callout, design: .monospaced)).frame(width: 110, alignment: .trailing)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $search).textFieldStyle(.roundedBorder)
                Button("Clear") { app.history.clear() }.controlSize(.small)
            }
            .padding(8)
            Divider()
            List {
                ForEach(filtered) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.sql)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(4)
                        HStack {
                            Text(app.session(for: e.dataSource)?.config.displayName ?? "removed")
                            Spacer()
                            Text(e.date, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { app.insertIntoConsole(e.sql + ";", dataSource: e.dataSource) }
                    .contextMenu {
                        Button("Insert into Console") { app.insertIntoConsole(e.sql + ";", dataSource: e.dataSource) }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(e.sql, forType: .string)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var filtered: [QueryHistory.Entry] {
        let all = app.history.entries.prefix(500)
        guard !search.isEmpty else { return Array(all) }
        return all.filter { $0.sql.localizedCaseInsensitiveContains(search) }
    }
}
