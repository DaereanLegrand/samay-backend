#!/usr/bin/env bash
# =============================================================================
# apply_migrations.sh — two-tier baseline applier (MSQ-01, 2026-08-22).
#
# Single source of truth for applying the feature-organized baseline tree
# (<stack>/migrations/<NNN_domain>/*.sql). Used by supabase*/migrate.sh,
# supabase*/reset.sh and the Makefile init/reset targets so the flows can't
# drift apart.
#
# Two tiers:
#   * normal files        → host psql as role `postgres` (approved port map)
#   * *_privileged.sql    → `docker compose exec db psql -U supabase_admin`
#     Files that must touch platform-owned objects (storage.objects RLS) run
#     inside the db container as the bootstrap superuser — the storage service
#     role owns those objects and plain `postgres` cannot attach policies to
#     them (this exact permission gap silently broke fresh inits before MSQ-01;
#     Makefile loops swallowed the error).
#
# Ordering: `find | LC_ALL=C sort` — numeric dir prefixes (010_…, 020_…) then
# filenames sort byte-identically everywhere.
#
# Usage: tools/apply_migrations.sh <supabase|supabase-testing>
# Exit 0 on success; any failed statement aborts (ON_ERROR_STOP=1).
# =============================================================================
set -euo pipefail

STACK="${1:?usage: apply_migrations.sh <supabase|supabase-testing>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/$STACK"

POSTGRES_PORT_VAL="${POSTGRES_PORT:-54382}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
DB_URL="${DB_URL:-postgres://postgres:postgres@localhost:${POSTGRES_PORT_VAL}/postgres}"

# Privileged tier target: the stack's db container (compose container_name is
# fixed per stack; override with DB_CONTAINER when testing scratch projects).
case "$STACK" in
  supabase)          DB_CONTAINER="${DB_CONTAINER:-samay-db}" ;;
  supabase-testing)  DB_CONTAINER="${DB_CONTAINER:-samay-testing-db}" ;;
  *)                 DB_CONTAINER="${DB_CONTAINER:?DB_CONTAINER required for $STACK}" ;;
esac

# Storage-schema readiness gate. The storage schema (buckets/objects tables +
# RLS) is NOT created by the db image's initdb — storage-api creates it at its
# own startup (M-12: the postgres image ships a MINIMAL storage schema; the
# tenant migrations live in the storage-api service). A fresh volume therefore
# has no `storage.buckets` until storage-api has bootstrapped, and the
# *_privileged.sql tier (950_storage/storage_buckets_privileged.sql) inserts
# bucket rows + attaches RLS policies to it. So wait for the table before the
# privileged tier runs — otherwise a fresh reset dies with PGRST-adjacent
# `relation "storage.buckets" does not exist`. Uses the same db container the
# privileged tier execs into; `docker exec` is the only client with the
# storage-role-owned schema visible.
wait_for_storage_schema() {
  echo "  Waiting for storage-api schema (storage.buckets)..."
  for i in $(seq 1 60); do
    if docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -tAc \
        "SELECT to_regclass('storage.buckets') IS NOT NULL" </dev/null 2>/dev/null | grep -q 't'; then
      echo "  storage.buckets present."
      return 0
    fi
    sleep 2
  done
  echo "  ERROR: storage.buckets still absent after 120s — is the storage-api container up?" >&2
  return 1
}

APPLIED=0
while IFS= read -r f; do
  echo "  Applying ${f#migrations/}..."
  case "$f" in
    *_privileged.sql)
      wait_for_storage_schema
      docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres \
        -v ON_ERROR_STOP=1 -q < "$f" ;;
    *)
      psql "$DB_URL" -v ON_ERROR_STOP=1 -qf "$f" ;;
  esac
  APPLIED=$((APPLIED + 1))
done < <(find migrations -type f -name '*.sql' | LC_ALL=C sort)

echo "  ${APPLIED} baseline file(s) applied."
