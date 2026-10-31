import Foundation

/// Introspection for engines whose drivers live in their own files (SQL Server, Redis).
func engineIntrospection(for connection: any DatabaseConnection) -> (any EngineIntrospection)? {
    if let r = connection as? RedisConnection { return RedisIntrospection(c: r) }
    if let m = connection as? SQLServerConnection { return SQLServerIntrospection(c: m) }
    return nil
}
