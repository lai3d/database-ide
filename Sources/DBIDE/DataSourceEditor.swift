import AppKit
import DBIDECore
import SwiftUI
import UniformTypeIdentifiers

struct DataSourceEditor: View {
    @Environment(AppModel.self) private var app
    @State var config: DataSourceConfig
    let isNew: Bool
    /// Password handed over with the request (a `dbide://connect` link).
    var initialPassword: String?
    @State private var password = ""
    @State private var passwordChanged = false
    @State private var testState: TestState = .idle
    @State private var url = ""
    @State private var urlError = false

    enum TestState: Equatable {
        case idle, testing, ok(String), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Data Source" : "Data Source Properties")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
                .onAppear {
                    if let initialPassword, !passwordChanged {
                        password = initialPassword
                        passwordChanged = true
                    }
                }
            Form {
                if isNew {
                    HStack {
                        TextField("URL", text: $url, prompt: Text("postgres://user:pass@host:5432/db, jdbc:mysql://…, ~/app.db"))
                            .onSubmit(applyURL)
                        Button("Apply", action: applyURL).disabled(url.isEmpty)
                    }
                    if urlError {
                        Text("Unrecognized connection string").font(.caption).foregroundStyle(.red)
                    }
                }
                Picker("Driver", selection: $config.dialect) {
                    ForEach(SQLDialect.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: config.dialect) { old, new in
                    if config.port == old.defaultPort || config.port == 0 { config.port = new.defaultPort }
                    if [.mongodb, .redis, .clickhouse].contains(new), config.sslMode == .prefer { config.sslMode = .disable }
                }
                TextField("Name", text: $config.name, prompt: Text(config.displayName))
                HStack {
                    TextField("Folder", text: $config.folder, prompt: Text("none"))
                    if !app.folders.isEmpty {
                        Menu {
                            ForEach(app.folders, id: \.self) { f in Button(f) { config.folder = f } }
                        } label: { Image(systemName: "folder") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }

                if config.dialect == .sqlite {
                    HStack {
                        TextField("File", text: $config.filePath, prompt: Text("~/data/app.db"))
                        Button("Choose…") { chooseFile(create: false) }
                        Button("New…") { chooseFile(create: true) }
                    }
                } else {
                    if config.dialect == .mongodb {
                        Toggle("DNS seed list (mongodb+srv)", isOn: $config.srv)
                    }
                    HStack {
                        TextField(config.srv ? "Cluster" : "Host", text: $config.host,
                                  prompt: Text(config.srv ? "cluster0.xxxx.mongodb.net" : "localhost"))
                        if !(config.dialect == .mongodb && config.srv) {
                            TextField("Port", value: $config.port, format: .number.grouping(.never))
                                .frame(width: 110)
                        }
                    }
                    TextField("User", text: $config.user, prompt: Text(config.dialect == .redis ? "default (optional, ACL)" : ""))
                    SecureField("Password", text: $password, prompt: Text(isNew || passwordChanged ? "" : "•••••• (stored in Keychain)"))
                        .onChange(of: password) { passwordChanged = true }
                    TextField("Database", text: $config.database,
                              prompt: Text(config.dialect == .mysql ? "optional" : config.dialect == .mongodb ? "test" : config.dialect == .redis ? "0" : config.dialect == .clickhouse ? "default" : config.dialect == .sqlserver ? "master" : config.user))
                    if config.dialect == .mongodb {
                        TextField("Auth source", text: $config.authSource, prompt: Text("admin"))
                    }
                }
                if config.dialect != .sqlite {
                    Section("SSH Tunnel") {
                        Toggle("Connect through SSH", isOn: $config.ssh.enabled)
                        if config.ssh.enabled {
                            HStack {
                                TextField("SSH host", text: $config.ssh.host, prompt: Text("bastion.example.com"))
                                TextField("Port", value: $config.ssh.port, format: .number.grouping(.never))
                                    .frame(width: 110)
                            }
                            TextField("SSH user", text: $config.ssh.user, prompt: Text(NSUserName()))
                            HStack {
                                TextField("Private key", text: $config.ssh.keyPath, prompt: Text("SSH agent / ~/.ssh defaults"))
                                Button("Choose…") { chooseKey() }
                            }
                            Text("Host and port above are resolved from the SSH server. Keys with a passphrase must be added to the SSH agent (ssh-add).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("SSL / TLS") {
                        Picker("Mode", selection: $config.sslMode) {
                            ForEach(SSLMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text(sslHelp).font(.caption).foregroundStyle(.secondary)
                        if config.sslMode == .verifyCA || config.sslMode == .verifyFull {
                            HStack {
                                TextField("Root CA", text: $config.sslRootCert, prompt: Text("system trust store"))
                                Button("Choose…") { chooseRootCert() }
                            }
                        }
                    }
                }
                Section("Safety") {
                    Picker("Color", selection: Binding(
                        get: { DataSourceColor(rawValue: config.color ?? "") ?? .none },
                        set: { config.color = $0 == .none ? nil : $0.rawValue })
                    ) {
                        ForEach(DataSourceColor.allCases) { c in
                            HStack {
                                if let color = c.color {
                                    Image(systemName: "circle.fill").foregroundStyle(color)
                                }
                                Text(c.title)
                            }
                            .tag(c)
                        }
                    }
                    Toggle("Confirm before modifying data", isOn: $config.confirmWrites)
                    Toggle("Read-only", isOn: $config.readOnly)
                    Text("Tip: mark production red and turn on confirmation.").font(.caption).foregroundStyle(.secondary)
                }
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

    private var sslHelp: String {
        switch config.sslMode {
        case .disable: "Never encrypt the connection."
        case .prefer where [.mongodb, .redis, .clickhouse].contains(config.dialect):
            "\(config.dialect.displayName) has no TLS negotiation: Prefer connects without TLS. Use Require for TLS."
        case .prefer: "Encrypt when the server supports it; certificate not checked."
        case .require: "Always encrypt; certificate not checked."
        case .verifyCA: "Always encrypt; certificate must chain to a trusted root."
        case .verifyFull: "Always encrypt; certificate must be trusted and match the host name."
        }
    }

    private func applyURL() {
        guard let parsed = ConnectionURL.parse(url) else {
            urlError = true
            return
        }
        urlError = false
        var c = parsed.config
        c.id = config.id
        c.name = config.name.isEmpty ? c.name : config.name
        config = c
        if let pw = parsed.password {
            password = pw
            passwordChanged = true
        }
        testState = .idle
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.ssh.keyPath = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseRootCert() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a PEM file with the root certificate(s)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.sslRootCert = url.path
    }

    private func test() async {
        testState = .testing
        let pw = isNew || passwordChanged ? password : (Keychain.password(for: config.id) ?? "")
        do {
            let conn = try await config.connect(password: pw)
            let version = conn.serverVersion
            let tls = conn.securityDescription.map { " · 🔒 \($0)" } ?? (config.dialect == .sqlite ? "" : " · not encrypted")
            await conn.close()
            testState = .ok("Connected · \(version)\(tls)")
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
