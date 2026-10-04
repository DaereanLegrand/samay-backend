#!/bin/bash
set -uo pipefail
# =============================================================================
# Samay — Backend Integration Test Runner
# Runs all opt-*.sh test scripts in order and reports summary.
#
# Suite (all auto-discovered via the test/opt-*.sh glob — no registration;
# 36 scripts today): opt-001…016 and opt-018…038 (there is NO opt-017). The
# stack-free static gates are opt-005 (seed-config/seed-test parity), opt-007
# (compose/config/ports), opt-008 (Makefile/platform/signing contract),
# opt-034 (Gitea workflows + Xcode Cloud), opt-036 (UTM/CI bootstrap media
# root), opt-037 (Qallariy Mail bootstrap) and opt-038 (offline root-grow
# InitRD hook); every other script is a LIVE curl test.
#
# The vault is verified ONLY by `test/vault.sh`: a single human-only test that
# needs an interactive TTY + the vault password. It is deliberately not named
# `opt-*.sh` so this runner never discovers it — AGENTS MUST NEVER RUN IT.
#
# Usage: bash test/run_all_backend.sh
# Prerequisites: a running local stack (make supabase-testing-reset) for the
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
