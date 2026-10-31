import AppKit
import DBIDECore
import SwiftUI
import UniformTypeIdentifiers

struct DataSourceEditor: View {
    @Environment(AppModel.self) private var app
    @State var config: DataSourceConfig
    let isNew: Bool
    @State private var password = ""
    @State private var passwordChanged = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, ok(String), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Data Source" : "Data Source Properties")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            Form {
                Picker("Driver", selection: $config.dialect) {
                    ForEach(SQLDialect.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: config.dialect) { old, new in
                    if config.port == old.defaultPort || config.port == 0 { config.port = new.defaultPort }
                }
                TextField("Name", text: $config.name, prompt: Text(config.displayName))

                if config.dialect == .sqlite {
                    HStack {
                        TextField("File", text: $config.filePath, prompt: Text("~/data/app.db"))
                        Button("Choose…") { chooseFile(create: false) }
                        Button("New…") { chooseFile(create: true) }
                    }
                } else {
                    HStack {
                        TextField("Host", text: $config.host)
                        TextField("Port", value: $config.port, format: .number.grouping(.never))
                            .frame(width: 110)
                    }
                    TextField("User", text: $config.user)
                    SecureField("Password", text: $password, prompt: Text(isNew || passwordChanged ? "" : "•••••• (stored in Keychain)"))
                        .onChange(of: password) { passwordChanged = true }
                    TextField("Database", text: $config.database, prompt: Text(config.dialect == .mysql ? "optional" : config.user))
                }
                Toggle("Read-only", isOn: $config.readOnly)
            }
            .formStyle(.grouped)

            HStack {
                Button("Test Connection") { Task { await test() } }
                    .disabled(testState == .testing)
                switch testState {
                case .idle: EmptyView()
                case .testing: ProgressView().controlSize(.small)
                case .ok(let v):
                    Label(v, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
                case .failed(let e):
                    Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel") { app.editingDataSource = nil }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    app.saveDataSource(config, password: isNew || passwordChanged ? password : nil)
                    app.editingDataSource = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.dialect == .sqlite ? config.filePath.isEmpty : config.host.isEmpty)
            }
            .padding()
        }
        .frame(width: 520)
    }

    private func test() async {
        testState = .testing
        let pw = isNew || passwordChanged ? password : (Keychain.password(for: config.id) ?? "")
        do {
            let conn = try await config.connect(password: pw)
            let version = conn.serverVersion
            await conn.close()
            testState = .ok("Connected · \(version)")
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func chooseFile(create: Bool) {
        if create {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "database.sqlite"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            config.filePath = url.path
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            config.filePath = url.path
        }
        if config.name.isEmpty { config.name = (config.filePath as NSString).lastPathComponent }
    }
}
