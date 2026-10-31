# DBIDE

A native macOS database IDE in the spirit of JetBrains DataGrip, written in Swift (SwiftUI + AppKit) with no third-party dependencies.

> Early but usable: connects, browses, queries and edits data on real servers.

## Features

- **Data sources**: SQLite, PostgreSQL, MySQL/MariaDB. All wire protocols are implemented in Swift
  (PostgreSQL SCRAM-SHA-256/MD5, MySQL caching_sha2_password/native_password). Passwords live in the Keychain.
- **Database Explorer**: data sources → schemas → tables / views / routines → columns (PK, type, nullability) and indexes.
  Filter box, context menus (open data, show DDL, SELECT in console, copy names, drop).
- **Query console**: SQL highlighting, line numbers, ⌘↩ runs the statement at the caret (or the selection),
  ⇧⌘↩ runs the whole script, ⌘. cancels (PostgreSQL CancelRequest, MySQL `KILL QUERY`, `sqlite3_interrupt`).
  The running statement is highlighted and errors are underlined at the server-reported position.
  Per-console schema switcher and row limit. Each console has its own session.
- **Completion** (⌃Space / Esc, or after `.`): keywords, tables, columns of tables in the statement, `alias.` columns.
- **Result grid**: one tab per result set, NULL styling, client-side sort, value viewer (pretty JSON),
  copy rows as TSV/CSV/JSON/Markdown/INSERT, export to file.
- **Table editor**: WHERE / ORDER BY filters, paging, row count; edit cells, set NULL, add/delete rows, preview the
  generated SQL and submit it in one transaction (tables with a primary key).
- **DDL viewer**, **query history** (⇧⌘E), consoles and their text persist across launches.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)

## Build & run

```sh
swift run DBIDE
swift test                    # unit tests + SQLite
./scripts/test-servers.sh     # also runs PostgreSQL/MySQL driver tests against docker containers
./scripts/bundle.sh           # build build/DBIDE.app
```

## Limitations

- No TLS yet: servers must accept unencrypted connections (`sslmode=disable` equivalent).
- No SSH tunnels; text-protocol results only.

Sibling projects: [golang-ide](https://github.com/lai3d/golang-ide).
