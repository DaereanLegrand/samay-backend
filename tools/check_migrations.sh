#!/usr/bin/env bash
# Migration hygiene gate (single stack: supabase/migrations).
#   1. no UNTRACKED migration files (they must be committed to be applied)
#   2. layout <NNN_domain>/<name>.sql with unique numeric prefixes
# Usage: tools/check_migrations.sh [repo_root]
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
MIG="supabase/migrations"
FAILURES=0
fail() { echo "  FAIL $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  PASS $*"; }

echo "migration hygiene"

[ -d "$ROOT/.git" ] || { echo "  FAIL $ROOT is not a git repo"; exit 2; }

UNTRACKED="$(git -C "$ROOT" status --short -- "$MIG" 2>/dev/null | grep '^??' || true)"
if [ -z "$UNTRACKED" ]; then pass "no untracked migrations"; else printf '%s\n' "$UNTRACKED"; fail "untracked migration(s)"; fi

BAD=""
while IFS= read -r REL; do
  REL="${REL#./}"
  [[ "$REL" =~ ^[0-9]{3}_[a-z0-9_]+/[a-z0-9_]+\.sql$ ]] || BAD="$BAD $REL"
done < <(cd "$ROOT/$MIG" && find . -type f -name '*.sql' | LC_ALL=C sort)
DUP="$(cd "$ROOT/$MIG" && find . -type f -name '*.sql' | sed 's|^\./||' | cut -d/ -f1 | sort -u | sed -E 's|^([0-9]{3})_.*|\1|' | sort | uniq -d)"

[ -z "$BAD" ] && pass "layout <NNN_domain>/<name>.sql" || fail "non-conforming path(s):$BAD"
[ -z "$DUP" ] && pass "unique ordering prefixes" || fail "duplicate prefix(es):$DUP"

[ "$FAILURES" -eq 0 ] && { echo "  all migration-hygiene checks passed."; exit 0; } || exit 1
