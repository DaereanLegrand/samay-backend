#!/usr/bin/env bash
set -euo pipefail

# Samay — Reset self-hosted Supabase (destroy data, re-create): baseline
# migrations + REQUIRED seed-config.sql. Result = fully functional schema +
# app config with ZERO user/test data (user directive 2026-08-23).
# Test data is explicit only: `make seed`.
#
# The env file lives at the repo root (.env/testing-local.env) exactly as the
# Makefile resolves it. Override with ENV_FILE.
cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-../.env/testing-local.env}"

echo "WARNING: This will destroy all data in the Samay Supabase database!"
read -rp "Type 'reset' to confirm: " confirm
if [ "$confirm" != "reset" ]; then
  echo "Aborted."
  exit 1
fi

if [ -r "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      '' | '#'* | *' '* | *'-'*) continue ;;
    esac
    value="${value%\"}"; value="${value#\"}"
    export "$key=$value" 2>/dev/null || true
  done < "$ENV_FILE"
fi

STACK_PREFIX="${STACK_PREFIX:-samay}"
STORAGE_DIR="${STORAGE_DIR:-./volumes/storage}"

bash ../tools/check-stack-env.sh "$ENV_FILE"

echo "Stopping stack ($STACK_PREFIX)..."
docker compose -p "$STACK_PREFIX" --env-file "$ENV_FILE" down

echo "Removing database and storage volumes..."
rm -rf "$STORAGE_DIR"
docker volume rm "${STACK_PREFIX}_db-data" "${STACK_PREFIX}_rustfs-data" 2>/dev/null || true

echo "Starting fresh stack..."
docker compose -p "$STACK_PREFIX" --env-file "$ENV_FILE" up -d --wait

export PGPASSWORD="${PGPASSWORD:-postgres}"
DB_URL="postgres://postgres:postgres@localhost:${POSTGRES_PORT:-54392}/postgres"
bash ../tools/apply_migrations.sh "$(basename "$(pwd)")"

echo "Applying required seed-config.sql (idempotent, no user data)..."
psql "$DB_URL" -v ON_ERROR_STOP=1 -f seed-config.sql

echo "Samay Supabase has been reset."
