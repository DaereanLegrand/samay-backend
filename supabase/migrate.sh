#!/usr/bin/env bash
set -euo pipefail

# Samay — Run the baseline migrations + required config against self-hosted
# Supabase (MSQ-01: feature-organized tree via tools/apply_migrations.sh,
# then seed-config.sql).
#
# USER DIRECTIVE (2026-08-23): seed-config.sql is FUNDAMENTAL app config and
# is applied AUTOMATICALLY here. It contains NO user data. Test data is a
# separate explicit step: `make seed` — never automatic.
#
# The env file lives at the repo root (.env/testing-local.env) exactly as the
# Makefile resolves it. Override with ENV_FILE.
cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-../.env/testing-local.env}"

# Load only simple KEY=VAL lines from the env file — never `source` it whole
# (values may contain spaces/UTF-8 that are fine for docker compose but not for
# the shell; sourcing used to fail with 'command not found' and abort the run).
if [ -r "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      '' | '#'* | *' '* | *'-'*) continue ;;
    esac
    value="${value%\"}"; value="${value#\"}"
    export "$key=$value" 2>/dev/null || true
  done < "$ENV_FILE"
fi

bash ../tools/check-stack-env.sh "$ENV_FILE"

DB_URL="${DB_URL:-postgres://postgres:postgres@localhost:${POSTGRES_PORT:-54392}/postgres}"

echo "Running baseline migrations against $DB_URL..."
bash ../tools/apply_migrations.sh "$(basename "$(pwd)")"

echo "Applying required seed-config.sql (idempotent, no user data)..."
PGPASSWORD="${PGPASSWORD:-postgres}" psql "$DB_URL" -v ON_ERROR_STOP=1 \
  -f seed-config.sql

echo "Migrations complete."
