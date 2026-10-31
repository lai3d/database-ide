import DBIDECore
import Foundation
import Observation

/// Lazily loaded catalog for one schema.
@MainActor @Observable
final class SchemaNode: Identifiable {
    let name: String
    var tables: [TableInfo]?
    var routines: [RoutineInfo] = []
    var columns: [String: [ColumnInfo]] = [:]
    var indexes: [String: [IndexInfo]] = [:]
    var isLoading = false
    var error: String?

    nonisolated var id: String { name }
    init(name: String) { self.name = name }
}

/// Explorer-side state of a data source: one metadata connection plus cached catalog.
/// Query consoles open their own connections so long queries never block the tree.
@MainActor @Observable
final class DataSourceSession {
    enum State: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    var config: DataSourceConfig
    private(set) var state: State = .disconnected
    private(set) var connection: (any DatabaseConnection)?
    private(set) var schemas: [SchemaNode] = []
    private(set) var defaultSchema: String?
    var serverVersion: String { connection?.serverVersion ?? "" }

    init(config: DataSourceConfig) { self.config = config }

    var isConnected: Bool { state == .connected }

    func connect() async {
        if case .connected = state { return }
        if case .connecting = state { return }
        state = .connecting
        do {
            let conn = try await config.connect(password: Keychain.password(for: config.id) ?? "")
            connection = conn
            state = .connected
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        let conn = connection
        connection = nil
        schemas = []
        state = .disconnected
        await conn?.close()
    }

    func refresh() async {
        guard let connection else { return }
        let intro = Introspector(connection)
        do {
            let names = try await intro.schemas()
            defaultSchema = try await intro.currentSchema()
            let old = Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0) })
            schemas = names.map { name in
                let node = SchemaNode(name: name)
                if old[name]?.tables != nil { Task { await self.loadSchema(node) } }
                return node
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func schema(named name: String) -> SchemaNode? { schemas.first { $0.name == name } }

    func loadSchema(_ node: SchemaNode, force: Bool = false) async {
        guard let connection, force || (node.tables == nil && !node.isLoading) else { return }
        node.isLoading = true
        defer { node.isLoading = false }
        let intro = Introspector(connection)
        do {
            node.tables = try await intro.tables(schema: node.name)
            node.routines = (try? await intro.routines(schema: node.name)) ?? []
            node.columns = [:]
            node.indexes = [:]
            node.error = nil
        } catch {
            node.error = error.localizedDescription
            node.tables = []
        }
    }

    func loadTable(_ table: TableInfo) async {
        guard let connection, let node = schema(named: table.schema), node.columns[table.name] == nil else { return }
        let intro = Introspector(connection)
        node.columns[table.name] = (try? await intro.columns(schema: table.schema, table: table.name)) ?? []
        node.indexes[table.name] = (try? await intro.indexes(schema: table.schema, table: table.name)) ?? []
    }

    func ddl(for table: TableInfo) async throws -> String {
        guard let connection else { throw DatabaseError("Not connected") }
        return try await Introspector(connection).ddl(for: table)
    }

    // MARK: Completion

    /// Table names in a schema (loading it if needed) for completion.
    func completionTables(schema: String?) async -> [TableInfo] {
        guard let name = schema ?? defaultSchema, let node = self.schema(named: name) else { return [] }
        if node.tables == nil { await loadSchema(node) }
        return node.tables ?? []
    }

    func completionColumns(schema: String?, table: String) async -> [ColumnInfo] {
        guard let name = schema ?? defaultSchema, let node = self.schema(named: name) else { return [] }
        if node.tables == nil { await loadSchema(node) }
        guard let info = node.tables?.first(where: { $0.name.caseInsensitiveCompare(table) == .orderedSame })
        else { return [] }
        await loadTable(info)
        return node.columns[info.name] ?? []
    }
}
