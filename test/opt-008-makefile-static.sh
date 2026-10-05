#!/usr/bin/env bash
# Backend static contract: targets resolve, separation, no supabase-docker, migrate gate.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$REPO/Makefile"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "backend makefile-static"

TARGETS="help init start stop status reset seed tunnel in-db \
build-cli build-linux build-api build-loadtest loadtest \
test check lint secrets migrate hooks"
for t in $TARGETS; do
  if make -n "$t" >/dev/null 2>&1; then pass "make -n $t"; else fail "make -n $t does not resolve"; fi
done
for pair in "test db" "test api" "loadtest smoke"; do
  if make -n $pair >/dev/null 2>&1; then pass "make -n $pair"; else fail "make -n $pair does not resolve"; fi
done

# Separation: no frontend-only targets may be defined here.
for t in build dev install build-install uninstall clear prepare signing-restore \
         analyze env tunnel-android tunnel-waydroid login ios-beta ios-release \
         android-alpha android-release bundle-install; do
  if grep -qE "^$t:" "$MAKEFILE"; then fail "frontend target '$t' leaked into backend Makefile"; fi
done
pass "no frontend-only targets defined"

# Standardization: legacy long names must be gone.
for t in db-test backend-tests test-static test-go secrets-check migrate-check \
         install-hooks loadtest-smoke supabase-docker; do
  if grep -qE "^$t:" "$MAKEFILE"; then fail "legacy target '$t' still defined"; fi
done
pass "no legacy/renamed targets defined"

# migrate-check RED probe (scratch git repo, real repo untouched).
if bash -n "$REPO/tools/check_migrations.sh" 2>/dev/null; then pass "bash -n tools/check_migrations.sh"; else fail "bash -n tools/check_migrations.sh"; fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/samay-be008.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
env -u GIT_INDEX_FILE git init -q "$SCRATCH"
mkdir -p "$SCRATCH/supabase/migrations/010_infra"
printf '%s\n' "-- placeholder schema --" > "$SCRATCH/supabase/migrations/010_infra/01_extensions.sql"
env -u GIT_INDEX_FILE git -C "$SCRATCH" add -A
env -u GIT_INDEX_FILE git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -q -m init

if env -u GIT_INDEX_FILE bash "$REPO/tools/check_migrations.sh" "$SCRATCH" >/dev/null 2>&1; then
  pass "GREEN: clean tree passes"
else
  fail "GREEN: clean tree should pass"
fi

printf '%s\n' "-- planted --" > "$SCRATCH/supabase/migrations/010_infra/planted.sql"
OUT="$(env -u GIT_INDEX_FILE bash "$REPO/tools/check_migrations.sh" "$SCRATCH" 2>&1)"
if [ $? -eq 1 ] && printf '%s' "$OUT" | grep -qi "untracked"; then
  pass "RED: untracked migration flagged"
else
  fail "RED: untracked migration not flagged"
fi
rm "$SCRATCH/supabase/migrations/010_infra/planted.sql"

printf '%s\n' "-- loose --" > "$SCRATCH/supabase/migrations/loose.sql"
env -u GIT_INDEX_FILE git -C "$SCRATCH" add -A
env -u GIT_INDEX_FILE git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -q -m loose
OUT="$(env -u GIT_INDEX_FILE bash "$REPO/tools/check_migrations.sh" "$SCRATCH" 2>&1)"
if [ $? -eq 1 ] && printf '%s' "$OUT" | grep -qi "conforming\|layout"; then
  pass "RED: non-conforming layout flagged"
else
  fail "RED: non-conforming layout not flagged"
fi

if bash -n "$0" 2>/dev/null; then pass "bash -n $0"; else fail "bash -n $0"; fi

echo ""
if [ "$FAILURES" -gt 0 ]; then echo "  $FAILURES backend static check(s) failed."; exit 1; fi
echo "  all backend static checks passed."
exit 0
