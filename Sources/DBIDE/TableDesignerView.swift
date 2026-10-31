import AppKit
import DBIDECore
import SwiftUI

struct TableDesignTarget: Identifiable {
    let id = UUID()
    let session: DataSourceSession
    let schema: String
    /// nil = new table.
    let table: TableInfo?
}

/// Create / modify a table, previewing the generated DDL.
struct TableDesignerView: View {
    @Environment(\.dismiss) private var dismiss
    let target: TableDesignTarget
    @State private var original: TableDesign?
    @State private var design = TableDesign(schema: "", name: "", columns: [])
    @State private var loading = true
    @State private var running = false
    @State private var error: String?
    @State private var preview = ""

    private var dialect: SQLDialect { target.session.config.dialect }
    private var isNew: Bool { target.table == nil }

    private var statements: [String] {
        if let original { return design.alterStatements(from: original, dialect: dialect) }
        return design.createStatements(dialect: dialect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New Table in \(target.schema)" : "Modify Table \(target.table!.name)").font(.headline)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    TextField("Name", text: $design.name).textFieldStyle(.roundedBorder).frame(width: 240)
                    TextField("Comment", text: $design.comment).textFieldStyle(.roundedBorder)
                }
                columnHeader
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach($design.columns) { $col in
                            ColumnRow(column: $col, dialect: dialect,
                                      onDelete: { design.columns.removeAll { $0.id == col.id } },
                                      onMove: { move(col.id, by: $0) })
                        }
                    }
                }
                .frame(minHeight: 160)
                HStack {
                    Button {
                        design.columns.append(.init(name: "column\(design.columns.count + 1)", type: TableDesign.suggestedTypes(dialect).dropFirst(isNew && dialect == .postgres ? 2 : 0).first ?? "text"))
                    } label: { Label("Add Column", systemImage: "plus") }
                    Spacer()
                    if dialect == .sqlite, statements.contains(where: { $0.hasPrefix("INSERT INTO") }) {
                        Label("SQLite will rebuild the table (copy data, recreate indexes)", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .controlSize(.small)
                Text("Preview").font(.subheadline)
                SQLEditorView(text: $preview, dialect: dialect, isEditable: false)
                    .frame(height: 150)
                    .border(Color(nsColor: .separatorColor))
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).lineLimit(5)
            }
            HStack {
                if dialect == .mysql { Text("MySQL DDL is not transactional: statements before a failure stay applied.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Apply") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || running || statements.isEmpty || design.validate() != nil)
            }
            if let problem = design.validate(), !loading {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(width: 860, height: 640)
        .task { await load() }
        .onChange(of: design) { preview = renderPreview() }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Name").frame(width: 170, alignment: .leading)
            Text("Type").frame(width: 170, alignment: .leading)
            Text("Not null").frame(width: 56)
            Text("PK").frame(width: 30)
            Text("Default").frame(width: 130, alignment: .leading)
            Text("Comment").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func move(_ id: String, by delta: Int) {
        guard let i = design.columns.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard design.columns.indices.contains(j) else { return }
        design.columns.swapAt(i, j)
    }

    private func renderPreview() -> String {
        let sql = statements
        return sql.isEmpty ? "-- no changes" : sql.map { $0 + ";" }.joined(separator: "\n\n")
    }

    private func load() async {
        defer {
            loading = false
            preview = renderPreview()
        }
        if let table = target.table {
            do {
                await target.session.connect()
                guard let conn = target.session.connection else { throw DatabaseError("Not connected") }
                let d = try await TableDesign.load(table, from: conn)
                original = d
                design = d
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            let types = TableDesign.suggestedTypes(dialect)
            design = TableDesign(schema: target.schema, name: "new_table", columns: [
                .init(name: "id", type: dialect == .postgres ? "bigserial" : dialect == .mysql ? "bigint" : "INTEGER", nullable: false, primaryKey: true),
                .init(name: "name", type: dialect == .sqlite ? "TEXT" : types.contains("text") ? "text" : "varchar(255)"),
            ])
        }
    }

    private func apply() async {
        let sql = statements
        guard confirmWrites(sql, on: target.session.config) else { return }
        running = true
        error = nil
        defer { running = false }
        do {
            let conn = try await target.session.config.connect(password: Keychain.password(for: target.session.config.id) ?? "")
            defer { Task { await conn.close() } }
            try await TableDesign.apply(sql, on: conn)
            if let node = target.session.schema(named: target.schema) {
                node.columns = [:]
                await target.session.loadSchema(node, force: true)
            }
            dismiss()
        } catch {
            self.error = (dialect == .postgres || dialect == .sqlite ? "Nothing was changed: " : "") + error.localizedDescription
        }
    }
}

private struct ColumnRow: View {
    @Binding var column: TableDesign.Column
    let dialect: SQLDialect
    let onDelete: () -> Void
    let onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("name", text: $column.name).frame(width: 170)
            HStack(spacing: 2) {
                TextField("type", text: $column.type)
                Menu {
                    ForEach(TableDesign.suggestedTypes(dialect), id: \.self) { t in Button(t) { column.type = t } }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .frame(width: 170)
            Toggle("", isOn: Binding(get: { !column.nullable }, set: { column.nullable = !$0 })).labelsHidden().frame(width: 56)
            Toggle("", isOn: $column.primaryKey).labelsHidden().frame(width: 30)
            TextField("default", text: $column.defaultValue).frame(width: 130)
            TextField("comment", text: $column.comment)
            Button { onMove(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
            Button { onMove(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
            Button(action: onDelete) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.red)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
        .controlSize(.small)
    }
}
