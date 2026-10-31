#!/usr/bin/env bash
# Starts throwaway PostgreSQL (with TLS) and MySQL containers and runs the full test suite against them.
set -euo pipefail
cd "$(dirname "$0")/.."

docker rm -f dbide-pg dbide-mysql >/dev/null 2>&1 || true
# PostgreSQL with a self-signed certificate for localhost (generated here; the image has no openssl).
# Plain connections are still allowed.
CERTS="$PWD/.build/test-certs"
mkdir -p "$CERTS"
openssl req -new -x509 -days 30 -nodes -newkey rsa:2048 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -addext "extendedKeyUsage=serverAuth" \
  -keyout "$CERTS/server.key" -out "$CERTS/server.crt" 2>/dev/null
docker run -d --name dbide-pg -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=dbide -p 55432:5432 \
  -v "$CERTS:/certs:ro" postgres:16-alpine \
  sh -c 'cp /certs/server.* /tmp/ && chown postgres /tmp/server.* && chmod 600 /tmp/server.key \
         && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key' >/dev/null
# MySQL 8.4 generates its own certificates and enables TLS by default.
docker run -d --name dbide-mysql -e MYSQL_ROOT_PASSWORD=secret -e MYSQL_DATABASE=dbide -p 53306:3306 mysql:8.4 >/dev/null

echo "Waiting for servers…"
until docker exec dbide-pg pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do sleep 1; done
until docker exec dbide-mysql mysql -uroot -psecret -e 'select 1' >/dev/null 2>&1; do sleep 1; done

DBIDE_PG=localhost:55432:postgres:secret:dbide \
DBIDE_PG_CA="$CERTS/server.crt" \
DBIDE_MYSQL=127.0.0.1:53306:root:secret:dbide \
  swift test "$@"
