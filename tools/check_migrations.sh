#!/usr/bin/env bash
# =============================================================================
# check_migrations.sh — migration hygiene gate (MKE-07 CI parity, agent M-15).
#
# Replaces the old inline grep in the `migrate-check` Makefile target. The
# logic lives in a script so the static gate (test/opt-008-makefile-static.sh)
# can RED-probe it against a scratch git repo. Static checks — no DB, no
# docker:
#
#   1. No UNTRACKED migration files in EITHER stack (supabase/migrations AND
#      supabase-testing/migrations) — migrations must be committed before
#      migrate.sh applies them (M-10 stack-parity contract).
#   2. The latest migration matches between the two stacks AND the file COUNT
#      matches (the stacks must stay in step — M-10 parity).
#   3. No migration carries a YYYYMMDD timestamp dated AFTER today (UTC) —
#      future-dated = typo or unshipped change; sanity gate. The timestamp
#      convention is <UTC 14-digit date><sequence>_<snake_case>.sql, e.g.
#      20260810000007_storage_buckets.sql.
#   4. Every migration filename conforms to that 14-digit convention
#      (^[0-9]{14}_[a-zA-Z0-9_]+\.sql$).
#
# Usage: tools/check_migrations.sh [repo_root]   # default: repo root (this file's parent)
# Exit 0 = all checks pass, 1 = violations found, 2 = not a git repo.
# =============================================================================
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
STACKS=("supabase/migrations" "supabase-testing/migrations")
TODAY="$(date -u +%Y%m%d)"
FAILURES=0
fail() { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  M-15 — migration hygiene (both stacks)"
echo "═══════════════════════════════════════════════════════════════"

if [ ! -d "$ROOT/.git" ]; then
  echo "  ❌ $ROOT is not a git repo (cannot check untracked state)."
  exit 2
fi

# ── 1. Untracked migrations ──────────────────────────────────────────────────
echo ""
echo "━━━ 1. No untracked migrations ━━━"
UNTRACKED="$(git -C "$ROOT" status --short -- "${STACKS[@]}" 2>/dev/null | grep '^??' || true)"
if [ -z "$UNTRACKED" ]; then
  pass "no untracked files in either migration stack"
else
  printf '%s\n' "$UNTRACKED" | sed 's/^/      /'
  fail "UNTRACKED migration file(s) — commit them before migrate.sh applies them"
fi

# ── 2. Latest-migration + count parity between stacks ────────────────────────
echo ""
echo "━━━ 2. Latest migration + count parity (M-10) ━━━"
LATEST_A="$(ls "$ROOT/${STACKS[0]}" 2>/dev/null | grep -E '\.sql$' | sort | tail -1)"
LATEST_B="$(ls "$ROOT/${STACKS[1]}" 2>/dev/null | grep -E '\.sql$' | sort | tail -1)"
COUNT_A="$(ls "$ROOT/${STACKS[0]}" 2>/dev/null | grep -cE '\.sql$')"
COUNT_B="$(ls "$ROOT/${STACKS[1]}" 2>/dev/null | grep -cE '\.sql$')"
if [ "$LATEST_A" = "$LATEST_B" ]; then
  pass "latest migration identical in both stacks: $LATEST_A"
else
  fail "latest migration differs — ${STACKS[0]}: $LATEST_A vs ${STACKS[1]}: $LATEST_B"
fi
if [ "$COUNT_A" -eq "$COUNT_B" ]; then
  pass "migration count identical ($COUNT_A)"
else
  fail "count differs — ${STACKS[0]}: $COUNT_A vs ${STACKS[1]}: $COUNT_B"
fi

# ── 3. No future-dated timestamps ────────────────────────────────────────────
echo ""
echo "━━━ 3. No future-dated migration timestamps (today: $TODAY UTC) ━━━"
FUTURE=""
for STACK in "${STACKS[@]}"; do
  for F in "$ROOT/$STACK"/*.sql; do
    [ -e "$F" ] || continue
    BASE="$(basename "$F")"
    STAMP="${BASE%%_*}"
    case "$STAMP" in
      ''|*[!0-9]*) continue ;;   # format check below reports it
    esac
    DATE="${STAMP:0:8}"          # first 8 digits = the YYYYMMDD date part
    if [ "$((10#$DATE))" -gt "$((10#$TODAY))" ]; then
      FUTURE="$FUTURE $BASE"
    fi
  done
done
if [ -z "$FUTURE" ]; then
  pass "no migration dated after today"
else
  fail "future-dated migration(s):$FUTURE"
fi

# ── 4. Filename convention (YYYYMMDDHHMMSS_name.sql) ─────────────────────────
echo ""
echo "━━━ 4. Migration filename convention (14-digit timestamp) ━━━"
BAD=""
for STACK in "${STACKS[@]}"; do
  for F in "$ROOT/$STACK"/*.sql; do
    [ -e "$F" ] || continue
    if ! [[ "$(basename "$F")" =~ ^[0-9]{14}_[a-zA-Z0-9_]+\.sql$ ]]; then
      BAD="$BAD $(basename "$F")"
    fi
  done
done
if [ -z "$BAD" ]; then
  pass "all files match YYYYMMDDHHMMSS_name.sql"
else
  fail "non-conforming filename(s):$BAD"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "  ❌ $FAILURES migration-hygiene check(s) failed."
  exit 1
fi
echo "  ✅ all migration-hygiene checks passed."
exit 0
