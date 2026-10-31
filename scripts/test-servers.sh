#!/usr/bin/env bash
# Starts throwaway PostgreSQL (TLS), MySQL, MongoDB (+TLS), ClickHouse, Redis, SQL Server and SSH containers and runs the full test suite against them.
set -euo pipefail
cd "$(dirname "$0")/.."

docker rm -f dbide-pg dbide-mysql dbide-ssh dbide-mongo dbide-mongo-tls dbide-ch dbide-redis dbide-mssql >/dev/null 2>&1 || true
docker network create dbide-net >/dev/null 2>&1 || true
# PostgreSQL with a self-signed certificate for localhost (generated here; the image has no openssl).
# Plain connections are still allowed.
CERTS="$PWD/.build/test-certs"
mkdir -p "$CERTS"
openssl req -new -x509 -days 30 -nodes -newkey rsa:2048 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -addext "extendedKeyUsage=serverAuth" \
  -keyout "$CERTS/server.key" -out "$CERTS/server.crt" 2>/dev/null
docker run -d --name dbide-pg --network dbide-net -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=dbide -p 55432:5432 \
  -v "$CERTS:/certs:ro" postgres:16-alpine \
  sh -c 'cp /certs/server.* /tmp/ && chown postgres /tmp/server.* && chmod 600 /tmp/server.key \
         && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key' >/dev/null
# MySQL 8.4 generates its own certificates and enables TLS by default.
docker run -d --name dbide-mysql -e MYSQL_ROOT_PASSWORD=secret -e MYSQL_DATABASE=dbide -p 53306:3306 mysql:8.4 >/dev/null

# MongoDB 7 with auth.
docker run -d --name dbide-mongo -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=secret -p 57017:27017 mongo:7 >/dev/null

# TLS-only MongoDB (no auth) using the same self-signed certificate.
cat "$CERTS/server.key" "$CERTS/server.crt" > "$CERTS/mongo.pem"
docker run -d --name dbide-mongo-tls -p 57018:27017 -v "$CERTS:/certs:ro" mongo:7 \
  mongod --tlsMode requireTLS --tlsCertificateKeyFile /certs/mongo.pem --tlsCAFile /certs/server.crt \
         --tlsAllowConnectionsWithoutCertificates --bind_ip_all >/dev/null

# ClickHouse (HTTP), Redis (with password), SQL Server 2022 (amd64 image; runs under Rosetta on Apple Silicon).
docker run -d --name dbide-ch -e CLICKHOUSE_USER=default -e CLICKHOUSE_PASSWORD=secret -e CLICKHOUSE_DB=dbide \
  -p 58123:8123 --ulimit nofile=262144:262144 clickhouse/clickhouse-server:24.8 >/dev/null
docker run -d --name dbide-redis -p 56379:6379 redis:7.4 redis-server --requirepass secret >/dev/null
docker run -d --name dbide-mssql --platform linux/amd64 -e ACCEPT_EULA=Y -e 'MSSQL_SA_PASSWORD=Secret#12345' \
  -p 51433:1433 mcr.microsoft.com/mssql/server:2022-latest >/dev/null

# SSH bastion (key auth, TCP forwarding) on the same network: tunnel tests reach dbide-pg:5432 through it.
rm -f "$CERTS/ssh_key" "$CERTS/ssh_key.pub" "$CERTS/known_hosts"
ssh-keygen -q -t ed25519 -N "" -f "$CERTS/ssh_key"
docker run -d --name dbide-ssh --network dbide-net -p 52222:22 -v "$CERTS/ssh_key.pub:/key.pub:ro" alpine:3.20 \
  sh -c 'apk add --no-cache openssh >/dev/null && ssh-keygen -A >/dev/null \
         && adduser -D tunnel && echo "tunnel:$(head -c 12 /dev/urandom | base64)" | chpasswd >/dev/null \
         && mkdir -p /home/tunnel/.ssh && cp /key.pub /home/tunnel/.ssh/authorized_keys \
         && chown -R tunnel /home/tunnel/.ssh && chmod 700 /home/tunnel/.ssh && chmod 600 /home/tunnel/.ssh/authorized_keys \
         && exec /usr/sbin/sshd -D -e -o AllowTcpForwarding=yes -o PasswordAuthentication=no' >/dev/null

echo "Waiting for servers…"
until docker exec dbide-pg pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do sleep 1; done
until docker exec dbide-mysql mysql -uroot -psecret -e 'select 1' >/dev/null 2>&1; do sleep 1; done
until docker exec dbide-mongo mongosh -u root -p secret --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; do sleep 1; done
until docker logs dbide-mongo-tls 2>&1 | grep -q "Waiting for connections"; do sleep 1; done
until curl -sf -u default:secret 'http://127.0.0.1:58123/?query=SELECT+1' >/dev/null; do sleep 1; done
until docker logs dbide-mssql 2>&1 | grep -q "ready for client connections"; do sleep 2; done
until nc -z 127.0.0.1 52222 2>/dev/null && docker logs dbide-ssh 2>&1 | grep -q "Server listening"; do sleep 1; done

DBIDE_PG=localhost:55432:postgres:secret:dbide \
DBIDE_PG_CA="$CERTS/server.crt" \
DBIDE_SSH="127.0.0.1:52222:tunnel:$CERTS/ssh_key:$CERTS/known_hosts" \
DBIDE_MYSQL=127.0.0.1:53306:root:secret:dbide \
DBIDE_MONGO=127.0.0.1:57017:root:secret \
DBIDE_MONGO_TLS=localhost:57018 \
DBIDE_CLICKHOUSE=127.0.0.1:58123:default:secret:dbide \
DBIDE_REDIS=127.0.0.1:56379::secret \
DBIDE_MSSQL='127.0.0.1:51433:sa:Secret#12345:dbide' \
  swift test "$@"
