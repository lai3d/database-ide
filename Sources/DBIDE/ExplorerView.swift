import AppKit
import DBIDECore
import SwiftUI

/// Selection identity for explorer rows.
enum ExplorerNode: Hashable {
    case dataSource(UUID)
    case schema(UUID, String)
    case table(UUID, TableInfo)
    case column(UUID, TableInfo, String)
    case routine(UUID, RoutineInfo)
    case folder(UUID, String)
}

struct ExplorerView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Set<ExplorerNode> = []
    @State private var expanded: Set<String> = []
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Database Explorer").font(.headline)
                Spacer()
                Menu {
                    ForEach(SQLDialect.allCases, id: \.self) { d in
                        Button(d.displayName) { app.beginAddDataSource(d) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Data Source")
                Button {
                    for ds in app.dataSources where ds.isConnected { Task { await ds.refresh() } }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            TextField("Filter tables", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            Divider()

            if app.dataSources.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(app.dataSources, id: \.config.id) { ds in
                        DataSourceRow(session: ds, expanded: $expanded, filter: filter)
                    }
                    .onMove { app.moveDataSources(from: $0, to: $1) }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: ExplorerNode.self) { nodes in
                    contextMenu(nodes)
                } primaryAction: { nodes in
                    primaryAction(nodes)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "cylinder.split.1x2").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No data sources").foregroundStyle(.secondary)
            Menu("Add Data Source") {
                ForEach(SQLDialect.allCases, id: \.self) { d in
                    Button(d.displayName) { app.beginAddDataSource(d) }
                }
            }
            .fixedSize()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func primaryAction(_ nodes: Set<ExplorerNode>) {
        guard let node = nodes.first else { return }
        switch node {
        case .dataSource(let id):
            if let ds = app.session(for: id) { app.openConsole(for: ds) }
        case .schema(let id, let schema):
            if let ds = app.session(for: id) { app.newConsole(for: ds, schema: schema) }
        case .table(let id, let t):
            if let ds = app.session(for: id) { app.openTable(t, in: ds) }
        case .column(let id, _, let name):
            app.insertIntoConsole(name, dataSource: id)
        case .routine, .folder:
            break
        }
    }

    @ViewBuilder
    private func contextMenu(_ nodes: Set<ExplorerNode>) -> some View {
        if let node = nodes.first {
            switch node {
            case .dataSource(let id):
                if let ds = app.session(for: id) {
                    Button("New Query Console") { app.newConsole(for: ds) }
                    Divider()
                    if ds.isConnected {
                        Button("Refresh") { Task { await ds.refresh() } }
                        Button("Disconnect") { Task { await ds.disconnect() } }
                    } else {
                        Button("Connect") { Task { await ds.connect() } }
                    }
                    if ds.isConnected, let schema = ds.defaultSchema ?? ds.schemas.first?.name {
                        if ds.config.dialect.isSQL { Button("Show ER Diagram") { app.openDiagram(schema: schema, in: ds) } }
                        Button("Import CSV as New Table…") {
                            app.csvImport = CSVImportTarget(session: ds, schema: schema, table: nil)
                        }
                    }
                    Divider()
                    Button("Properties…") { app.beginEdit(ds) }
                    Button("Duplicate") { app.duplicate(ds) }
                    Divider()
                    Button("Delete Data Source", role: .destructive) { confirmDelete(ds) }
                }
            case .schema(let id, let schema):
                if let ds = app.session(for: id) {
                    Button("New Query Console") { app.newConsole(for: ds, schema: schema) }
                    Button("Refresh") {
                        if let n = ds.schema(named: schema) { Task { await ds.loadSchema(n, force: true) } }
                    }
                    if ds.config.dialect.isSQL { Button("Show ER Diagram") { app.openDiagram(schema: schema, in: ds) } }
                    Button("Import CSV as New Table…") {
                        app.csvImport = CSVImportTarget(session: ds, schema: schema, table: nil)
                    }
                    Button("Copy Name") { copy(schema) }
                }
            case .table(let id, let t):
                if let ds = app.session(for: id) {
                    Button("Open Data") { app.openTable(t, in: ds) }
                    Button("Show DDL") { app.openDDL(t, in: ds) }
                    if t.kind == .table {
                        Button("Import CSV…") { app.csvImport = CSVImportTarget(session: ds, schema: t.schema, table: t) }
                    }
                    Divider()
                    let q = ds.config.dialect.qualified(schema: t.schema, name: t.name)
                    if ds.config.dialect == .mongodb {
                        Button("Query in Console") {
                            app.insertIntoConsole("db.getCollection(\(SQLDialect.mongodb.literal(t.name))).find({})", dataSource: id)
                        }
                    } else {
                        Button("SELECT in Console") { app.insertIntoConsole("SELECT * FROM \(q);", dataSource: id) }
                    }
                    Button("Copy Name") { copy(t.name) }
                    Button("Copy Qualified Name") { copy(q) }
                    Divider()
                    Button("Drop \(ds.config.dialect == .mongodb ? "Collection" : t.kind == .table ? "Table" : "View")…", role: .destructive) {
                        app.insertIntoConsole(
                            ds.config.dialect == .mongodb
                                ? "db.getCollection(\(SQLDialect.mongodb.literal(t.name))).drop()"
                                : "DROP \(t.kind == .table ? "TABLE" : "VIEW") \(q);", dataSource: id)
                    }
                }
            case .column(_, _, let name):
                Button("Copy Name") { copy(name) }
            case .routine(let id, let r):
                Button("Copy Name") { copy(r.name) }
                if let ds = app.session(for: id) {
                    Button("Call in Console") {
                        let q = ds.config.dialect.qualified(schema: r.schema, name: r.name)
                        app.insertIntoConsole(r.kind == "procedure" ? "CALL \(q)();" : "SELECT \(q)();", dataSource: id)
                    }
                }
            case .folder:
                EmptyView()
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func confirmDelete(_ ds: DataSourceSession) {
        let alert = NSAlert()
        alert.messageText = "Delete data source “\(ds.config.displayName)”?"
        alert.informativeText = "Its consoles will be closed. The database itself is not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { app.deleteDataSource(ds) }
    }
}

private struct DataSourceRow: View {
    @Bindable var session: DataSourceSession
    @Binding var expanded: Set<String>
    var filter: String

    private var key: String { session.config.id.uuidString }

    var body: some View {
        DisclosureGroup(isExpanded: binding(key, onExpand: { Task { await session.connect() } })) {
            switch session.state {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption).lineLimit(4)
                Button("Retry") { Task { await session.connect() } }.controlSize(.small)
            case .connecting:
                ProgressView().controlSize(.small)
            default:
                // Single-schema SQLite databases skip the schema level.
                if session.config.dialect == .sqlite, session.schemas.count == 1, let only = session.schemas.first {
                    SchemaContents(session: session, schema: only, expanded: $expanded, filter: filter)
                        .task { await session.loadSchema(only) }
                } else {
                    ForEach(session.schemas) { schema in
                        SchemaRow(session: session, schema: schema, expanded: $expanded, filter: filter)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let c = DataSourceColor.of(session.config) {
                    RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 3, height: 26)
                }
                DialectIcon(dialect: session.config.dialect)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.config.displayName).lineLimit(1)
                    Text(session.config.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.securityDescription != nil {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .help(statusHelp)
            }
        }
        .tag(ExplorerNode.dataSource(session.config.id))
    }

    private var statusHelp: String {
        guard session.isConnected else { return "" }
        let tls = session.securityDescription.map { "\n🔒 \($0)" } ?? (session.config.dialect == .sqlite ? "" : "\nNot encrypted")
        return session.serverVersion + tls
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray.opacity(0.4)
        }
    }

    private func binding(_ key: String, onExpand: @escaping () -> Void) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { open in
                if open {
                    expanded.insert(key)
                    onExpand()
                } else {
                    expanded.remove(key)
                }
            })
    }
}

struct DialectIcon: View {
    var dialect: SQLDialect
    var body: some View {
        let (letter, color): (String, Color) =
            switch dialect {
            case .postgres: ("P", .blue)
            case .mysql: ("M", .orange)
            case .sqlite: ("S", .teal)
            case .mongodb: ("Mg", .green)
            }
        Text(letter)
            .font(.system(size: letter.count > 1 ? 8 : 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
    }
}

private struct SchemaRow: View {
    var session: DataSourceSession
    @Bindable var schema: SchemaNode
    @Binding var expanded: Set<String>
    var filter: String

    var body: some View {
        let key = session.config.id.uuidString + "/" + schema.name
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(key) || !filter.isEmpty && schema.tables != nil },
                set: { open in
                    if open {
                        expanded.insert(key)
                        Task { await session.loadSchema(schema) }
                    } else {
                        expanded.remove(key)
                    }
                })
        ) {
            SchemaContents(session: session, schema: schema, expanded: $expanded, filter: filter)
        } label: {
            HStack {
                Label(schema.name, systemImage: "square.stack.3d.up")
                if schema.name == session.defaultSchema {
                    Text("default").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .tag(ExplorerNode.schema(session.config.id, schema.name))
    }
}

private struct SchemaContents: View {
    var session: DataSourceSession
    @Bindable var schema: SchemaNode
    @Binding var expanded: Set<String>
    var filter: String

    var body: some View {
        if schema.isLoading && schema.tables == nil {
            ProgressView().controlSize(.small)
        } else if let error = schema.error {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let tables = schema.tables {
            let visible = filter.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            let plain = visible.filter { $0.kind == .table }
            let views = visible.filter { $0.kind != .table }
            folder(session.config.dialect == .mongodb ? "collections" : "tables", count: plain.count) {
                ForEach(plain) { TableRow(session: session, schema: schema, table: $0, expanded: $expanded) }
            }
            if !views.isEmpty {
                folder("views", count: views.count) {
                    ForEach(views) { TableRow(session: session, schema: schema, table: $0, expanded: $expanded) }
                }
            }
            if !schema.routines.isEmpty, filter.isEmpty {
                folder("routines", count: schema.routines.count) {
                    ForEach(schema.routines) { r in
                        Label {
                            Text(r.name) + Text("  \(r.kind)").font(.caption).foregroundColor(.secondary)
                        } icon: {
                            Image(systemName: "function").foregroundStyle(.purple)
                        }
                        .tag(ExplorerNode.routine(session.config.id, r))
                    }
                }
            }
        }
    }

    private func folder<Content: View>(_ name: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        let key = session.config.id.uuidString + "/" + schema.name + "/" + name
        return DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(key) || (!filter.isEmpty && name != "routines") },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
        ) {
            content
        } label: {
            HStack {
                Label(name, systemImage: "folder")
                Text("\(count)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .tag(ExplorerNode.folder(session.config.id, key))
    }
}

private struct TableRow: View {
    var session: DataSourceSession
    var schema: SchemaNode
    var table: TableInfo
    @Binding var expanded: Set<String>

    var body: some View {
        let key = session.config.id.uuidString + "/" + table.id
        DisclosureGroup(
            isExpanded: Binding(
                get: { expanded.contains(key) },
                set: { open in
                    if open {
                        expanded.insert(key)
                        Task { await session.loadTable(table) }
                    } else {
                        expanded.remove(key)
                    }
                })
        ) {
            if let cols = schema.columns[table.name] {
                ForEach(cols) { c in
                    HStack(spacing: 4) {
                        Image(systemName: c.isPrimaryKey ? "key.fill" : "line.3.horizontal")
                            .foregroundStyle(c.isPrimaryKey ? .yellow : .secondary)
                            .font(.caption)
                        Text(c.name)
                        Text(c.type + (c.nullable ? "" : " not null"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .help(c.comment ?? "")
                    .tag(ExplorerNode.column(session.config.id, table, c.name))
                }
                let fks = schema.foreignKeys.filter { $0.table == table.name }
                if !fks.isEmpty {
                    let fkey = key + "/fks"
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expanded.contains(fkey) },
                            set: { if $0 { expanded.insert(fkey) } else { expanded.remove(fkey) } })
                    ) {
                        ForEach(fks) { fk in
                            HStack(spacing: 4) {
                                Image(systemName: "link").font(.caption).foregroundStyle(.teal)
                                Text("(\(fk.columns.joined(separator: ", ")))")
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text("\(fk.refSchema == fk.schema ? "" : fk.refSchema + ".")\(fk.refTable)(\(fk.refColumns.joined(separator: ", ")))")
                                    .foregroundStyle(.secondary)
                            }
                            .help(fk.name)
                            .tag(ExplorerNode.folder(session.config.id, fkey + "/" + fk.name))
                        }
                    } label: {
                        Label("foreign keys", systemImage: "folder")
                    }
                    .tag(ExplorerNode.folder(session.config.id, fkey))
                }
                let idx = schema.indexes[table.name] ?? []
                if !idx.isEmpty {
                    let ikey = key + "/indexes"
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expanded.contains(ikey) },
                            set: { if $0 { expanded.insert(ikey) } else { expanded.remove(ikey) } })
                    ) {
                        ForEach(idx) { i in
                            HStack(spacing: 4) {
                                Image(systemName: i.primary ? "key" : i.unique ? "number.circle" : "number")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(i.name)
                                Text("(\(i.columns.joined(separator: ", ")))").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(ExplorerNode.folder(session.config.id, ikey + "/" + i.name))
                        }
                    } label: {
                        Label("indexes", systemImage: "folder")
                    }
                    .tag(ExplorerNode.folder(session.config.id, ikey))
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Label {
                Text(table.name)
            } icon: {
                Image(systemName: table.kind == .table ? "tablecells" : "eye")
                    .foregroundStyle(table.kind == .table ? .blue : .indigo)
            }
            .help(table.comment ?? table.kind.label)
        }
        .tag(ExplorerNode.table(session.config.id, table))
    }
}
