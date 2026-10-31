// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DBIDE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DBIDE", targets: ["DBIDE"]),
        .library(name: "DBIDECore", targets: ["DBIDECore"]),
    ],
    targets: [
        // UI-independent pieces: wire-protocol drivers (SQLite, PostgreSQL, MySQL),
        // SQL lexer/splitter, introspection, export.
        .target(name: "DBIDECore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "DBIDE", dependencies: ["DBIDECore"]),
        .testTarget(name: "DBIDECoreTests", dependencies: ["DBIDECore"]),
    ]
)
