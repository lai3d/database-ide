import AppKit
import DBIDECore
import SwiftUI

/// DataGrip-style table editor: WHERE / ORDER BY filters, paging, edit + submit.
struct TableDataView: View {
    @Bindable var model: TableDataModel
    @State private var editVersion = 0
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filters
            Divider()
            if let error = model.error {
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
            }
            if let result = model.result {
                ResultGridView(source: gridSource(result))
            } else {
                Spacer()
                if model.isRunning { ProgressView() }
                Spacer()
            }
            statusBar
        }
        .sheet(isPresented: $showPreview) { previewSheet }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            Divider().frame(height: 16)
            Button { Task { await model.previousPage() } } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack || model.hasPendingChanges)
                .help("Previous page")
            Text(pageLabel).font(.caption).monospacedDigit()
            Button { Task { await model.nextPage() } } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward || model.hasPendingChanges)
                .help("Next page")
            Picker("Page size", selection: $model.pageSize) {
                ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.pageSize) { Task { await model.reload(resetPage: true) } }
            Button("Count") { Task { await model.countRows() } }
                .help("Count rows matching the filter")
            Divider().frame(height: 16)
            if model.isEditable {
                Button { model.addRow(); editVersion += 1 } label: { Image(systemName: "plus") }
                    .help("Add row")
                Button {
                    Task {
                        await model.submit()
                        editVersion += 1
                    }
                } label: {
                    Label("Submit", systemImage: "arrow.up.circle.fill")
                }
                .disabled(!model.hasPendingChanges)
                .help("Apply pending changes in one transaction (⌘↩)")
                .keyboardShortcut(.return, modifiers: .command)
                Button("Preview") { showPreview = true }
                    .disabled(!model.hasPendingChanges)
                Button("Revert") {
                    model.discardChanges()
                    editVersion += 1
                }
                .disabled(!model.hasPendingChanges)
            } else if model.result != nil {
                Text(model.table.kind == .table ? "read-only (no primary key)" : "read-only (\(model.table.kind.label))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancel() }
            }
            if let r = model.result {
                ExportMenu(result: r, dialect: model.dialect, name: model.table.name)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Text("WHERE").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.blue)
            TextField("e.g. id > 10 AND name LIKE 'a%'", text: $model.filter)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.reload(resetPage: true) } }
            Divider().frame(height: 16)
            Text("ORDER BY").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.blue)
            TextField("e.g. id DESC", text: $model.orderBy)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .frame(maxWidth: 220)
                .onSubmit { Task { await model.reload(resetPage: true) } }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var pageLabel: String {
        guard let r = model.result else { return "–" }
        if r.rows.isEmpty { return "0 rows" }
        let from = model.offset + 1
        let to = model.offset + r.rows.count
        return "\(from)–\(to)" + (model.totalCount.map { " of \($0)" } ?? "")
    }

    private var statusBar: some View {
        HStack {
            Text(model.lastSQL).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.hasPendingChanges {
                let n = model.pendingStatements().count
                Text("\(n) pending change\(n == 1 ? "" : "s")").foregroundStyle(.orange)
            }
            if let r = model.result { Text(String(format: "%.0f ms", r.duration * 1000)) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(.bar)
    }

    private func gridSource(_ result: QueryResult) -> GridSource {
        let m = model
        let base = result.rows.count
        return GridSource(
            columns: result.columns,
            rowCount: base + m.pending.insertedRows.count,
            version: editVersion &+ result.rows.count &* 31 &+ Int(result.duration * 1e6),
            dialect: m.dialect,
            tableName: m.dialect.qualified(schema: m.table.schema, name: m.table.name),
            value: { r, c in m.value(row: r, column: c) },
            rowState: { r in
                r >= base ? .inserted : m.pending.deletedRows.contains(r) ? .deleted : m.pending.updates[r] != nil ? .edited : .normal
            },
            isCellEdited: { r, c in m.pending.updates[r]?[c] != nil },
            onEdit: m.isEditable
                ? { r, c, v in
                    m.setValue(v, row: r, column: c)
                    editVersion += 1
                } : nil,
            onDeleteRows: m.isEditable
                ? { rows in
                    m.deleteRows(rows)
                    editVersion += 1
                } : nil)
    }

    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending changes").font(.headline)
            ScrollView {
                Text(model.pendingStatements().map { $0 + ";" }.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 560, minHeight: 220)
            HStack {
                Spacer()
                Button("Close") { showPreview = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
    }
}

struct DDLView: View {
    @Bindable var model: DDLModel
    var dialect: SQLDialect

    var body: some View {
        SQLEditorView(text: $model.text, dialect: dialect, isEditable: false)
    }
}
