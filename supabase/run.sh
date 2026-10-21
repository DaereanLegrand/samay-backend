#!/usr/bin/env bash
set -euo pipefail

# Samay — Start self-hosted Supabase stack
cd "$(dirname "$0")"

source .env 2>/dev/null || true
bash ../tools/check-stack-env.sh .env

STACK_PREFIX="${STACK_PREFIX:-samay}"
echo "Starting Samay Supabase stack ($STACK_PREFIX)..."
docker compose -p "$STACK_PREFIX" --env-file .env up -d --wait

echo ""
echo "Samay Supabase is running:"
echo "  API Gateway:    http://localhost:${KONG_HTTP_PORT:-54386}"
echo "  Studio:          http://localhost:${STUDIO_PORT:-54381}"
echo "  Database:        postgres://postgres:postgres@localhost:${POSTGRES_PORT:-54382}/postgres"
echo "  Mailpit (dev):   http://localhost:${MAILPIT_PORT:-54384}"
echo ""
echo "To stop:  docker compose down"
