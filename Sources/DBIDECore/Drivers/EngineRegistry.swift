import Foundation

/// Introspection for engines whose drivers live in their own files (SQL Server, Redis).
func engineIntrospection(for connection: any DatabaseConnection) -> (any EngineIntrospection)? {
    nil
}
