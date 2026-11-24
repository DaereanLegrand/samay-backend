#!/usr/bin/env bash
# SEC-012 — Edge Functions auth (Kong JWT role gate + self-authenticated webhook).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_ENV="${STACK_ENV:-$ROOT/supabase/testing-local.env}"
KONG="$ROOT/supabase/volumes/api/kong.yml"
COMPOSE="$ROOT/supabase/docker-compose.yml"
FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

read_env() {
  sed -n "s/^${1}=\([^[:space:]#]*\).*/\1/p" "$STACK_ENV" 2>/dev/null | head -1
}

echo "functions-auth (SEC-012)"

grep -Eq -- '- name: jwt' "$KONG" && pass "kong: jwt plugin present" || fail "kong: jwt plugin missing"
grep -Eq 'key_claim_name: role' "$KONG" && pass "kong: jwt keyed on role claim" || fail "kong: role claim missing"
grep -Eq -- '- name: revenuecat-webhook' "$KONG" && pass "kong: webhook route present" || fail "kong: webhook route missing"
grep -Eq 'revenuecat-webhook:9000' "$KONG" && pass "kong: webhook routes to its service" || fail "kong: webhook upstream missing"
grep -Eq 'VERIFY_JWT: "\$\{FUNCTIONS_VERIFY_JWT:-true\}"' "$COMPOSE" && pass "compose: functions VERIFY_JWT defaults true" || fail "compose: VERIFY_JWT default not true"
grep -Eq 'main-service", "/home/deno/functions/revenuecat-webhook"' "$COMPOSE" && pass "compose: webhook runtime isolated" || fail "compose: webhook runtime missing"

function_dirs=()
while IFS= read -r f; do
  function_dirs+=("$(basename "$(dirname "$f")")")
done < <(find "$ROOT/supabase/functions" -mindepth 2 -maxdepth 2 -name index.ts | sort)
[ "${#function_dirs[@]}" -gt 0 ] && pass "discovered ${#function_dirs[@]} function(s)" || fail "no functions discovered"

if [ "${STATIC_ONLY:-0}" = "1" ]; then
  echo ""
  [ "$FAILURES" -eq 0 ] && { echo "  all static function-auth checks passed."; exit 0; }
  echo "  $FAILURES function-auth check(s) failed."; exit 1
fi

[ -r "$STACK_ENV" ] || { echo "  missing stack env: $STACK_ENV" >&2; exit 1; }
KONG_PORT="$(read_env KONG_HTTP_PORT)"; KONG_PORT="${KONG_PORT:-54386}"
BASE="http://127.0.0.1:${KONG_PORT}"
ANON="$(read_env SUPABASE_ANON_KEY)"
SERVICE="$(read_env SUPABASE_SERVICE_ROLE_KEY)"
SECRET="$(read_env JWT_SECRET)"
WEBHOOK_SECRET="$(read_env REVENUECAT_WEBHOOK_SECRET)"

if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/rest/v1/")" = "000" ]; then
  echo "  stack not reachable at $BASE (set STACK_ENV; STATIC_ONLY=1 for static only)" >&2
  exit 1
fi

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

check_code() {
  local name="$1" expected="$2"; shift 2
  local got; got="$(code "$@")"
  if [[ " $expected " == *" $got "* ]]; then pass "$name ($got)"; else fail "$name (got $got, expected $expected)"; fi
}

check_code "unauthenticated /functions/v1/" "401" "$BASE/functions/v1/"
for fn in "${function_dirs[@]}"; do
  [ "$fn" = "revenuecat-webhook" ] && continue
  check_code "unauthenticated /functions/v1/$fn" "401 403" "$BASE/functions/v1/$fn"
done

check_code "webhook missing secret" "401 403" -X POST "$BASE/functions/v1/revenuecat-webhook"
check_code "webhook wrong secret" "401 403" -X POST -H "Authorization: Bearer wrong-secret" "$BASE/functions/v1/revenuecat-webhook"
if [ -n "$WEBHOOK_SECRET" ]; then
  check_code "webhook correct secret reaches handler" "400" -X POST \
    -H "Authorization: Bearer $WEBHOOK_SECRET" -H "Content-Type: application/json" \
    --data 'not-json' "$BASE/functions/v1/revenuecat-webhook"
else
  echo "  SKIP: webhook correct-secret check (REVENUECAT_WEBHOOK_SECRET unset)"
fi

if [ -n "$ANON" ] && [ -n "$SERVICE" ] && [ -n "$SECRET" ]; then
  check_code "anon role token denied" "403" -H "Authorization: Bearer $ANON" "$BASE/functions/v1/main"
  check_code "service_role token allowed" "200" -H "Authorization: Bearer $SERVICE" "$BASE/functions/v1/main"
  USER_JWT="$(JWT_SECRET="$SECRET" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
now = int(time.time())
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
body = b64(json.dumps({"role": "authenticated", "aud": "authenticated",
    "sub": "11111111-1111-4111-8111-111111111111", "iss": "supabase",
    "iat": now, "exp": now + 3600}, separators=(",", ":")).encode())
signed = f"{head}.{body}".encode()
sig = hmac.new(os.environ["JWT_SECRET"].encode(), signed, hashlib.sha256).digest()
print(f"{head}.{body}.{b64(sig)}")
PY
)"
  check_code "authenticated role token allowed" "200" -H "Authorization: Bearer $USER_JWT" "$BASE/functions/v1/main"
else
  fail "cannot test role gate (missing JWT_SECRET / keys in $STACK_ENV)"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then echo "  $FAILURES function-auth check(s) failed."; exit 1; fi
echo "  all function-auth checks passed."
exit 0
