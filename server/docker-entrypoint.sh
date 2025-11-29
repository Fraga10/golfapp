#!/bin/sh
set -e

# Simple entrypoint: wait for DB, run migrations, then start server
: "DB_HOST=${DB_HOST:-db}"
: "DB_PORT=${DB_PORT:-5432}"
: "DB_USER=${DB_USER:-golfe_user}"
: "DB_PASS=${DB_PASS:-golfepass}"
: "PORT=${PORT:-8080}"

echo "Entrypoint: waiting for DB at ${DB_HOST}:${DB_PORT} (if using external DB set DB_HOST in .env)"

# If DB_HOST is reachable via pg_isready (container has postgres client?), try loop with tcp
# Use dart to run migrations; first wait for TCP port
wait_for_tcp() {
  host="$1"
  port="$2"
  n=0
  while ! (echo > /dev/tcp/$host/$port) >/dev/null 2>&1; do
    n=$((n+1))
    if [ $n -ge 60 ]; then
      echo "Timed out waiting for $host:$port"
      return 1
    fi
    sleep 1
  done
  return 0
}

if [ "$DB_HOST" = "db" ]; then
  # Wait for DB service in compose
  if ! wait_for_tcp "$DB_HOST" "$DB_PORT"; then
    echo "DB did not become available; continuing anyway"
  fi
else
  echo "Using external DB host: $DB_HOST"
fi

# Ensure dependencies are fetched
echo "Running 'dart pub get'"
dart pub get || true

# Run migrations if migrate script exists
if [ -f bin/migrate.dart ]; then
  echo "Running migrations"
  dart run bin/migrate.dart || echo "Migrations failed (non-fatal)"
fi

# Start server
echo "Starting server on port $PORT"
exec dart run bin/server.dart
