#!/usr/bin/env bash
# Backend static contract: targets resolve, separation, no supabase-docker, migrate gate.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$REPO/Makefile"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "backend makefile-static"

TARGETS="help build-cli build-linux build-api build-loadtest loadtest loadtest-smoke \
test test-all test-backend-static test-go check lint secrets-check migrate-check install-hooks \
supabase-start supabase-stop supabase-status supabase-reset supabase-init \
supabase-seed-config supabase-seed-test in-db supabase-db-test supabase-backend-tests supabase-stack-check \
supabase-testing-start supabase-testing-stop supabase-testing-status supabase-testing-reset supabase-testing-init \
supabase-testing-seed-sample-matches"
for t in $TARGETS; do
  if make -n "$t" >/dev/null 2>&1; then pass "make -n $t"; else fail "make -n $t does not resolve"; fi
done

# Separation: no frontend-only targets may be defined here.
for t in build dev install build-install uninstall clear-storage define-env flutter-analyze \
         tunnel-android tunnel-waydroid ios-signing-restore login ios-beta ios-release \
         android-alpha android-release bundle-install; do
  if grep -qE "^$t:" "$MAKEFILE"; then fail "frontend target '$t' leaked into backend Makefile"; fi
done
pass "no frontend-only targets defined"

# Standardization: supabase-docker-* must be gone.
if grep -qE '^supabase-docker' "$MAKEFILE"; then fail "supabase-docker-* targets still defined"; else pass "no supabase-docker-* targets"; fi

# migrate-check RED probe (scratch git repo, real repo untouched).
if bash -n "$REPO/tools/check_migrations.sh" 2>/dev/null; then pass "bash -n tools/check_migrations.sh"; else fail "bash -n tools/check_migrations.sh"; fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/samay-be008.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
env -u GIT_INDEX_FILE git init -q "$SCRATCH"
mkdir -p "$SCRATCH/supabase/migrations/010_infra" "$SCRATCH/supabase-testing/migrations/010_infra"
printf '%s\n' "-- placeholder schema --" > "$SCRATCH/supabase/migrations/010_infra/01_extensions.sql"
cp "$SCRATCH/supabase/migrations/010_infra/01_extensions.sql" "$SCRATCH/supabase-testing/migrations/010_infra/"
env -u GIT_INDEX_FILE git -C "$SCRATCH" add -A
env -u GIT_INDEX_FILE git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -q -m init

if env -u GIT_INDEX_FILE bash "$REPO/tools/check_migrations.sh" "$SCRATCH" >/dev/null 2>&1; then
  pass "GREEN: clean stacks pass"
else
  fail "GREEN: clean stacks should pass"
fi

printf '%s\n' "-- planted --" > "$SCRATCH/supabase/migrations/010_infra/planted.sql"
OUT="$(env -u GIT_INDEX_FILE bash "$REPO/tools/check_migrations.sh" "$SCRATCH" 2>&1)"
if [ $? -eq 1 ] && printf '%s' "$OUT" | grep -q "UNTRACKED"; then
  pass "RED: untracked migration flagged"
else
  fail "RED: untracked migration not flagged"
fi
rm "$SCRATCH/supabase/migrations/010_infra/planted.sql"

mkdir -p "$SCRATCH/supabase/migrations/020_core"
printf '%s\n' "-- one-sided --" > "$SCRATCH/supabase/migrations/020_core/01_enums.sql"
env -u GIT_INDEX_FILE git -C "$SCRATCH" add -A
env -u GIT_INDEX_FILE git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -q -m oneside
OUT="$(env -u GIT_INDEX_FILE bash "$REPO/tools/check_migrations.sh" "$SCRATCH" 2>&1)"
if [ $? -eq 1 ] && printf '%s' "$OUT" | grep -qi "parity\|differs"; then
  pass "RED: stack parity break flagged"
else
  fail "RED: stack parity break not flagged"
fi

if bash -n "$0" 2>/dev/null; then pass "bash -n $0"; else fail "bash -n $0"; fi

echo ""
if [ "$FAILURES" -gt 0 ]; then echo "  $FAILURES backend static check(s) failed."; exit 1; fi
echo "  all backend static checks passed."
exit 0
