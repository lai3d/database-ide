import AppKit
import DBIDECore
import SwiftUI

enum GridRowState { case normal, edited, deleted, inserted }

/// What the grid shows. `version` must change whenever the content does.
struct GridSource {
    var columns: [ResultColumn]
    var rowCount: Int
    var version: Int
    var dialect: SQLDialect
    var tableName: String = "my_table"
    var value: (Int, Int) -> SQLValue
    var rowState: ((Int) -> GridRowState)? = nil
    var isCellEdited: ((Int, Int) -> Bool)? = nil
    /// Non-nil makes cells editable.
    var onEdit: ((Int, Int, SQLValue) -> Void)? = nil
    var onDeleteRows: ((IndexSet) -> Void)? = nil
    /// Client-side quick filter: rows containing this text in any column.
    var filter: String = ""
    /// Selected model rows and the last clicked column (model index).
    var onSelectionChange: ((_ rows: [Int], _ column: Int?) -> Void)? = nil

    static func readOnly(_ result: QueryResult, dialect: SQLDialect, version: Int) -> GridSource {
        GridSource(
            columns: result.columns, rowCount: result.rows.count, version: version, dialect: dialect,
            value: { r, c in c < result.rows[r].count ? result.rows[r][c] : .null })
    }
}

struct ResultGridView: NSViewRepresentable {
    var source: GridSource

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = .separatorColor.withAlphaComponent(0.4)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 20
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.menu = context.coordinator.makeMenu()
        table.menu?.delegate = context.coordinator
        table.action = #selector(Coordinator.singleClick(_:))
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        context.coordinator.headerMenu = headerMenu
        table.headerView?.menu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.apply(source, force: true)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(source, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var table: GridTableView?
        var source: GridSource?
        private var columnSignature: [ResultColumn] = []
        /// Display order → model row.
        private var order: [Int] = []
        private var popover: NSPopover?

        func apply(_ new: GridSource, force: Bool) {
            guard let table else { return }
            let old = source
            source = new
            if force || new.columns != columnSignature {
                if new.columns != columnSignature { hidden = [] }
                columnSignature = new.columns
                rebuildColumns(table, new)
            }
            if force || old?.version != new.version || old?.rowCount != new.rowCount || old?.filter != new.filter {
                resort()
                table.reloadData()
            }
        }

        private func rebuildColumns(_ table: NSTableView, _ s: GridSource) {
            for c in table.tableColumns { table.removeTableColumn(c) }
            let rowCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
            rowCol.title = ""
            rowCol.width = max(36, CGFloat(String(s.rowCount).count) * 8 + 14)
            rowCol.isEditable = false
            table.addTableColumn(rowCol)
            for (i, col) in s.columns.enumerated() where !hidden.contains(i) {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
                c.title = col.name
                c.headerToolTip = "\(col.name): \(col.typeName)"
                c.sortDescriptorPrototype = NSSortDescriptor(key: String(i), ascending: true)
                c.minWidth = 40
                c.width = estimateWidth(column: i, source: s)
                table.addTableColumn(c)
            }
            table.sortDescriptors = []
        }

        private func estimateWidth(column: Int, source s: GridSource) -> CGFloat {
            var chars = s.columns[column].name.count + 2
            for r in 0..<min(s.rowCount, 60) {
                chars = max(chars, min(60, s.value(r, column).displayString.count))
            }
            return min(420, max(60, CGFloat(chars) * 7.4 + 16))
        }

        private func resort() {
            guard let s = source else { return }
            let needle = s.filter.trimmingCharacters(in: .whitespaces).lowercased()
            if needle.isEmpty {
                order = Array(0..<s.rowCount)
            } else {
                order = (0..<s.rowCount).filter { r in
                    (0..<s.columns.count).contains { s.value(r, $0).displayString.lowercased().contains(needle) }
                }
            }
            guard let sd = table?.sortDescriptors.first, let key = sd.key, let col = Int(key) else { return }
            let asc = sd.ascending
            order.sort { a, b in
                let va = s.value(a, col), vb = s.value(b, col)
                return asc ? SQLValue.sortsBefore(va, vb) : SQLValue.sortsBefore(vb, va)
            }
        }

        func modelRow(_ displayRow: Int) -> Int { displayRow < order.count ? order[displayRow] : displayRow }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { order.count }

        // MARK: Selection & header menu

        weak var headerMenu: NSMenu?
        var hidden: Set<Int> = []
        private var lastColumn: Int?
        private var headerColumn: Int?

        @objc func singleClick(_ sender: NSTableView) {
            let col = sender.clickedColumn
            if col > 0, let c = Int(sender.tableColumns[col].identifier.rawValue) { lastColumn = c }
            notifySelection()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            // Re-render visible cells so text colors follow the selection highlight.
            if let table {
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
            notifySelection()
        }

        private func notifySelection() {
            guard let table, let s = source else { return }
            s.onSelectionChange?(table.selectedRowIndexes.map { modelRow($0) }, lastColumn)
        }

        private func buildHeaderMenu(_ menu: NSMenu) {
            guard let table, let header = table.headerView, let s = source else { return }
            let point = header.convert(header.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            let index = header.column(at: point)
            headerColumn = index > 0 ? Int(table.tableColumns[index].identifier.rawValue) : nil
            func item(_ title: String, _ action: Selector) -> NSMenuItem {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
                i.target = self
                return i
            }
            if let c = headerColumn {
                let name = NSMenuItem(title: s.columns[c].name + (s.columns[c].typeName.isEmpty ? "" : "  ·  " + s.columns[c].typeName), action: nil, keyEquivalent: "")
                name.isEnabled = false
                menu.addItem(name)
                menu.addItem(.separator())
                menu.addItem(item("Sort Ascending", #selector(sortAscending(_:))))
                menu.addItem(item("Sort Descending", #selector(sortDescending(_:))))
                menu.addItem(.separator())
                menu.addItem(item("Copy Column Name", #selector(copyColumnName(_:))))
                menu.addItem(item("Copy Column Values", #selector(copyColumnValues(_:))))
                menu.addItem(.separator())
                menu.addItem(item("Hide Column", #selector(hideColumn(_:))))
            }
            if !hidden.isEmpty { menu.addItem(item("Show All Columns (\(hidden.count) hidden)", #selector(showAllColumns(_:)))) }
        }

        @objc func sortAscending(_ sender: Any?) { sort(ascending: true) }
        @objc func sortDescending(_ sender: Any?) { sort(ascending: false) }
        private func sort(ascending: Bool) {
            guard let c = headerColumn, let table else { return }
            table.sortDescriptors = [NSSortDescriptor(key: String(c), ascending: ascending)]
        }

        @objc func copyColumnName(_ sender: Any?) {
            guard let c = headerColumn, let s = source else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.columns[c].name, forType: .string)
        }

        @objc func copyColumnValues(_ sender: Any?) {
            guard let c = headerColumn, let s = source else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(order.map { s.value($0, c).exportString }.joined(separator: "\n"), forType: .string)
        }

        @objc func hideColumn(_ sender: Any?) {
            guard let c = headerColumn, let table, let s = source else { return }
            hidden.insert(c)
            rebuildColumns(table, s)
            table.reloadData()
        }

        @objc func showAllColumns(_ sender: Any?) {
            guard let table, let s = source else { return }
            hidden = []
            rebuildColumns(table, s)
            table.reloadData()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            resort()
            tableView.reloadData()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let s = source, let tableColumn else { return nil }
            let id = tableColumn.identifier
            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = id
                cell.font = EditorTheme.gridFont
                cell.lineBreakMode = .byTruncatingTail
                cell.cell?.usesSingleLineMode = true
                cell.delegate = self
            }
            let m = modelRow(row)
            let state = s.rowState?(m) ?? .normal
            if id.rawValue == "#" {
                cell.stringValue = state == .inserted ? "+" : String(m + 1)
                cell.textColor = .tertiaryLabelColor
                cell.alignment = .right
                cell.isEditable = false
                cell.attributedStringValue = NSAttributedString(string: cell.stringValue)
                return cell
            }
            guard let col = Int(id.rawValue) else { return nil }
            let v = s.value(m, col)
            cell.isEditable = s.onEdit != nil && state != .deleted && !(v.isBlob)
            cell.alignment = v.isNumeric ? .right : .left
            let text = v.displayString.replacingOccurrences(of: "\n", with: "⏎")
            var attrs: [NSAttributedString.Key: Any] = [.font: EditorTheme.gridFont]
            if v.isNull {
                attrs[.foregroundColor] = NSColor.tertiaryLabelColor
                attrs[.font] = NSFontManager.shared.convert(EditorTheme.gridFont, toHaveTrait: .italicFontMask)
            } else if tableView.isRowSelected(row) {
                attrs[.foregroundColor] = NSColor.alternateSelectedControlTextColor
            } else {
                attrs[.foregroundColor] = v.isNumeric ? NSColor.systemBlue : NSColor.labelColor
            }
            if state == .deleted {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = NSColor.systemRed
            }
            cell.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
            cell.drawsBackground = state == .inserted || (s.isCellEdited?(m, col) ?? false)
            cell.backgroundColor =
                state == .inserted ? NSColor.systemGreen.withAlphaComponent(0.15) : NSColor.systemBlue.withAlphaComponent(0.15)
            cell.toolTip = v.displayString.count > 40 ? String(v.displayString.prefix(2000)) : nil
            return cell
        }

        // MARK: Editing

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let table, let s = source, let onEdit = s.onEdit else { return }
            let row = table.row(for: field)
            let colIndex = table.column(for: field)
            guard row >= 0, colIndex >= 0, let col = Int(table.tableColumns[colIndex].identifier.rawValue) else { return }
            let m = modelRow(row)
            let old = s.value(m, col)
            let text = field.stringValue
            if text == old.displayString.replacingOccurrences(of: "\n", with: "⏎") { return }
            let newValue: SQLValue =
                switch old {
                case .integer: Int64(text).map(SQLValue.integer) ?? .text(text)
                case .real: Double(text).map(SQLValue.real) ?? .text(text)
                default: .text(text)
                }
            onEdit(m, col, newValue)
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow, col = sender.clickedColumn
            guard row >= 0, col > 0, let s = source, let c = Int(sender.tableColumns[col].identifier.rawValue) else { return }
            if s.onEdit != nil, !(s.value(modelRow(row), c).isBlob) {
                sender.editColumn(col, row: row, with: nil, select: true)
            } else {
                showValue(row: row, column: col)
            }
        }

        private func showValue(row: Int, column: Int) {
            guard let table, let s = source, let c = Int(table.tableColumns[column].identifier.rawValue) else { return }
            let v = s.value(modelRow(row), c)
            var text = v.isNull ? "NULL" : v.exportString
            if case .text(let t) = v, let data = t.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data),
                let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                t.first == "{" || t.first == "["
            {
                text = String(decoding: pretty, as: UTF8.self)
            }
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
            tv.string = text
            tv.font = EditorTheme.gridFont
            tv.isEditable = false
            let scroll = NSScrollView(frame: tv.frame)
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            let vc = NSViewController()
            vc.view = scroll
            let p = NSPopover()
            p.contentViewController = vc
            p.behavior = .transient
            p.contentSize = tv.frame.size
            p.show(relativeTo: table.frameOfCell(atColumn: column, row: row), of: table, preferredEdge: .maxY)
            popover = p
        }

        // MARK: Copy & menu

        func selectedModelRows() -> [Int] {
            guard let table else { return [] }
            var rows = table.selectedRowIndexes
            if rows.isEmpty, table.clickedRow >= 0 { rows = IndexSet(integer: table.clickedRow) }
            return rows.map { modelRow($0) }
        }

        /// Columns in on-screen order (respecting reordering), excluding the row-number column.
        private func visibleColumns() -> [Int] {
            table?.tableColumns.compactMap { Int($0.identifier.rawValue) } ?? []
        }

        func copy(_ format: ResultExport.Format, header: Bool) {
            guard let s = source else { return }
            let cols = visibleColumns()
            let rows = selectedModelRows().map { r in cols.map { s.value(r, $0) } }
            let text = ResultExport.render(
                columns: cols.map { s.columns[$0] }, rows: rows, format: format, includeHeader: header,
                dialect: s.dialect, tableName: s.tableName)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc func copyTSV(_ sender: Any?) { copy(.tsv, header: false) }
        @objc func copyWithHeader(_ sender: Any?) { copy(.tsv, header: true) }
        @objc func copyAs(_ sender: NSMenuItem) {
            guard let f = sender.representedObject as? String, let format = ResultExport.Format(rawValue: f) else { return }
            copy(format, header: true)
        }

        @objc func copyCell(_ sender: Any?) {
            guard let table, let s = source else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            let col = table.clickedColumn
            guard row >= 0, col > 0, let c = Int(table.tableColumns[col].identifier.rawValue) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.value(modelRow(row), c).exportString, forType: .string)
        }

        @objc func viewValue(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedColumn > 0 else { return }
            showValue(row: table.clickedRow, column: table.clickedColumn)
        }

        @objc func setNull(_ sender: Any?) {
            guard let table, let s = source, let onEdit = s.onEdit else { return }
            let col = table.clickedColumn
            guard col > 0, let c = Int(table.tableColumns[col].identifier.rawValue) else { return }
            for r in selectedModelRows() { onEdit(r, c, .null) }
        }

        @objc func deleteRows(_ sender: Any?) {
            guard let s = source, let onDelete = s.onDeleteRows else { return }
            onDelete(IndexSet(selectedModelRows()))
        }

        func makeMenu() -> NSMenu { NSMenu() }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                buildHeaderMenu(menu)
                return
            }
            func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
                i.target = self
                return i
            }
            if (table?.clickedColumn ?? -1) > 0 {
                menu.addItem(item("View Value", #selector(viewValue(_:))))
                menu.addItem(item("Copy Cell Value", #selector(copyCell(_:))))
                menu.addItem(.separator())
            }
            menu.addItem(item("Copy Rows", #selector(copyTSV(_:))))
            menu.addItem(item("Copy Rows with Header", #selector(copyWithHeader(_:))))
            let sub = NSMenu()
            for f in ResultExport.Format.allCases {
                let i = item(f.title, #selector(copyAs(_:)))
                i.representedObject = f.rawValue
                sub.addItem(i)
            }
            let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
            copyAs.submenu = sub
            menu.addItem(copyAs)
            if source?.onEdit != nil {
                menu.addItem(.separator())
                if (table?.clickedColumn ?? -1) > 0 { menu.addItem(item("Set NULL", #selector(setNull(_:)))) }
                menu.addItem(item("Delete Rows", #selector(deleteRows(_:))))
            }
        }
    }
}

final class GridTableView: NSTableView {
    weak var coordinator: ResultGridView.Coordinator?

    @objc func copy(_ sender: Any?) { coordinator?.copy(.tsv, header: false) }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty || flags == .function, event.keyCode == 51 || event.keyCode == 117 {  // ⌫ / ⌦
            coordinator?.deleteRows(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return numberOfSelectedRows > 0 }
        return super.validateUserInterfaceItem(item)
    }
}

extension SQLValue {
    var isBlob: Bool { if case .blob = self { true } else { false } }
}
