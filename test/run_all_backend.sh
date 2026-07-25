#!/bin/bash
set -uo pipefail
# =============================================================================
# Samay — Backend Integration Test Runner
# Runs all opt-*.sh test scripts in order and reports summary.
#
# Usage: bash test/run_all_backend.sh
# Prerequisites: make supabase-start, make supabase-reset
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="${ANON_KEY:-sb_publishable_q7NDNoV4TCGqCgheg4tcvC_odjEiEdN}"

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
