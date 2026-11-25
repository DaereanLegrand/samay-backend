#!/usr/bin/env bash
set -euo pipefail

# Samay — Start self-hosted Supabase stack
#
# The env file lives at the repo root (.env/testing-local.env) exactly as the
# Makefile resolves it. Override with ENV_FILE.
cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-../.env/testing-local.env}"

source "$ENV_FILE" 2>/dev/null || true
bash ../tools/check-stack-env.sh "$ENV_FILE"

STACK_PREFIX="${STACK_PREFIX:-samay}"
echo "Starting Samay Supabase stack ($STACK_PREFIX)..."
docker compose -p "$STACK_PREFIX" --env-file "$ENV_FILE" up -d --wait

echo ""
echo "Samay Supabase is running:"
echo "  API Gateway:    http://localhost:${KONG_HTTP_PORT:-54396}"
echo "  Studio:          http://localhost:${STUDIO_PORT:-54391}"
echo "  Database:        postgres://postgres:postgres@localhost:${POSTGRES_PORT:-54392}/postgres"
echo "  Mailpit (dev):   http://localhost:${MAILPIT_PORT:-54394}"
echo ""
echo "To stop:  docker compose down"
