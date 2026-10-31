#!/usr/bin/env bash
# Starts throwaway PostgreSQL and MySQL containers and runs the full test suite against them.
set -euo pipefail
cd "$(dirname "$0")/.."

docker rm -f dbide-pg dbide-mysql >/dev/null 2>&1 || true
docker run -d --name dbide-pg -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=dbide -p 55432:5432 postgres:16-alpine >/dev/null
docker run -d --name dbide-mysql -e MYSQL_ROOT_PASSWORD=secret -e MYSQL_DATABASE=dbide -p 53306:3306 mysql:8.4 >/dev/null

echo "Waiting for servers…"
until docker exec dbide-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
until docker exec dbide-mysql mysql -uroot -psecret -e 'select 1' >/dev/null 2>&1; do sleep 1; done

DBIDE_PG=localhost:55432:postgres:secret:dbide \
DBIDE_MYSQL=127.0.0.1:53306:root:secret:dbide \
  swift test "$@"
