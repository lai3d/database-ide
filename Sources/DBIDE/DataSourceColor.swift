import AppKit
import DBIDECore
import SwiftUI

/// Color tags for data sources (e.g. red for production), stored as hex in the config.
enum DataSourceColor: String, CaseIterable, Identifiable {
    case none = ""
    case red = "#E5484D", orange = "#F76B15", yellow = "#FFC53D", green = "#30A46C", blue = "#0090FF", purple = "#8E4EC6"

    var id: String { rawValue }
    var title: String { self == .none ? "None" : String(describing: self).capitalized }

    var color: Color? { self == .none ? nil : Color(hex: rawValue) }

    static func of(_ config: DataSourceConfig) -> Color? {
        guard let hex = config.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Asks before running data-modifying statements on a guarded data source. Returns true to proceed.
@MainActor
func confirmWrites(_ statements: [String], on config: DataSourceConfig) -> Bool {
    guard config.confirmWrites else { return true }
    let writes = statements.filter { !SQLClassifier.isReadOnly($0, dialect: config.dialect) }
    guard !writes.isEmpty else { return true }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Modify data on “\(config.displayName)”?"
    let preview = writes.prefix(5).map { String($0.prefix(160)) }.joined(separator: "\n\n")
    alert.informativeText = "\(writes.count) statement\(writes.count == 1 ? "" : "s") will change data or schema:\n\n\(preview)\(writes.count > 5 ? "\n\n…" : "")"
    alert.addButton(withTitle: "Execute")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
