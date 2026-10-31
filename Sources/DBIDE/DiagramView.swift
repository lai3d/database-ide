import AppKit
import DBIDECore
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class DiagramModel: Identifiable {
    let id = UUID()
    let session: DataSourceSession
    let schema: String
    let dataSourceID: UUID
    var title: String { schema + " diagram" }

    private(set) var tables: [TableInfo] = []
    private(set) var columns: [String: [ColumnInfo]] = [:]
    private(set) var foreignKeys: [ForeignKeyInfo] = []
    /// Top-left of each table box, in diagram coordinates.
    var positions: [String: CGPoint] = [:]
    var zoom: CGFloat = 1
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var truncated = false

    static let boxWidth: CGFloat = 230
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 19
    static let maxColumnsShown = 24
    static let maxTables = 150

    init(session: DataSourceSession, schema: String) {
        self.session = session
        self.schema = schema
        dataSourceID = session.config.id
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await session.connect()
        guard let conn = session.connection else {
            error = "Not connected"
            return
        }
        let intro = Introspector(conn)
        do {
            let all = try await intro.tables(schema: schema).filter { $0.kind == .table }
            truncated = all.count > Self.maxTables
            tables = Array(all.prefix(Self.maxTables))
            foreignKeys = try await intro.foreignKeys(schema: schema)
            for t in tables { columns[t.name] = try await intro.columns(schema: schema, table: t.name) }
            layout()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func boxHeight(_ table: String) -> CGFloat {
        let n = min(columns[table]?.count ?? 0, Self.maxColumnsShown)
        let more = (columns[table]?.count ?? 0) > Self.maxColumnsShown ? 1 : 0
        return Self.headerHeight + CGFloat(n + more) * Self.rowHeight + 8
    }

    /// Layered layout: referenced tables on the left.
    func layout() {
        let names = tables.map(\.name)
        let edges = foreignKeys.filter { $0.refSchema == schema }.map { (from: $0.table, to: $0.refTable) }
        let grid = ERLayout.grid(tables: names, foreignKeys: edges)
        var columnY: [Int: CGFloat] = [:]
        for name in names.sorted(by: { (grid[$0]!.column, grid[$0]!.row) < (grid[$1]!.column, grid[$1]!.row) }) {
            let c = grid[name]!.column
            let y = columnY[c, default: 30]
            positions[name] = CGPoint(x: 30 + CGFloat(c) * (Self.boxWidth + 110), y: y)
            columnY[c] = y + boxHeight(name) + 30
        }
    }

    var contentSize: CGSize {
        let maxX = positions.values.map { $0.x + Self.boxWidth }.max() ?? 400
        let maxY = positions.map { $0.value.y + boxHeight($0.key) }.max() ?? 300
        return CGSize(width: maxX + 60, height: maxY + 60)
    }

    /// Y of a column's row inside a box (relative to the box top).
    func rowY(_ table: String, column: String) -> CGFloat {
        let cols = columns[table] ?? []
        let i = cols.firstIndex { $0.name == column } ?? 0
        return Self.headerHeight + 4 + (CGFloat(min(i, Self.maxColumnsShown)) + 0.5) * Self.rowHeight
    }
}

struct DiagramView: View {
    @Bindable var model: DiagramModel
    @Environment(AppModel.self) private var app
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var highlighted: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(model.tables.count) tables · \(model.foreignKeys.count) foreign keys").font(.caption).foregroundStyle(.secondary)
                if model.truncated {
                    Text("(first \(DiagramModel.maxTables) shown)").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Re-layout") { withAnimation { model.layout() } }
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $model.zoom, in: 0.3...1.6).frame(width: 140)
                Image(systemName: "plus.magnifyingglass")
                Button("Export PNG…", action: exportPNG)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if model.isLoading {
                ProgressView("Loading schema…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .scaleEffect(model.zoom, anchor: .topLeading)
                        .frame(width: model.contentSize.width * model.zoom, height: model.contentSize.height * model.zoom, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    /// The diagram at zoom 1 (also used for PNG export).
    var canvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in drawEdges(ctx) }
                .frame(width: model.contentSize.width, height: model.contentSize.height)
            ForEach(model.tables) { t in
                TableBox(table: t, columns: model.columns[t.name] ?? [], foreignKeyColumns: fkColumns(t.name),
                         highlighted: highlighted == t.name)
                    .frame(width: DiagramModel.boxWidth, height: model.boxHeight(t.name), alignment: .top)
                    .offset(x: model.positions[t.name]?.x ?? 0, y: model.positions[t.name]?.y ?? 0)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let start = dragStart[t.name] ?? model.positions[t.name] ?? .zero
                                dragStart[t.name] = start
                                model.positions[t.name] = CGPoint(x: max(0, start.x + v.translation.width), y: max(0, start.y + v.translation.height))
                            }
                            .onEnded { _ in dragStart[t.name] = nil }
                    )
                    .onTapGesture(count: 2) { app.openTable(t, in: model.session) }
                    .onHover { highlighted = $0 ? t.name : (highlighted == t.name ? nil : highlighted) }
            }
        }
        .frame(width: model.contentSize.width, height: model.contentSize.height, alignment: .topLeading)
    }

    private func fkColumns(_ table: String) -> Set<String> {
        Set(model.foreignKeys.filter { $0.table == table }.flatMap(\.columns))
    }

    private func drawEdges(_ ctx: GraphicsContext) {
        for fk in model.foreignKeys where fk.refSchema == model.schema {
            guard let a = model.positions[fk.table], let b = model.positions[fk.refTable] else { continue }
            let w = DiagramModel.boxWidth
            let y1 = a.y + model.rowY(fk.table, column: fk.columns.first ?? "")
            let y2 = b.y + model.rowY(fk.refTable, column: fk.refColumns.first ?? "")
            var path = Path()
            let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
            if fk.table == fk.refTable {  // self reference: loop on the right side
                start = CGPoint(x: a.x + w, y: y1)
                end = CGPoint(x: a.x + w, y: y2)
                c1 = CGPoint(x: a.x + w + 50, y: y1)
                c2 = CGPoint(x: a.x + w + 50, y: y2)
            } else if b.x + w < a.x {  // parent on the left
                start = CGPoint(x: a.x, y: y1)
                end = CGPoint(x: b.x + w, y: y2)
                let dx = max(40, (start.x - end.x) / 2)
                c1 = CGPoint(x: start.x - dx, y: y1)
                c2 = CGPoint(x: end.x + dx, y: y2)
            } else if a.x + w < b.x {
                start = CGPoint(x: a.x + w, y: y1)
                end = CGPoint(x: b.x, y: y2)
                let dx = max(40, (end.x - start.x) / 2)
                c1 = CGPoint(x: start.x + dx, y: y1)
                c2 = CGPoint(x: end.x - dx, y: y2)
            } else {  // same column: route around the left edge
                start = CGPoint(x: a.x, y: y1)
                end = CGPoint(x: b.x, y: y2)
                c1 = CGPoint(x: a.x - 60, y: y1)
                c2 = CGPoint(x: b.x - 60, y: y2)
            }
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
            let hot = highlighted == fk.table || highlighted == fk.refTable
            ctx.stroke(path, with: .color(hot ? .accentColor : .secondary.opacity(0.6)), lineWidth: hot ? 2 : 1.2)
            // Parent end: filled dot; child end: open circle.
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(hot ? .accentColor : .secondary))
            ctx.stroke(Path(ellipseIn: CGRect(x: start.x - 3.5, y: start.y - 3.5, width: 7, height: 7)), with: .color(.secondary), lineWidth: 1)
        }
    }

    private func exportPNG() {
        let renderer = ImageRenderer(content: canvas.background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.schema)-diagram.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

private struct TableBox: View {
    let table: TableInfo
    let columns: [ColumnInfo]
    let foreignKeyColumns: Set<String>
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "tablecells").font(.caption)
                Text(table.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: DiagramModel.headerHeight, alignment: .leading)
            .background(Color.accentColor.opacity(highlighted ? 1 : 0.85))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(columns.prefix(DiagramModel.maxColumnsShown)) { c in
                    HStack(spacing: 4) {
                        Image(systemName: c.isPrimaryKey ? "key.fill" : foreignKeyColumns.contains(c.name) ? "link" : "circle.fill")
                            .font(.system(size: c.isPrimaryKey || foreignKeyColumns.contains(c.name) ? 9 : 4))
                            .foregroundStyle(c.isPrimaryKey ? .yellow : foreignKeyColumns.contains(c.name) ? .teal : .secondary)
                            .frame(width: 12)
                        Text(c.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(c.type).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(height: DiagramModel.rowHeight)
                }
                if columns.count > DiagramModel.maxColumnsShown {
                    Text("… \(columns.count - DiagramModel.maxColumnsShown) more").font(.caption2).foregroundStyle(.secondary)
                        .frame(height: DiagramModel.rowHeight)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(highlighted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: highlighted ? 2 : 1))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}
