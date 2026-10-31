# DBIDE Roadmap

Status: ✅ done · 🚧 in progress · ⬜ planned

Estimates are Claude Code session time.

## Done

- ✅ Package scaffold (`DBIDECore` library + `DBIDE` app), public repo, `scripts/bundle.sh`
- ✅ Drivers written in Swift, no dependencies:
  - PostgreSQL v3 protocol: cleartext / MD5 / SCRAM-SHA-256 auth, simple query, CancelRequest
  - MySQL protocol: native_password + caching_sha2_password (incl. RSA full auth), `KILL QUERY` cancel
  - SQLite via system libsqlite3, `sqlite3_interrupt` cancel
- ✅ SQL lexer (highlighting) and statement splitter (dollar quotes, nested comments, trigger bodies, MySQL `DELIMITER`)
- ✅ Introspection: schemas, tables / views, columns, indexes, routines, DDL (all three dialects)
- ✅ Export: CSV / TSV / JSON / Markdown / SQL INSERT
- ✅ Tests: unit tests + docker-backed PostgreSQL 16 (TLS) / MySQL 8.4 / SSH bastion tests (`scripts/test-servers.sh`) — 56 tests

## Phase 1 — Core IDE (MVP)

| # | Item | Notes | Est. |
|---|---|---|---|
| 1.1 | ✅ Data sources | Add / edit / duplicate / delete, Test Connection, read-only mode, passwords in Keychain | 0.4h |
| 1.2 | ✅ Database Explorer | Data source → schema → tables / views / routines → columns + indexes, filter, context menus | 0.6h |
| 1.3 | ✅ Query console | Highlighting, line numbers, ⌘↩ statement at caret / selection, ⇧⌘↩ run all, ⌘. cancel, schema switcher, row limit, own session per console | 0.7h |
| 1.4 | ✅ Error feedback | Running statement highlighted; server error position underlined; Output log | 0.2h |
| 1.5 | ✅ Result grid | Tab per result set, NULL styling, sort, value viewer (pretty JSON), copy as TSV/CSV/JSON/Markdown/INSERT, export to file | 0.6h |
| 1.6 | ✅ Completion | Keywords, tables, columns, `alias.` columns (popup UI: see 3.1) | 0.3h |
| 1.7 | ✅ Table data view | WHERE / ORDER BY filters, paging, row count | 0.3h |
| 1.8 | ✅ Table data editing | Edit cells, set NULL, add / delete rows, preview SQL, submit in one transaction (rolled back unless every statement hits exactly one row); `TableEdits` in Core with unit + PG/MySQL/SQLite tests | 0.3h |
| 1.9 | ✅ DDL viewer, query history, persistence | History panel (⇧⌘E); consoles and their text survive restarts | 0.3h |

## Phase 2 — Connectivity

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ✅ TLS | PostgreSQL `SSLRequest` + MySQL SSL upgrade; modes disable / prefer (default) / require / verify-ca / verify-full, custom root CA; 🔒 in explorer, Test Connection and console log. Tested against TLS-enabled PG 16 and MySQL 8.4 | 0.6h |
| 2.1b | ⬜ TLS 1.3 | Current TLS layer is SecureTransport (TLS 1.2 max, deprecated by Apple); move to Network.framework with a STARTTLS framer | 0.8h |
| 2.2 | ✅ SSH tunnel | System `ssh -L` (agent or key file), shared per target, restarted if it dies, closed on quit; TLS inside the tunnel verifies the real DB host name. Tested through a docker sshd bastion | 0.4h |
| 2.3 | ✅ Connection URL import | Paste `postgres://`, `mysql://`, `jdbc:…`, `sqlite://` or a file path into the dialog; also reads sslmode / sslrootcert / useSSL | 0.2h |
| 2.4 | ⬜ More engines | MariaDB-specific tweaks, then maybe ClickHouse (HTTP) / SQL Server (TDS) | 1h+ each |

## Phase 3 — Editor & query power

| # | Item | Notes | Est. |
|---|---|---|---|
| 3.1 | ✅ Completion popup | Pops up while typing / after `.` / ⌃Space; icons for table, view, column, schema, alias, keyword; context-aware (tables after FROM/JOIN, columns in SELECT/WHERE), alias and `schema.` resolution, quotes names when needed, loads metadata lazily and refreshes. Engine in Core (`SQLCompletion`) with tests | 0.6h |
| 3.2 | ✅ SQL formatter | ⌥⌘L reformats the selection or the console: clause per line, aligned select list, AND/OR breaks (BETWEEN-aware), indented subqueries, upper-case keywords; only whitespace/keyword case change (tested for idempotence and token preservation) | 0.4h |
| 3.3 | ⬜ Bind parameters | Prompt for `?` / `:name` / `$1` values before running | 0.4h |
| 3.4 | ✅ Explain plan | ⌥⌘E / ⇧⌥⌘E (analyze) on the statement at the caret: PG JSON, MySQL TREE / EXPLAIN ANALYZE, SQLite QUERY PLAN → one tree with cost, estimated vs actual rows (misestimates flagged), self-time bars, raw view; ANALYZE of DML is rolled back | 0.5h |
| 3.5 | ✅ Transaction mode | Auto / Manual per console, Commit (⇧⌘K) / Rollback, "Transaction open" indicator driven by the server's own status (PG ReadyForQuery, MySQL status flags, SQLite autocommit) so a typed BEGIN is tracked too; prompt when closing a console with an open transaction | 0.4h |
| 3.6 | ⬜ Pinned results & paging in console | Keep result tabs across runs; fetch next page instead of a hard row limit | 0.5h |
| 3.7 | ⬜ SQL files | Open / save `.sql` files; run a file against a data source | 0.4h |

## Phase 4 — Schema tools

| # | Item | Notes | Est. |
|---|---|---|---|
| 4.1 | ⬜ Foreign keys & ER diagram | Show FKs in the tree; simple diagram of a schema | 1h |
| 4.2 | ⬜ Table designer | Create / alter table dialog that generates DDL | 1h |
| 4.3 | ⬜ Import data | CSV → table with column mapping | 0.6h |
| 4.4 | ✅ Go to table | ⌘O fuzzy-finds tables / views across data sources in use (loads their catalogs on open); ↩ opens data, ⌥↩ DDL | 0.3h |

## Phase 5 — Polish & release

| # | Item | Notes | Est. |
|---|---|---|---|
| 5.1 | ⬜ Settings | Fonts, default row limit, confirm-on-DML for read-write prod data sources | 0.4h |
| 5.2 | ⬜ Data source colors / folders | Color tag on tabs (e.g. red for production), grouping | 0.3h |
| 5.3 | ⬜ CI & packaging | GitHub Actions build + unit tests (+ docker service containers), app icon, release `.app` zip | 0.5h |

**User must do manually** (duration outside Claude's control): Apple Developer Program enrollment,
Developer ID certificate, notarization credentials — only needed to ship a signed/notarized build to others.

## Later / ideas

- Binary protocol / extended query for typed values and server-side cursors
- Grid cell selection (not just rows), column filters, transpose view
- Diff two result sets or two schemas
- AI assist: explain / write SQL from the schema in context
