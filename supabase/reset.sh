#!/usr/bin/env bash
set -euo pipefail

# Samay — Reset self-hosted Supabase (destroy data, re-create)
# SEED_DEV=1 additionally applies seed-dev.sql (DEMO data, agent I-75) after
# the production seed. Off by default — the production seed stays clean:
#   SEED_DEV=1 bash reset.sh
cd "$(dirname "$0")"

SEED_DEV="${SEED_DEV:-0}"

echo "WARNING: This will destroy all data in the Samay Supabase database!"
read -rp "Type 'reset' to confirm: " confirm
if [ "$confirm" != "reset" ]; then
  echo "Aborted."
  exit 1
fi

echo "Stopping stack..."
docker compose down

echo "Removing database and storage volumes..."
rm -rf volumes/storage
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2)"
PROJECT="${PROJECT:-samay}"
docker volume rm "${PROJECT}_db-data" "${PROJECT}_minio-data" 2>/dev/null || true

echo "Starting fresh stack..."
docker compose up -d --wait

echo "Running migrations..."
for f in migrations/*.sql; do
  echo "  Applying $(basename "$f")..."
  PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -f "$f"
done

echo "Applying seed data..."
PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -f seed.sql

if [ "$SEED_DEV" = "1" ]; then
  echo "Applying dev/demo seed data (SEED_DEV=1)..."
  PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -f seed-dev.sql
fi

echo "Samay Supabase has been reset."
