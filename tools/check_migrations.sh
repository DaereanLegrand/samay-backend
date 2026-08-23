#!/usr/bin/env bash
# =============================================================================
# check_migrations.sh — migration hygiene gate (rewritten by MSQ-01, 2026-08-22
# for the feature-organized baseline tree; replaces the M-15 timestamp-era
# checks. Probed by test/opt-008-makefile-static.sh §3.)
#
# Static checks — no DB, no docker:
#
#   1. No UNTRACKED migration files in EITHER stack (supabase/migrations AND
#      supabase-testing/migrations) — migrations must be committed before
#      apply_migrations.sh runs them (M-10 stack-parity contract).
#   2. STACK PARITY: the sorted relative file list of both migration trees
#      must be IDENTICAL (same files, same dirs, same order inputs).
#   3. FILENAME CONVENTION: every migration lives at
#         migrations/<NNN_domain>/<name>.sql
#      where <NNN_domain> = ^[0-9]{3}_[a-z0-9_]+$ (three-digit ordering
#      prefix + snake_case domain) and <name> = ^[a-z0-9_]+\.sql$.
#      Files named *_privileged.sql run in the superuser tier (see
#      tools/apply_migrations.sh); the suffix is plain naming, not syntax.
#
# The old YYYYMMDDHHMMSS timestamp convention and future-date check were
# retired with the 49-file pile they policed (MSQ-01 squash).
#
# Usage: tools/check_migrations.sh [repo_root]   # default: repo root (this file's parent)
# Exit 0 = all checks pass, 1 = violations found, 2 = not a git repo.
# =============================================================================
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
STACKS=("supabase/migrations" "supabase-testing/migrations")
FAILURES=0
fail() { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  MSQ-01 — migration hygiene (both stacks)"
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
  fail "UNTRACKED migration file(s) — commit them before apply_migrations.sh runs them"
fi

# ── 2. Stack parity: identical sorted relative file lists ────────────────────
echo ""
echo "━━━ 2. Stack parity (identical file lists) ━━━"
list_stack() {
  (cd "$ROOT/$1" && find . -type f -name '*.sql' | LC_ALL=C sort)
}
COUNT_A="$(list_stack "${STACKS[0]}" | grep -c . || true)"
COUNT_B="$(list_stack "${STACKS[1]}" | grep -c . || true)"
if diff <(list_stack "${STACKS[0]}") <(list_stack "${STACKS[1]}") >/dev/null 2>&1; then
  pass "file lists identical ($COUNT_A files per stack)"
else
  fail "stack parity differs — supabase($COUNT_A) vs supabase-testing($COUNT_B):" \
       "$(diff <(list_stack "${STACKS[0]}") <(list_stack "${STACKS[1]}") | head -6 | tr '\n' ' ')"
fi

# ── 3. Filename convention ────────────────────────────────────────────────────
echo ""
echo "━━━ 3. Layout convention (<NNN_domain>/<name>.sql) ━━━"
BAD=""
DUP_PREFIXES=""
for STACK in "${STACKS[@]}"; do
  while IFS= read -r REL; do
    REL="${REL#./}"
    if ! [[ "$REL" =~ ^[0-9]{3}_[a-z0-9_]+/[a-z0-9_]+\.sql$ ]]; then
      BAD="$BAD $STACK/$REL"
    fi
  done < <(list_stack "$STACK")
  # Duplicate numeric dir prefixes make apply ordering ambiguous
  DUP="$(list_stack "$STACK" | sed 's|^\./||;s|/[^/]*$||' | sort -u | uniq -d)"
  [ -n "$DUP" ] && DUP_PREFIXES="$DUP_PREFIXES [$STACK: $(echo $DUP | tr '\n' ' ')]"
done
if [ -z "$BAD" ]; then
  pass "all paths match <NNN_domain>/<name>.sql"
else
  fail "non-conforming path(s):$BAD"
fi
if [ -z "$DUP_PREFIXES" ]; then
  pass "no duplicate ordering prefixes"
else
  fail "duplicate dir prefix(es):$DUP_PREFIXES"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "  ❌ $FAILURES migration-hygiene check(s) failed."
  exit 1
fi
echo "  ✅ all migration-hygiene checks passed."
exit 0
