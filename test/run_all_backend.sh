#!/bin/bash
set -uo pipefail
# =============================================================================
# Samay — Backend Integration Test Runner
# Runs all opt-*.sh test scripts in order and reports summary.
#
# Suite (all auto-discovered via the test/opt-*.sh glob — no registration).
# Slim-prod composition: 34 scripts. The stack-free static gates are opt-005
# (seed-config/seed-test parity), opt-008 (Makefile/platform/signing contract)
# and opt-063 (compose secrets); every other script is a LIVE curl/psql test
# against the local stack. Kept surfaces: RLS (001), minigame sessions (006,
# 016, 018-023, 028-032), groups (009/010/011/070), friendships (012), profile
# (014), search (015), safety/abuse (050/051/052, 060-065), subscriptions
# (068) and password recovery (069). Removed with their features: events,
# E2EE chat, photos, user ranking and the shard economy. CI was removed by
# owner decision (14-wave2-decisions §13), so there is no CI-workflow static
# gate any more.
#
# Operator-only release checks are not part of this runner: they need an
# interactive TTY and operator credentials, are deliberately not named
# `opt-*.sh` so this runner never discovers them, and agents must never run them.
#
# Usage: bash test/run_all_backend.sh
# Prerequisites: a running local stack (make reset) for the
# live tests — they hit Kong on 127.0.0.1:54396; the static gates pass
# anywhere.
#
# NOTE: Dart/Flutter tests live in the frontend repo (`test/*.dart`); this
# runner covers the backend only. Exit code reflects ONLY the opt-* curl tests
# below.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"

# Keys come from the RUNNING stack's env files via the shared loader
# (no key literals are committed anywhere — see test/dev_env.sh).
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

# Tests that document a disposable-stack requirement read STACK_ENV; default
# them to this running stack's env file so the full local suite is runnable
# in one pass (override STACK_ENV to point them at a disposable stack).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export STACK_ENV="${STACK_ENV:-$ROOT_DIR/.env/testing-local.env}"
DB_PORT="$(sed -n 's/^POSTGRES_PORT=//p' "$STACK_ENV" | head -1 | awk '{print $1}' | tr -d '"')"
DB_PORT="${DB_PORT:-54392}"

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
