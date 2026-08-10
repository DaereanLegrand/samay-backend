#!/usr/bin/env bash
set -euo pipefail

# Samay — Run database migrations against self-hosted Supabase
# SEED_DEV=1 additionally applies seed-dev.sql (DEMO data, agent I-75) after
# the production seed. Off by default — the production seed stays clean:
#   SEED_DEV=1 bash migrate.sh
cd "$(dirname "$0")"

source .env 2>/dev/null || true

DB_URL="${DB_URL:-postgres://postgres:postgres@localhost:54382/postgres}"
SEED_DEV="${SEED_DEV:-0}"

echo "Running migrations against $DB_URL..."

for f in migrations/*.sql; do
  echo "  Applying $(basename "$f")..."
  psql "$DB_URL" -f "$f"
done

echo "Applying seed data (idempotent)..."
psql "$DB_URL" -f seed.sql

if [ "$SEED_DEV" = "1" ]; then
  echo "Applying dev/demo seed data (SEED_DEV=1)..."
  psql "$DB_URL" -f seed-dev.sql
fi

echo "Migrations complete."
