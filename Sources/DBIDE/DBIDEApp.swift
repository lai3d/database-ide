import AppKit
import DBIDECore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) { model?.saveNow() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DBIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("DBIDE") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Menu("New Data Source") {
                    ForEach(SQLDialect.allCases, id: \.self) { d in
                        Button(d.displayName) { model.beginAddDataSource(d) }
                    }
                }
                Button("New Query Console") {
                    if let ds = model.activeDataSource ?? model.dataSources.first { model.newConsole(for: ds) }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.dataSources.isEmpty)
                Divider()
                Button("Close Tab") { model.closeSelectedTab() }
                    .keyboardShortcut("w")
                    .disabled(model.selectedTab == nil)
            }
            CommandMenu("Query") {
                Button("Execute") { console?.run(.caretOrSelection) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(console == nil)
                Button("Execute All") { console?.run(.all) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(console == nil)
                Button("Cancel") { console?.cancel() }
                    .keyboardShortcut(".")
                    .disabled(console?.isRunning != true)
                Divider()
                Button("Toggle Comment") {
                    NSApp.sendAction(#selector(SQLTextView.toggleComment(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("/")
                Button("Show History") { model.showHistory.toggle() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }

    private var console: ConsoleModel? {
        if case .console(let c) = model.selectedTab { return c }
        return nil
    }
}
