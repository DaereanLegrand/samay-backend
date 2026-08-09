#!/usr/bin/env bash
set -euo pipefail

# Samay — Run database migrations against self-hosted Supabase
cd "$(dirname "$0")"

source .env 2>/dev/null || true

DB_URL="${DB_URL:-postgres://postgres:postgres@localhost:54382/postgres}"

echo "Running migrations against $DB_URL..."

for f in migrations/*.sql; do
  echo "  Applying $(basename "$f")..."
  psql "$DB_URL" -f "$f"
done

echo "Applying seed data (idempotent)..."
psql "$DB_URL" -f seed.sql

echo "Migrations complete."
