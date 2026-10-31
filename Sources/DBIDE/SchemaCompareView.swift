import AppKit
import DBIDECore
import SwiftUI

/// Compare two schemas (any SQL data sources) and produce migration SQL for the target.
struct SchemaCompareView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var sourceSchema = ""
    @State private var targetSchema = ""
    @State private var diff: SchemaDiff?
    @State private var sql = ""
    @State private var running = false
    @State private var error: String?
    @State private var dropRemoved = true

    private var sqlSources: [DataSourceSession] { app.dataSources.filter { $0.config.dialect.isSQL } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare Schemas").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                picker("Source (desired state)", id: $sourceID, schema: $sourceSchema)
                Image(systemName: "arrow.right").padding(.top, 22)
                picker("Target (to migrate)", id: $targetID, schema: $targetSchema)
            }
            HStack {
                Button("Compare") { Task { await compare() } }
                    .disabled(running || sourceID == nil || targetID == nil || sourceSchema.isEmpty || targetSchema.isEmpty)
                Toggle("Drop tables missing from source", isOn: $dropRemoved)
                    .onChange(of: dropRemoved) { sql = render() }
                if running { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if let diff {
                HSplitView {
                    List {
                        if diff.isEmpty { Text("Schemas are identical").foregroundStyle(.secondary) }
                        ForEach(diff.tables, id: \.name) { t in
                            DisclosureGroup {
                                ForEach(t.columns, id: \.name) { c in line(c, icon: "line.3.horizontal") }
                                ForEach(t.indexes, id: \.name) { i in line(i, icon: "number") }
                            } label: {
                                Label {
                                    Text(t.name) + Text("  \(t.kind.rawValue)").foregroundColor(.secondary).font(.caption)
                                } icon: {
                                    Image(systemName: "tablecells").foregroundStyle(color(t.kind))
                                }
                            }
                        }
                    }
                    .frame(minWidth: 260)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Migration for the target").font(.subheadline)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sql, forType: .string)
                            }
                            Button("Open in Console") {
                                if let t = targetID { app.insertIntoConsole(sql, dataSource: t) }
                                dismiss()
                            }
                            .disabled(diff.isEmpty)
                        }
                        .controlSize(.small)
                        SQLEditorView(text: $sql, dialect: app.session(for: targetID ?? UUID())?.config.dialect ?? .postgres, isEditable: false)
                            .border(Color(nsColor: .separatorColor))
                    }
                    .frame(minWidth: 380)
                }
            } else {
                Spacer()
            }
            HStack {
                Text("Nothing is executed: review the SQL, then run it from a console.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 900, height: 620)
        .onAppear {
            sourceID = sourceID ?? sqlSources.first?.config.id
            targetID = targetID ?? (sqlSources.dropFirst().first ?? sqlSources.first)?.config.id
        }
    }

    @ViewBuilder
    private func picker(_ title: String, id: Binding<UUID?>, schema: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: id) {
                ForEach(sqlSources, id: \.config.id) { ds in
                    Text(ds.config.displayName).tag(Optional(ds.config.id))
                }
            }
            .labelsHidden()
            .frame(width: 300)
            SchemaPicker(session: app.session(for: id.wrappedValue ?? UUID()), schema: schema)
        }
    }

    private func line(_ c: SchemaDiff.ColumnChange, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(color(c.kind))
            Text(c.name)
            Text(c.kind.rawValue).font(.caption).foregroundStyle(color(c.kind))
            Text(c.details.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func color(_ k: SchemaDiff.Kind) -> Color {
        switch k {
        case .added: .green
        case .removed: .red
        case .changed: .orange
        }
    }

    private func render() -> String {
        guard let diff else { return "" }
        let statements = diff.migrationSQL(dropRemoved: dropRemoved)
        return statements.isEmpty ? "-- no changes" : statements.map { $0.hasPrefix("--") ? $0 : $0 + ";" }.joined(separator: "\n\n")
    }

    private func compare() async {
        guard let s = app.session(for: sourceID ?? UUID()), let t = app.session(for: targetID ?? UUID()) else { return }
        running = true
        error = nil
        defer { running = false }
        do {
            await s.connect()
            await t.connect()
            guard let sc = s.connection, let tc = t.connection else { throw DatabaseError("Could not connect") }
            let a = try await SchemaSnapshot.load(schema: sourceSchema, from: sc)
            let b = try await SchemaSnapshot.load(schema: targetSchema, from: tc)
            diff = SchemaDiff.compare(source: a, target: b)
            sql = render()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Schema chooser that connects the data source and lists its schemas.
private struct SchemaPicker: View {
    let session: DataSourceSession?
    @Binding var schema: String

    var body: some View {
        Picker("", selection: $schema) {
            ForEach(session?.schemas.map(\.name) ?? [], id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 300)
        .task(id: session?.config.id) {
            guard let session else { return }
            await session.connect()
            if !session.schemas.contains(where: { $0.name == schema }) {
                schema = session.defaultSchema ?? session.schemas.first?.name ?? ""
            }
        }
    }
}
