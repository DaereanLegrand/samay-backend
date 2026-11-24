#!/usr/bin/env bash
# SEC-013 — the two env classes hold the line:
#   * no placeholder secret is ever a compose default (a missing credential
#     must yield an EMPTY value, never "your-anon-key");
#   * testing-local mints its own JWT and refuses a placeholder;
#   * the testing LAYOUT carries no secret at all.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "compose-secrets (SEC-013)"

# 1. No fake credential may sit in compose as a default.
if grep -R -nE 'your-(anon|service|supabase|jwt)|your_supabase|change-in-production' \
     "$ROOT/supabase"/docker-compose*.yml >/dev/null 2>&1; then
  fail "a placeholder credential is a compose default:"
  grep -R -nE 'your-(anon|service|supabase|jwt)|your_supabase|change-in-production' \
    "$ROOT/supabase"/docker-compose*.yml | sed 's/^/      /'
else
  pass "no placeholder credential in compose"
fi

# 2. Secret-bearing compose vars must resolve to empty when unset (no fake key).
for v in SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY JWT_SECRET; do
  if grep -qE "\\\$\{$v:-[^}]" "$ROOT/supabase/docker-compose.yml"; then
    fail "$v has a non-empty compose default"
  else
    pass "$v has no non-empty compose default"
  fi
done

# 3. JWT_SECRET is still wired into every verifier (db, kong, auth, rest,
#    realtime, storage) even though its default is empty.
count="$(grep -c "JWT_SECRET:-" "$ROOT/supabase/docker-compose.yml")"
[ "$count" -ge 7 ] && pass "JWT_SECRET wired into $count places" || fail "JWT_SECRET wiring incomplete ($count)"

# 4. testing-local env template documents the app-level toggles and mints.
grep -q 'FUNCTIONS_VERIFY_JWT=true' "$ROOT/.env/example.env" \
  && pass ".env.example documents FUNCTIONS_VERIFY_JWT" \
  || fail ".env.example missing FUNCTIONS_VERIFY_JWT"
[ -x "$ROOT/tools/gen-local-env.sh" ] && pass "local env generator executable" || fail "local env generator missing/not executable"
[ -x "$ROOT/tools/check-stack-env.sh" ] && pass "boot env check executable" || fail "boot env check missing/not executable"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/samay-i063.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/.env/example.env" "$TMP/env"

# 5. Boot check rejects a placeholder JWT.
python3 - "$TMP/env" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().splitlines() if not l.startswith('JWT_SECRET=')]
lines.append('JWT_SECRET=your-jwt-secret-change-in-production')
open(p, 'w').write('\n'.join(lines) + '\n')
PY
if bash "$ROOT/tools/check-stack-env.sh" "$TMP/env" testing-local >"$TMP/out" 2>"$TMP/err"; then
  fail "boot check accepted the placeholder"
else
  grep -qi 'placeholder' "$TMP/err" && pass "boot check rejects the placeholder" || fail "boot check rejection unclear"
fi

# 6. The generator produces a usable secret pair, and --fill is idempotent.
bash "$ROOT/tools/gen-local-env.sh" "$TMP/env" >/dev/null 2>&1 || fail "local env generator failed"
bash "$ROOT/tools/check-stack-env.sh" "$TMP/env" testing-local >/dev/null 2>&1 \
  && pass "generated local env passes boot check" || fail "generated local env rejected"
SEC1="$(sed -n 's/^JWT_SECRET=//p' "$TMP/env" | head -1)"
[ "${#SEC1}" -ge 32 ] && pass "generated JWT_SECRET length >= 32" || fail "generated JWT_SECRET too short"
grep -q '^SUPABASE_ANON_KEY=eyJ' "$TMP/env" && pass "anon key minted" || fail "anon key not minted"
grep -q '^SUPABASE_SERVICE_ROLE_KEY=eyJ' "$TMP/env" && pass "service key minted" || fail "service key not minted"
bash "$ROOT/tools/gen-local-env.sh" "$TMP/env" --fill >/dev/null 2>&1
SEC2="$(sed -n 's/^JWT_SECRET=//p' "$TMP/env" | head -1)"
[ "$SEC1" = "$SEC2" ] && pass "--fill preserves an existing secret" || fail "--fill rotated an existing secret"

# 7. The testing LAYOUT carries no secret and is accepted as a layout.
if grep -qE '^[A-Z_0-9_]*(SECRET|_KEY|_PASS)[A-Z_0-9_]*=.+' "$ROOT/.env/testing.env"; then
  fail ".env/testing.env carries a secret:"
  grep -nE '^[A-Z_0-9_]*(SECRET|_KEY|_PASS)[A-Z_0-9_]*=' "$ROOT/.env/testing.env" | sed 's/=.*/=<redacted>/' | sed 's/^/      /'
else
  pass ".env/testing.env is secret-free (layout only)"
fi
bash "$ROOT/tools/check-stack-env.sh" "$ROOT/.env/testing.env" testing >/dev/null 2>&1 \
  && pass "testing layout passes the boot check" || fail "testing layout rejected"

# 8. Compose parses the layout alone (stop/status/logs need no secret).
if ( cd "$ROOT/supabase" && COMPOSE_FILE=docker-compose.yml:docker-compose.pg17.yml:docker-compose.rustfs.yml:docker-compose.pushworker.yml docker compose -p samay-i063 --env-file "$ROOT/.env/testing.env" config --quiet ) >/dev/null 2>&1; then
  pass "compose parses the testing layout without secrets"
else
  fail "compose cannot parse the testing layout"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then echo "  $FAILURES compose-secret check(s) failed."; exit 1; fi
echo "  all compose-secret checks passed."
exit 0
