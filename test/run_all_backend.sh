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
# NOTE: The Flutter modular integration suite (integration_test/) is a SEPARATE
# suite and is NOT run here (it needs no server in hermetic mode, but runs
# under `flutter test`). This script only reports whether it exists and how to
# run it. Exit code reflects ONLY the opt-* curl tests below.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="${ANON_KEY:-eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9.eyJyb2xlIjogImFub24iLCAiaXNzIjogInN1cGFiYXNlIiwgImlhdCI6IDE3ODY0ODU4OTMsICJleHAiOiAxODE4MDIxODkzfQ.YR0NRqrTGXY6JibsjhLEkC7EE1T83b887bCqaZd834Y}"

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

# ── Flutter integration suite (separate step, NOT executed here) ────────────
# The modular Flutter integration suite lives in integration_test/ and runs
# under `flutter test` (hermetic by default — no server needed). It is out of
# scope for this curl-based runner, but we detect and link it so CI and humans
# see the full picture. Exit semantics below cover ONLY the opt-* tests.
if [ -f integration_test/runner.sh ]; then
  FLOWS=$(ls integration_test/*_test.dart 2>/dev/null | wc -l | tr -d ' ')
  echo ""
  echo "━━━ Flutter integration suite (separate step, not run here) ━━━"
  echo "  integration_test/ present — $FLOWS flow file(s)."
  echo "  Run it separately (does not need this stack in hermetic mode):"
  echo "    bash integration_test/runner.sh                  # no device needed"
  echo "    bash integration_test/runner.sh -d <device-id>   # on device/emulator"
  echo "  Each flow also runs standalone, e.g.:"
  echo "    flutter test integration_test/auth_flow_test.dart"
else
  echo ""
  echo "━━━ Flutter integration suite ━━━"
  echo "  integration_test/ not present (expected once I-01 lands)."
fi

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
