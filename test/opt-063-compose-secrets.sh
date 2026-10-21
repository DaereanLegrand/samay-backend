#!/usr/bin/env bash
# SEC-013 — no placeholder JWT secret; fail fast when JWT_SECRET is missing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "compose-secrets (SEC-013)"

if grep -R -n 'your-jwt-secret-change-in-production' "$ROOT/supabase"/docker-compose*.yml "$ROOT/supabase/.env.example" >/dev/null 2>&1; then
  fail "literal JWT placeholder still tracked"
else
  pass "no literal JWT placeholder in compose/.env.example"
fi

count="$(grep -c '\${JWT_SECRET:?' "$ROOT/supabase/docker-compose.yml")"
[ "$count" -ge 7 ] && pass "compose requires JWT_SECRET ($count references)" || fail "compose JWT_SECRET requirement incomplete ($count)"
grep -q 'FUNCTIONS_VERIFY_JWT=true' "$ROOT/supabase/.env.example" && pass ".env.example documents FUNCTIONS_VERIFY_JWT" || fail ".env.example missing FUNCTIONS_VERIFY_JWT"
[ -x "$ROOT/tools/gen-local-env.sh" ] && pass "local env generator executable" || fail "local env generator missing/not executable"
[ -x "$ROOT/tools/check-stack-env.sh" ] && pass "boot env check executable" || fail "boot env check missing/not executable"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/samay-i063.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
COMPOSE_ARGS=(-p samay-i063 --env-file "$TMP/env" -f "$ROOT/supabase/docker-compose.yml")

cp "$ROOT/supabase/.env.example" "$TMP/env"
if docker compose "${COMPOSE_ARGS[@]}" config >"$TMP/out" 2>"$TMP/err"; then
  fail "compose accepted a missing JWT_SECRET"
else
  grep -qi 'JWT_SECRET is required' "$TMP/err" && pass "compose fails fast without JWT_SECRET" || fail "compose failure did not mention JWT_SECRET"
fi

cp "$ROOT/supabase/.env.example" "$TMP/env"
python3 - "$TMP/env" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().splitlines() if not l.startswith('JWT_SECRET=')]
lines.append('JWT_SECRET=your-jwt-secret-change-in-production')
open(p, 'w').write('\n'.join(lines) + '\n')
PY
if bash "$ROOT/tools/check-stack-env.sh" "$TMP/env" >"$TMP/out" 2>"$TMP/err"; then
  fail "boot check accepted the placeholder"
else
  grep -qi 'placeholder' "$TMP/err" && pass "boot check rejects the placeholder" || fail "boot check rejection unclear"
fi

bash "$ROOT/tools/gen-local-env.sh" "$TMP/env" >/dev/null 2>&1 || fail "local env generator failed"
bash "$ROOT/tools/check-stack-env.sh" "$TMP/env" >/dev/null 2>&1 && pass "generated local env passes boot check" || fail "generated local env rejected"
if docker compose "${COMPOSE_ARGS[@]}" config >"$TMP/out" 2>"$TMP/err"; then
  pass "compose config succeeds with generated secret"
else
  fail "compose config failed with generated secret"
fi

SEC1="$(sed -n 's/^JWT_SECRET=//p' "$TMP/env" | head -1)"
[ "${#SEC1}" -ge 32 ] && pass "generated JWT_SECRET length >= 32" || fail "generated JWT_SECRET too short"
grep -q '^SUPABASE_ANON_KEY=eyJ' "$TMP/env" && pass "anon key minted" || fail "anon key not minted"
grep -q '^SUPABASE_SERVICE_ROLE_KEY=eyJ' "$TMP/env" && pass "service key minted" || fail "service key not minted"
bash "$ROOT/tools/gen-local-env.sh" "$TMP/env" --fill >/dev/null 2>&1
SEC2="$(sed -n 's/^JWT_SECRET=//p' "$TMP/env" | head -1)"
[ "$SEC1" = "$SEC2" ] && pass "--fill preserves an existing secret" || fail "--fill rotated an existing secret"

echo ""
if [ "$FAILURES" -gt 0 ]; then echo "  $FAILURES compose-secret check(s) failed."; exit 1; fi
echo "  all compose-secret checks passed."
exit 0
