import AppKit
import DBIDECore
import SwiftUI
import UniformTypeIdentifiers

struct CSVImportTarget: Identifiable {
    let id = UUID()
    let session: DataSourceSession
    let schema: String
    /// nil = create a new table.
    let table: TableInfo?
}

struct CSVImportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: CSVImportTarget

    @State private var fileURL: URL?
    @State private var text = ""
    @State private var delimiter: Character = ","
    @State private var hasHeader = true
    @State private var emptyAsNull = true
    @State private var newTableName = ""
    @State private var types: [CSVImport.ColumnType] = []
    @State private var mapping: [String?] = []
    @State private var tableColumns: [String] = []
    @State private var progress: Double?
    @State private var message: String?
    @State private var failed = false

    private var dialect: SQLDialect { target.session.config.dialect }
    private var csv: CSVImport { CSVImport(parsed: CSVParser.parse(text, delimiter: delimiter), firstRowIsHeader: hasHeader) }

    var body: some View {
        let csv = csv
        VStack(alignment: .leading, spacing: 10) {
            Text(target.table.map { "Import CSV into \($0.name)" } ?? "Import CSV as New Table")
                .font(.headline)
            HStack {
                Button("Choose File…", action: choose)
                Text(fileURL?.lastPathComponent ?? "No file").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Picker("Delimiter", selection: Binding(get: { String(delimiter) }, set: { delimiter = Character($0); reset() })) {
                    Text("Comma").tag(","); Text("Semicolon").tag(";"); Text("Tab").tag("\t"); Text("Pipe").tag("|")
                }
                .fixedSize()
                Toggle("Header row", isOn: $hasHeader).onChange(of: hasHeader) { reset() }
                Toggle("Empty = NULL", isOn: $emptyAsNull)
            }
            .controlSize(.small)

            if !text.isEmpty {
                Text("\(csv.rows.count) rows · \(csv.header.count) columns").font(.caption).foregroundStyle(.secondary)
                ResultGridView(source: .readOnly(previewResult(csv), dialect: dialect, version: previewVersion))
                    .frame(height: 170)
                    .border(Color(nsColor: .separatorColor))
                mappingSection(csv)
            } else {
                Spacer()
            }

            if let progress { ProgressView(value: progress) }
            if let message {
                Text(message).font(.callout).foregroundStyle(failed ? .red : .green).textSelection(.enabled).lineLimit(4)
            }
            HStack {
                Spacer()
                Button(message != nil && !failed ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await runImport(csv) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || progress != nil || (target.table == nil && newTableName.isEmpty)
                        || mapping.allSatisfy { $0 == nil } || (message != nil && !failed))
            }
        }
        .padding()
        .frame(width: 720, height: 600, alignment: .top)
        .task {
            if let t = target.table, let conn = target.session.connection {
                tableColumns = (try? await Introspector(conn).columns(schema: t.schema, table: t.name).map(\.name)) ?? []
            }
            choose()
        }
    }

    private var previewVersion: Int { text.count &+ Int(delimiter.asciiValue ?? 0) &* 7 &+ (hasHeader ? 1 : 0) }

    private func previewResult(_ csv: CSVImport) -> QueryResult {
        QueryResult(
            columns: csv.header.map { ResultColumn(name: $0, typeName: "") },
            rows: csv.rows.prefix(50).map { $0.map { SQLValue.text($0) } })
    }

    @ViewBuilder
    private func mappingSection(_ csv: CSVImport) -> some View {
        if target.table == nil {
            HStack {
                Text("Table name")
                TextField("name", text: $newTableName).textFieldStyle(.roundedBorder).frame(width: 260)
                Text("in \(target.schema)").foregroundStyle(.secondary)
            }
        }
        Text(target.table == nil ? "Columns and types" : "Map CSV columns to table columns").font(.subheadline)
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(csv.header.enumerated()), id: \.offset) { i, name in
                    GridRow {
                        Text(name).font(.system(.body, design: .monospaced)).lineLimit(1)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        if target.table == nil {
                            Toggle("", isOn: Binding(get: { i < mapping.count && mapping[i] != nil },
                                                     set: { if i < mapping.count { mapping[i] = $0 ? name : nil } }))
                                .labelsHidden()
                            Picker("", selection: Binding(get: { i < types.count ? types[i] : .text },
                                                          set: { if i < types.count { types[i] = $0 } })) {
                                ForEach(CSVImport.ColumnType.allCases, id: \.self) {
                                    Text(CSVImport.sqlType($0, dialect: dialect)).tag($0)
                                }
                            }
                            .labelsHidden().fixedSize()
                        } else {
                            Picker("", selection: Binding(get: { i < mapping.count ? mapping[i] : nil },
                                                          set: { if i < mapping.count { mapping[i] = $0 } })) {
                                Text("— skip —").tag(String?.none)
                                ForEach(tableColumns, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                            .labelsHidden().frame(width: 240)
                        }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        fileURL = url
        text = String(decoding: data, as: UTF8.self)
        delimiter = url.pathExtension.lowercased() == "tsv" ? "\t" : CSVParser.detectDelimiter(text)
        newTableName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"[^A-Za-z0-9_]+"#, with: "_", options: .regularExpression).lowercased()
        reset()
    }

    /// Recomputes inferred types and the default mapping after options change.
    private func reset() {
        let csv = csv
        types = (0..<csv.header.count).map(csv.inferType)
        mapping = target.table == nil ? csv.header.map { Optional($0) } : csv.autoMapping(to: tableColumns)
        message = nil
    }

    private func runImport(_ csv: CSVImport) async {
        let table = target.table?.name ?? newTableName
        let statements = csv.insertStatements(
            schema: target.schema, table: table, mapping: mapping, types: types, emptyAsNull: emptyAsNull, dialect: dialect)
        var all = statements
        var createSQL: String?
        if target.table == nil {
            // Only the chosen columns, with their types.
            let keep = mapping.indices.filter { mapping[$0] != nil }
            let sub = CSVImport(parsed: [keep.map { csv.header[$0] }], firstRowIsHeader: true)
            createSQL = sub.createTableSQL(schema: target.schema, table: table, types: keep.map { types[$0] }, dialect: dialect)
            all.insert(createSQL!, at: 0)
        }
        guard confirmWrites(all, on: target.session.config) else { return }
        failed = false
        message = nil
        progress = 0
        defer { progress = nil }
        do {
            let conn = try await target.session.config.connect(password: Keychain.password(for: target.session.config.id) ?? "")
            defer { Task { await conn.close() } }
            if let createSQL { _ = try await conn.execute(createSQL) }
            let n = try await CSVImport.run(statements, on: conn) { p in await MainActor.run { progress = p } }
            message = "Imported \(n) rows into \(table)."
            if let node = target.session.schema(named: target.schema) { await target.session.loadSchema(node, force: true) }
        } catch {
            failed = true
            message = "Import failed, nothing was imported: \(error.localizedDescription)"
                + (createSQL != nil && dialect != .postgres ? "\n(The new table may already have been created.)" : "")
        }
    }
}
