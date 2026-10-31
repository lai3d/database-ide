import Foundation

/// Connections that can keep a read-only result open on the server and page through it.
/// One cursor per connection; running anything else on the connection closes it.
public protocol CursorCapable: DatabaseConnection {
    /// Runs `sql` and returns the first `pageSize` rows; `truncated` means more rows are available.
    func openCursor(_ sql: String, pageSize: Int) async throws -> QueryResult
    /// Next rows of the open cursor; `hasMore` is false once it is exhausted (and closed).
    func fetchMore(_ count: Int) async throws -> (rows: [[SQLValue]], hasMore: Bool)
    var hasOpenCursor: Bool { get }
    func closeCursor() async
}
