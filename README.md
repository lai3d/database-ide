# DBIDE

A native macOS database IDE in the spirit of JetBrains DataGrip, written in Swift (SwiftUI + AppKit) with no third-party dependencies.

> Work in progress — early scaffold.

## Planned features

- Data sources: SQLite, PostgreSQL, MySQL (wire protocols implemented in Swift; passwords in Keychain)
- Database Explorer tree: schemas → tables / views → columns, indexes
- Query console with SQL highlighting; ⌘↩ runs the statement at the caret (or the selection)
- Result grid: NULL rendering, sorting, copy as TSV/CSV, export CSV
- Table data view with WHERE / ORDER BY filters and paging
- DDL viewer, query cancellation, query history

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)

## Build & run

```sh
swift run DBIDE
swift test
./scripts/bundle.sh      # build build/DBIDE.app
```

Sibling projects: [golang-ide](https://github.com/lai3d/golang-ide).
