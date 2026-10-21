#!/usr/bin/env bash
# Seed the store-reviewer account on STAGING ONLY.
#
# Requires SAMAY_ENV=staging and REVIEWER_PASSWORD (vault-generated, rotated per
# review cycle). The password is passed to psql as a variable and is never
# echoed or written to disk. Idempotent: a second run preserves the existing
# bcrypt hash.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "${SAMAY_ENV:-}" != "staging" ]; then
  echo "refusing: reviewer seed is staging-only (set SAMAY_ENV=staging)" >&2
  exit 1
fi
if [ -z "${REVIEWER_PASSWORD:-}" ]; then
  echo "refusing: REVIEWER_PASSWORD must be set" >&2
  exit 1
fi
if [ "${#REVIEWER_PASSWORD}" -lt 12 ]; then
  echo "refusing: REVIEWER_PASSWORD must be at least 12 characters" >&2
  exit 1
fi

STACK_ENV="${STACK_ENV:-$ROOT/supabase/.env}"
if [ -n "${DB_URL:-}" ]; then
  db_url="$DB_URL"
else
  db_port="54382"
  if [ -r "$STACK_ENV" ]; then
    parsed_port="$(awk -F= '/^POSTGRES_PORT=/{print $2; exit}' "$STACK_ENV")"
    [ -n "$parsed_port" ] && db_port="$parsed_port"
  fi
  db_url="postgres://postgres:postgres@127.0.0.1:${db_port}/postgres?sslmode=disable"
fi

PGPASSWORD="${PGPASSWORD:-postgres}" psql "$db_url" \
  -v ON_ERROR_STOP=1 -q \
  -v samay_env="$SAMAY_ENV" \
  -v reviewer_password="$REVIEWER_PASSWORD" \
  -f supabase/seed-reviewer-staging.sql

echo "reviewer seed applied (unchanged if already present)"
