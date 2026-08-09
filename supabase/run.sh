#!/usr/bin/env bash
set -euo pipefail

# Samay — Start self-hosted Supabase stack
cd "$(dirname "$0")"

source .env 2>/dev/null || true

echo "Starting Samay Supabase stack..."
docker compose up -d --wait

echo ""
echo "Samay Supabase is running:"
echo "  API Gateway:    http://localhost:54386"
echo "  Studio:          http://localhost:54381"
echo "  Database:        postgres://postgres:postgres@localhost:54382/postgres"
echo "  Mailpit (dev):   http://localhost:54384"
echo ""
echo "To stop:  docker compose down"
