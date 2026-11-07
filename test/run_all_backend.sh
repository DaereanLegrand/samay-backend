#!/bin/bash
set -uo pipefail
# =============================================================================
# Samay — Backend Integration Test Runner
# Runs all opt-*.sh test scripts in order and reports summary.
#
# Suite (all auto-discovered via the test/opt-*.sh glob — no registration).
# The stack-free static gates are opt-005 (seed-config/seed-test parity),
# opt-007 (compose/config/ports) and opt-008 (Makefile/platform/signing
# contract); every other script is a LIVE curl/psql test against the local
# stack. CI was removed by owner decision (14-wave2-decisions §13), so there
# is no CI-workflow static gate any more.
#
# The vault is verified ONLY by `test/vault.sh`: a single human-only test that
# needs an interactive TTY + the vault password. It is deliberately not named
# `opt-*.sh` so this runner never discovers it — AGENTS MUST NEVER RUN IT.
#
# Usage: bash test/run_all_backend.sh
# Prerequisites: a running local stack (make supabase-reset) for the
# live tests — they hit Kong on 127.0.0.1:54386; the static gates pass
# anywhere.
#
# NOTE: The Flutter integration suite (integration_test/) was DELETED
# (directive 2026-08-31 — testing is backend-only). Exit code reflects ONLY
# the opt-* curl tests below.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"

# Keys come from the RUNNING stack's env files via the shared loader
# (no key literals are committed anywhere — see test/dev_env.sh).
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

# Tests that document a disposable-stack requirement read STACK_ENV; default
# them to this running stack's env file so the full local suite is runnable
# in one pass (override STACK_ENV to point them at a disposable stack).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export STACK_ENV="${STACK_ENV:-$ROOT_DIR/supabase/.env}"
DB_PORT="$(sed -n 's/^POSTGRES_PORT=//p' "$STACK_ENV" | head -1 | awk '{print $1}' | tr -d '"')"
DB_PORT="${DB_PORT:-54382}"

PASS=0
FAIL=0
TOTAL=0
FAILED_TESTS=""


echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Samay — Backend Integration Tests"
echo "  Supabase: $SUPABASE_URL"
echo "  Date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "═══════════════════════════════════════════════════════════════"

for f in test/opt-*.sh; do
  TOTAL=$((TOTAL + 1))
  name=$(basename "$f")
  echo ""
  echo "━━━ [$TOTAL] Running $name ━━━"

  # Rate-limit counters are per-run artifacts; a prior test must never make
  # the next one fail (E3 limits are 3/min, 5/hour, 20/day ...).
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d postgres \
    -tAc "DELETE FROM public.action_rate_limits;" >/dev/null 2>&1 || true

  start=$(date +%s%N)
  if bash "$f"; then
    end=$(date +%s%N)
    elapsed_ms=$(((end - start) / 1000000))
    PASS=$((PASS + 1))
    echo "  ✅ $name passed (${elapsed_ms}ms)"
  else
    end=$(date +%s%N)
    elapsed_ms=$(((end - start) / 1000000))
    FAIL=$((FAIL + 1))
    FAILED_TESTS="$FAILED_TESTS\n  - $name"
    echo "  ❌ $name FAILED (${elapsed_ms}ms)"
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo "  Total:  $TOTAL"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  Failed tests:"
  echo -e "$FAILED_TESTS"
  echo ""
  exit 1
else
  echo ""
  echo "  🎉 All backend integration tests passed!"
  exit 0
fi
