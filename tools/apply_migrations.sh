#!/usr/bin/env bash
# =============================================================================
# apply_migrations.sh — ledger-aware migration applier (MSQ-01, 2026-08-22;
# ledger added 2026-10-10).
#
# Single source of truth for applying the feature-organized tree
# (<stack>/migrations/<NNN_domain>/*.sql). Used by supabase*/migrate.sh,
# supabase*/reset.sh and the Makefile init/reset/start targets.
#
# RE-RUN SAFE: a ledger table records every applied file, so `make start` skips
# the baseline it already ran and only applies pending migrations. A pre-ledger
# database (schema present, ledger empty) must be ADOPTED once first — run
# `make migrate-adopt` (or `apply_migrations.sh <stack> adopt`) — which records
# the existing baseline WITHOUT re-running it. Fresh DBs (reset) never adopt.
#
# Two tiers:
#   * normal files        → host psql as role `postgres` (approved port map)
#   * *_privileged.sql    → `docker compose exec db psql -U supabase_admin`
#     (platform-owned objects, e.g. storage.objects RLS).
#
# Usage: tools/apply_migrations.sh <supabase> [adopt]
# Exit 0 on success; any failed statement aborts (ON_ERROR_STOP=1).
# =============================================================================
set -euo pipefail

STACK="${1:?usage: apply_migrations.sh <supabase> [adopt]}"
ACTION="${2:-apply}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/$STACK"

POSTGRES_PORT_VAL="${POSTGRES_PORT:-54382}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
DB_URL="${DB_URL:-postgres://postgres:postgres@localhost:${POSTGRES_PORT_VAL}/postgres}"
LEDGER="public._qallariy_migrations"

# Migrations that POSTDATE the ledger: a pre-ledger DB does not have them, so
# `adopt` must NOT stamp them (they still need to run). Everything else in the
# tree is treated as already applied by the old applier.
LEDGER_ERA_FILES="223_device_tokens/device_tokens.sql 224_minigame_turn_notice/turn.sql"

case "$STACK" in
  supabase) DB_CONTAINER="${DB_CONTAINER:-${STACK_PREFIX:-samay}-db}" ;;
  *)        DB_CONTAINER="${DB_CONTAINER:?DB_CONTAINER required for $STACK}" ;;
esac

psql_q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -tAqc "$1"; }

# Storage readiness gate (storage-api creates the schema at its own startup).
wait_for_storage_schema() {
  echo "  Waiting for storage-api schema (storage.buckets)..."
  for _ in $(seq 1 60); do
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

psql_q "CREATE TABLE IF NOT EXISTS ${LEDGER} (
    filename   text PRIMARY KEY,
    applied_at timestamp with time zone NOT NULL DEFAULT now()
);" >/dev/null
# The platform default privileges grant ALL on postgres-created public tables to
# anon/authenticated; the ledger must be server-only (filenames are not data, but
# anon writes could skip/re-run migrations). Revoke every run (idempotent).
psql_q "REVOKE ALL ON ${LEDGER} FROM anon;" >/dev/null
psql_q "REVOKE ALL ON ${LEDGER} FROM authenticated;" >/dev/null

# ── adopt: record the existing baseline WITHOUT running it ────────────────────
if [ "$ACTION" = "adopt" ]; then
  adopted=0
  while IFS= read -r f; do
    rel="${f#migrations/}"
    case " $LEDGER_ERA_FILES " in *" $rel "*) continue ;; esac
    psql_q "INSERT INTO ${LEDGER} (filename) VALUES ('${rel}') ON CONFLICT DO NOTHING;" >/dev/null
    adopted=$((adopted + 1))
  done < <(find migrations -type f -name '*.sql' | LC_ALL=C sort)
  echo "  adopted ${adopted} baseline file(s) into ${LEDGER}."
  exit 0
fi

# ── apply ─────────────────────────────────────────────────────────────────────
schema_present="$(psql_q "SELECT to_regclass('public.users') IS NOT NULL;")"
ledger_count="$(psql_q "SELECT count(*) FROM ${LEDGER};")"
if [ "$schema_present" = "t" ] && [ "${ledger_count:-0}" = "0" ]; then
  echo "ERROR: pre-ledger database (schema present, ledger empty)." >&2
  echo "       Run 'make migrate-adopt' once (VM: the equivalent adopt) to record" >&2
  echo "       the existing baseline, then re-run." >&2
  exit 1
fi

APPLIED=0
SKIPPED=0
while IFS= read -r f; do
  rel="${f#migrations/}"
  if [ "$(psql_q "SELECT 1 FROM ${LEDGER} WHERE filename = '${rel}' LIMIT 1;")" = "1" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  echo "  Applying ${rel}..."
  case "$f" in
    *_privileged.sql)
      wait_for_storage_schema
      docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres \
        -v ON_ERROR_STOP=1 -q < "$f" ;;
    *)
      psql "$DB_URL" -v ON_ERROR_STOP=1 -qf "$f" ;;
  esac
  psql_q "INSERT INTO ${LEDGER} (filename) VALUES ('${rel}');" >/dev/null
  APPLIED=$((APPLIED + 1))
done < <(find migrations -type f -name '*.sql' | LC_ALL=C sort)

echo "  ${APPLIED} applied, ${SKIPPED} already recorded."
