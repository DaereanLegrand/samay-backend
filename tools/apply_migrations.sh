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

APPLIED=0
while IFS= read -r f; do
  echo "  Applying ${f#migrations/}..."
  case "$f" in
    *_privileged.sql)
      docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres \
        -v ON_ERROR_STOP=1 -q < "$f" ;;
    *)
      psql "$DB_URL" -v ON_ERROR_STOP=1 -qf "$f" ;;
  esac
  APPLIED=$((APPLIED + 1))
done < <(find migrations -type f -name '*.sql' | LC_ALL=C sort)

echo "  ${APPLIED} baseline file(s) applied."
