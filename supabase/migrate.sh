#!/usr/bin/env bash
set -euo pipefail

# Samay — Run database migrations against self-hosted Supabase
# SEED_DEV=1 additionally applies seed-dev.sql (DEMO data, agent I-75) after
# the production seed. Off by default — the production seed stays clean:
#   SEED_DEV=1 bash migrate.sh
cd "$(dirname "$0")"

# Load only simple KEY=VAL lines from .env — never `source` it whole (values
# may contain spaces/UTF-8 that are fine for docker compose but not for the
# shell; sourcing used to fail with 'command not found' and abort the run).
if [ -r .env ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      '' | '#'* | *' '* | *'-'*) continue ;;
    esac
    value="${value%\"}"; value="${value#\"}"
    export "$key=$value" 2>/dev/null || true
  done < .env
fi

DB_URL="${DB_URL:-postgres://postgres:postgres@localhost:54382/postgres}"
SEED_DEV="${SEED_DEV:-0}"

echo "Running migrations against $DB_URL..."

for f in migrations/*.sql; do
  echo "  Applying $(basename "$f")..."
  psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"
done

echo "Applying seed data (idempotent)..."
psql "$DB_URL" -v ON_ERROR_STOP=1 -f seed.sql

if [ "$SEED_DEV" = "1" ]; then
  echo "Applying dev/demo seed data (SEED_DEV=1)..."
  psql "$DB_URL" -f seed-dev.sql
fi

echo "Migrations complete."
