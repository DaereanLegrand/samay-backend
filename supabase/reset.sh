#!/usr/bin/env bash
set -euo pipefail

# Samay — Reset self-hosted Supabase (destroy data, re-create)
cd "$(dirname "$0")"

echo "WARNING: This will destroy all data in the Samay Supabase database!"
read -rp "Type 'reset' to confirm: " confirm
if [ "$confirm" != "reset" ]; then
  echo "Aborted."
  exit 1
fi

echo "Stopping stack..."
docker compose down

echo "Removing database and storage volumes..."
rm -rf volumes/db/data volumes/storage

echo "Starting fresh stack..."
docker compose up -d --wait

echo "Running migrations..."
for f in migrations/*.sql; do
  echo "  Applying $(basename "$f")..."
  PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -f "$f"
done

echo "Applying seed data..."
PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -f seed.sql

echo "Samay Supabase has been reset."
