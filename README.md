# DBIDE

[![CI](https://github.com/lai3d/database-ide/actions/workflows/ci.yml/badge.svg)](https://github.com/lai3d/database-ide/actions/workflows/ci.yml)

A native macOS database IDE in the spirit of JetBrains DataGrip, written in Swift (SwiftUI + AppKit) with no third-party dependencies.
Supports **PostgreSQL, MySQL/MariaDB, SQLite and MongoDB**.

> Early but usable: connects, browses, queries and edits data on real servers.

## Features

- **Data sources**: SQLite, PostgreSQL, MySQL/MariaDB, MongoDB. All wire protocols are implemented in Swift
  (PostgreSQL SCRAM-SHA-256/MD5, MySQL caching_sha2_password/native_password). Passwords live in the Keychain.
  TLS with libpq-style modes (disable / prefer / require / verify-ca / verify-full) and an optional root CA.
  SSH tunnels through the system `ssh`. Paste a connection URL (`postgres://…`, `jdbc:mysql://…`, a `.db` path) to fill the form.
- **Database Explorer**: data sources → schemas → tables / views / routines → columns (PK, type, nullability) and indexes.
  Filter box, context menus (open data, show DDL, SELECT in console, copy names, drop).
- **Query console**: SQL highlighting, line numbers, ⌘↩ runs the statement at the caret (or the selection),
  ⇧⌘↩ runs the whole script, ⌘. cancels (PostgreSQL CancelRequest, MySQL `KILL QUERY`, `sqlite3_interrupt`).
  The running statement is highlighted and errors are underlined at the server-reported position.
  Per-console schema switcher and row limit. Each console has its own session.
- **Completion popup** while typing (or ⌃Space / Esc, or after `.`): context-aware — tables after FROM/JOIN,
  columns of the statement's tables in SELECT/WHERE, `alias.` / `schema.` resolution, quoting when needed.
- **Result grid**: one tab per result set, NULL styling, client-side sort, value viewer (pretty JSON),
  copy rows as TSV/CSV/JSON/Markdown/INSERT, export to file.
- **Table editor**: WHERE / ORDER BY filters, paging, row count; edit cells, set NULL, add/delete rows, preview the
  generated SQL and submit it in one transaction (tables with a primary key).
- **MongoDB**: mongosh-style console (`db.coll.find({...}).sort(...)`, aggregate, CRUD, indexes, `show dbs`, `use`),
  completion for collections / methods / fields / `$` operators, grid + JSON results, collection browser with editing,
  explain plans, `mongodb+srv://` connection strings.
- **Transactions**: Auto / Manual commit per console, Commit (⇧⌘K) / Rollback, open-transaction indicator.
- **Formatter** (⌥⌘L) for the selection or the whole console.
- **DDL viewer**, **query history** (⇧⌘E), consoles and their text persist across launches.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)

## Build & run

```sh
swift run DBIDE
swift test                    # unit tests + SQLite
./scripts/test-servers.sh     # also runs PostgreSQL/MySQL driver tests against docker containers
./scripts/bundle.sh           # build build/DBIDE.app (with icon; VERSION=1.2.3 to override)
swift scripts/make-icon.swift # regenerate Resources/AppIcon.icns
```

Pushing a `v*` tag builds the app on GitHub Actions and attaches a zip to a GitHub release
(ad-hoc signed, not notarized — right-click → Open the first time).

## Limitations

- TLS is limited to TLS 1.2 (SecureTransport); servers that only accept TLS 1.3 won't connect yet.
- SSH tunnels need key or agent auth (no SSH passwords); text-protocol results only.

See [ROADMAP.md](ROADMAP.md) for what is done and what is next.

Sibling projects: [golang-ide](https://github.com/lai3d/golang-ide).
