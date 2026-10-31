import SwiftUI

/// User preferences (UserDefaults keys shared with @AppStorage).
enum Preferences {
    static let fontSizeKey = "editorFontSize"
    static let autoCompleteKey = "autoPopupCompletion"
    static let uppercaseKeywordsKey = "formatUppercaseKeywords"
    static let defaultRowLimitKey = "defaultRowLimit"
    static let defaultAutoCommitKey = "defaultAutoCommit"

    static func register() {
        UserDefaults.standard.register(defaults: [
            fontSizeKey: 13.0, autoCompleteKey: true, uppercaseKeywordsKey: true,
            defaultRowLimitKey: 500, defaultAutoCommitKey: true,
        ])
    }

    static var fontSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: fontSizeKey)) }
    static var autoComplete: Bool { UserDefaults.standard.bool(forKey: autoCompleteKey) }
    static var uppercaseKeywords: Bool { UserDefaults.standard.bool(forKey: uppercaseKeywordsKey) }
    static var defaultRowLimit: Int { UserDefaults.standard.integer(forKey: defaultRowLimitKey) }
    static var defaultAutoCommit: Bool { UserDefaults.standard.bool(forKey: defaultAutoCommitKey) }
}

struct SettingsView: View {
    @AppStorage(Preferences.fontSizeKey) private var fontSize = 13.0
    @AppStorage(Preferences.autoCompleteKey) private var autoComplete = true
    @AppStorage(Preferences.uppercaseKeywordsKey) private var uppercase = true
    @AppStorage(Preferences.defaultRowLimitKey) private var rowLimit = 500
    @AppStorage(Preferences.defaultAutoCommitKey) private var autoCommit = true

    var body: some View {
        TabView {
            Form {
                HStack {
                    Slider(value: $fontSize, in: 10...22, step: 1) { Text("Font size") }
                    Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 44)
                }
                Text("SELECT * FROM products WHERE price > 50;")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                Toggle("Show completion popup while typing", isOn: $autoComplete)
                Text("⌃Space or Esc always opens it.").font(.caption).foregroundStyle(.secondary)
                Toggle("Upper-case keywords when reformatting (⌥⌘L)", isOn: $uppercase)
            }
            .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }

            Form {
                Picker("Default row limit", selection: $rowLimit) {
                    ForEach([100, 500, 1000, 5000, 50000], id: \.self) { Text("\($0) rows").tag($0) }
                }
                Picker("Default transaction mode", selection: $autoCommit) {
                    Text("Auto-commit").tag(true)
                    Text("Manual").tag(false)
                }
                Text("Applies to consoles opened from now on.").font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Query", systemImage: "play.rectangle") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}
