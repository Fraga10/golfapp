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
run_migrations() {
  if [ -f bin/migrate.dart ]; then
    echo "Running migrations"
    dart run bin/migrate.dart || echo "Migrations failed (non-fatal)"
  fi
}

# Start the server in foreground (child process) so we can restart it
start_server() {
  echo "Starting server on port $PORT"
  dart run bin/server.dart &
  SERVER_PID=$!
  echo "Server PID: $SERVER_PID"
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    echo "Stopping server PID $SERVER_PID"
    kill "$SERVER_PID" || true
    wait "$SERVER_PID" || true
    SERVER_PID=""
  fi
}

# Git auto-update loop: periodically checks origin for new commits and pulls
# Controlled by environment variable GIT_AUTO_PULL=1 and interval GIT_PULL_INTERVAL (seconds)
git_auto_pull_loop() {
  if [ "${GIT_AUTO_PULL:-0}" != "1" ]; then
    return
  fi
  INTERVAL=${GIT_PULL_INTERVAL:-30}
  echo "Git auto-pull enabled: checking origin every ${INTERVAL}s"

  # Only proceed if .git exists and origin is configured
  if [ ! -d .git ]; then
    echo ".git directory not present; skipping auto-pull"
    return
  fi

  while true; do
    sleep $INTERVAL
    # Determine current branch
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -z "$BRANCH" ]; then
      echo "Could not determine current git branch; skipping check"
      continue
    fi
    # Fetch remote
    git fetch --quiet origin "$BRANCH" || { echo "git fetch failed"; continue; }
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/${BRANCH} 2>/dev/null || true)
    if [ -z "$REMOTE" ]; then
      echo "No remote ref for origin/${BRANCH}; skipping"
      continue
    fi
    if [ "$LOCAL" != "$REMOTE" ]; then
      echo "New commit detected on origin/${BRANCH}: $REMOTE (local $LOCAL)"
      echo "Pulling updates..."
      # Try a fast-forward pull, fallback to reset
      if git pull --ff-only origin "$BRANCH"; then
        echo "Pulled successfully (fast-forward)"
      else
        echo "Fast-forward failed, resetting to origin/${BRANCH}"
        git reset --hard origin/${BRANCH} || echo "Reset failed"
      fi
      # Run migrations after update
      run_migrations
      # Restart server
      echo "Restarting server to apply updates"
      stop_server
      start_server
    else
      echo "No updates on origin/${BRANCH}"
    fi
  done
}

# Trap signals so we can stop child cleanly
trap 'echo "Shutting down"; stop_server; exit 0' INT TERM

run_migrations
start_server
# Kick off git auto-pull loop in background (if enabled)
git_auto_pull_loop &

# Wait for the server process
wait $SERVER_PID
