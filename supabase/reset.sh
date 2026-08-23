#!/usr/bin/env bash
set -euo pipefail

# Samay — Reset self-hosted Supabase (destroy data, re-create): baseline
# migrations + REQUIRED seed-config.sql. Result = fully functional schema +
# app config with ZERO user/test data (user directive 2026-08-23).
# Test data is explicit only: `make supabase-seed-test`.
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
rm -rf volumes/storage
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2)"
PROJECT="${PROJECT:-samay}"
docker volume rm "${PROJECT}_db-data" "${PROJECT}_minio-data" 2>/dev/null || true

echo "Starting fresh stack..."
docker compose up -d --wait

export PGPASSWORD="${PGPASSWORD:-postgres}"
DB_URL="postgres://postgres:postgres@localhost:${POSTGRES_PORT:-54382}/postgres"
bash ../tools/apply_migrations.sh "$(basename "$(pwd)")"

echo "Applying required seed-config.sql (idempotent, no user data)..."
psql "$DB_URL" -v ON_ERROR_STOP=1 -f seed-config.sql

echo "Samay Supabase has been reset."
