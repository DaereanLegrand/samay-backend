#!/bin/bash
set -uo pipefail
# =============================================================================
# Samay — Backend Integration Test Runner
# Runs all opt-*.sh test scripts in order and reports summary.
#
# Suite (all auto-discovered via the test/opt-*.sh glob — no registration):
#   opt-001-rls-security.sh      RLS / anon vs auth vs service_role security
#   opt-002-events.sh            event lifecycle (fields, CHECK, QR trigger, RLS)
#   opt-003-chat.sh              chat + E2EE envelope contract (RLS, message cap)
#   opt-004-photos.sh            photo gallery contract (RLS, likes trigger, UNIQUE)
#   opt-005-seed-dev-static.sh   STATIC gate for seed-dev.sql (no stack needed)
#   opt-006-e2ee-rpc.sh          fetch_prekey_bundle contract (OPK consumption)
#   opt-007-compose-static.sh    STATIC gate for compose/config/ports (no stack needed)
#   opt-008-makefile-static.sh   STATIC gate for Makefile/scratch-repo rules (no stack)
#
# Usage: bash test/run_all_backend.sh
# Prerequisites: make supabase-docker-start, make supabase-docker-reset
# (all opt-tests except opt-005 need the stack on Kong 127.0.0.1:54386;
#  opt-005 is a static gate that runs anywhere)
#
# NOTE: The Flutter integration suite (integration_test/) was DELETED
# (directive 2026-08-31 — testing is backend-only). Exit code reflects ONLY
# the opt-* curl tests below.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"

# Keys come from the RUNNING stack's env files via the shared loader
# (no key literals are committed anywhere — see test/dev_env.sh).
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

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
