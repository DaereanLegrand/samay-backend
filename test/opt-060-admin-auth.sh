#!/usr/bin/env bash
# [OPT-060] SEC-016 admin JWT auth + SEC-028 staging reviewer seed.
#
# Runs against ONE disposable stack:
#   STACK_ENV=/tmp/samay-a2.env API_PORT=18090 bash test/opt-060-admin-auth.sh
#
# Requirements: the stack is up, the default seed was applied (zero reviewer
# rows), and psql is on PATH. The script builds and starts its own API server,
# then stops only that process.
set -uo pipefail

STACK_ENV="${STACK_ENV:?set STACK_ENV to the disposable stack env}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

read_env() {
  sed -n "s/^${1}=\([^[:space:]#]*\).*/\1/p" "$STACK_ENV" | head -1
}

DB_PORT="$(read_env POSTGRES_PORT)"
KONG_PORT="$(read_env KONG_HTTP_PORT)"
SERVICE_KEY="$(read_env SUPABASE_SERVICE_ROLE_KEY)"
JWT_SECRET="$(read_env SUPABASE_JWT_SECRET)"
if [ -z "$JWT_SECRET" ]; then JWT_SECRET="$(read_env JWT_SECRET)"; fi
DB_PORT="${DB_PORT:-54382}"
KONG_PORT="${KONG_PORT:-54386}"
API_PORT="${API_PORT:-18097}"
BASE="http://127.0.0.1:${API_PORT}"

ADMIN_ID="00000000-0000-0000-0000-000000000000"
NONADMIN_ID="11111111-1111-4111-8111-111111111111"

[ -n "$SERVICE_KEY" ] || { echo "missing SUPABASE_SERVICE_ROLE_KEY in $STACK_ENV" >&2; exit 1; }
[ -n "$JWT_SECRET" ] || { echo "missing JWT_SECRET/SUPABASE_JWT_SECRET in $STACK_ENV" >&2; exit 1; }

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (got $3, expected $2)"; fi
}

psql_db() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -tAq "$@"
}

mint_jwt() { # mint_jwt <sub> <aud> <role> <exp-offset>
  JWT_SECRET="$JWT_SECRET" SUB="$1" AUD="$2" ROLE="$3" OFFSET="$4" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

now = int(time.time())
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload = b64(json.dumps({
    "role": os.environ["ROLE"],
    "aud": os.environ["AUD"],
    "sub": os.environ["SUB"],
    "iss": "supabase",
    "iat": now,
    "exp": now + int(os.environ["OFFSET"]),
}, separators=(",", ":")).encode())
signed = f"{header}.{payload}".encode()
sig = b64(hmac.new(os.environ["JWT_SECRET"].encode(), signed, hashlib.sha256).digest())
print(f"{header}.{payload}.{sig}")
PY
}

code() { # code <curl args...>
  curl -sS -o /tmp/opt060-resp -w '%{http_code}' "$@"
}

TMP="$(mktemp -d /tmp/opt060.XXXXXX)"
API_PID=""

cleanup() {
  if [ -n "$API_PID" ]; then kill "$API_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-060 — admin JWT auth + staging reviewer seed"
echo "═══════════════════════════════════════════════════════════════"

# ── Build + start the API under test ────────────────────────────────────────
go build -o "$TMP/samay-api-server" ./cmd/samay-api-server || { echo "build failed" >&2; exit 1; }
env -u ADMIN_API_KEY -u SUPABASE_ADMIN_USER_ID \
  SUPABASE_URL="http://127.0.0.1:${KONG_PORT}" \
  SUPABASE_SERVICE_ROLE_KEY="$SERVICE_KEY" \
  SUPABASE_JWT_SECRET="$JWT_SECRET" \
  PORT="$API_PORT" \
  "$TMP/samay-api-server" >"$TMP/api.log" 2>&1 &
API_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "$BASE/api/v1/health" >/dev/null 2>&1 && break
  sleep 0.2
done
if ! curl -fsS "$BASE/api/v1/health" >/dev/null 2>&1; then
  echo "API server did not start; log:" >&2
  cat "$TMP/api.log" >&2
  exit 1
fi

ADMIN_JWT="$(mint_jwt "$ADMIN_ID" authenticated authenticated 3600)"
USER_JWT="$(mint_jwt "$NONADMIN_ID" authenticated authenticated 3600)"
EXPIRED_JWT="$(mint_jwt "$ADMIN_ID" authenticated authenticated -60)"
WRONG_AUD_JWT="$(mint_jwt "$ADMIN_ID" other authenticated 3600)"

# ── SEC-016: token validation ──────────────────────────────────────────────
echo ""
echo "━━━ SEC-016 token validation ━━━"
check "no token -> 401" 401 "$(code "$BASE/api/v1/admin/config")"
check "garbage token -> 401" 401 "$(code -H 'Authorization: Bearer garbage' "$BASE/api/v1/admin/config")"
check "expired JWT -> 401" 401 "$(code -H "Authorization: Bearer $EXPIRED_JWT" "$BASE/api/v1/admin/config")"
check "wrong audience -> 401" 401 "$(code -H "Authorization: Bearer $WRONG_AUD_JWT" "$BASE/api/v1/admin/config")"
check "valid non-admin JWT -> 403" 403 "$(code -H "Authorization: Bearer $USER_JWT" "$BASE/api/v1/admin/config")"
check "admin JWT -> 200" 200 "$(code -H "Authorization: Bearer $ADMIN_JWT" "$BASE/api/v1/admin/config")"

# The legacy shared key must no longer work.
check "legacy ADMIN_API_KEY -> 401" 401 "$(code -H 'Authorization: Bearer legacy-shared-key' "$BASE/api/v1/admin/config")"

# ── SEC-016: audit actor equals JWT sub ────────────────────────────────────
echo ""
echo "━━━ SEC-016 audit actor ━━━"
check "admin mutation -> 200" 200 "$(code -X POST \
  -H "Authorization: Bearer $ADMIN_JWT" -H 'Content-Type: application/json' \
  -d '{"value":"300"}' "$BASE/api/v1/admin/config/app.search_debounce_ms")"
AUDIT_ACTOR="$(psql_db -c "SELECT admin_user_id::text FROM public.admin_audit_log WHERE action='config_set' AND target_id='app.search_debounce_ms' ORDER BY created_at DESC LIMIT 1;")"
check "audit admin_user_id == JWT sub" "$ADMIN_ID" "$AUDIT_ACTOR"

# ── SEC-016: body cap + rate limit ─────────────────────────────────────────
echo ""
echo "━━━ SEC-016 request limits ━━━"
python3 -c 'import sys; sys.stdout.write("a" * (200 * 1024))' >"$TMP/big.json"
check "200 KiB body -> 413" 413 "$(code -X POST \
  -H "Authorization: Bearer $ADMIN_JWT" -H 'Content-Type: application/json' \
  --data-binary "@$TMP/big.json" "$BASE/api/v1/admin/config/app.search_debounce_ms")"

LIMITED=0
RETRY_AFTER=""
for _ in $(seq 1 80); do
  status="$(code "$BASE/api/v1/admin/config")"
  if [ "$status" = "429" ]; then
    LIMITED=1
    RETRY_AFTER="$(curl -sS -o /dev/null -D - "$BASE/api/v1/admin/config" 2>/dev/null | awk -F': ' 'tolower($1)=="retry-after"{print $2}' | tr -d '\r')"
    break
  fi
done
if [ "$LIMITED" = "1" ]; then
  ok "burst over per-IP limit -> 429"
  if [ -n "$RETRY_AFTER" ]; then ok "429 carries Retry-After ($RETRY_AFTER)"; else bad "429 missing Retry-After"; fi
else
  bad "burst over per-IP limit did not return 429"
fi

# ── SEC-028: staging-only reviewer seed ────────────────────────────────────
echo ""
echo "━━━ SEC-028 reviewer seed ━━━"
BEFORE="$(psql_db -c "SELECT count(*) FROM auth.users WHERE email='tester@qallariy.lat';")"
check "default reset has zero reviewer rows" "0" "$BEFORE"

REVIEWER_PASSWORD="LaneAReviewer-2026-Test"
SAMAY_ENV=staging STACK_ENV="$STACK_ENV" REVIEWER_PASSWORD="$REVIEWER_PASSWORD" \
  bash tools/seed-reviewer.sh >/dev/null || bad "reviewer seed (first run) failed"
HASH1="$(psql_db -c "SELECT encrypted_password FROM auth.users WHERE email='tester@qallariy.lat';")"
COUNT1="$(psql_db -c "SELECT count(*) FROM auth.users WHERE email='tester@qallariy.lat';")"
check "staging seed creates exactly one reviewer" "1" "$COUNT1"
if [ -n "$HASH1" ] && [ "$HASH1" != "$REVIEWER_PASSWORD" ]; then
  ok "reviewer password is hashed (bcrypt)"
else
  bad "reviewer password was not hashed"
fi

SAMAY_ENV=staging STACK_ENV="$STACK_ENV" REVIEWER_PASSWORD="$REVIEWER_PASSWORD" \
  bash tools/seed-reviewer.sh >/dev/null || bad "reviewer seed (second run) failed"
HASH2="$(psql_db -c "SELECT encrypted_password FROM auth.users WHERE email='tester@qallariy.lat';")"
COUNT2="$(psql_db -c "SELECT count(*) FROM auth.users WHERE email='tester@qallariy.lat';")"
check "second seed keeps exactly one reviewer" "1" "$COUNT2"
check "second seed does not change the bcrypt hash" "$HASH1" "$HASH2"

# Staging gate: a non-staging env must refuse before touching the DB.
if SAMAY_ENV=prod REVIEWER_PASSWORD="$REVIEWER_PASSWORD" STACK_ENV="$STACK_ENV" \
   bash tools/seed-reviewer.sh >/dev/null 2>&1; then
  bad "seed-reviewer.sh accepted SAMAY_ENV=prod"
else
  ok "seed-reviewer.sh refuses SAMAY_ENV=prod"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  OPT-060 PASSED ($PASS checks)"
  exit 0
fi
echo "  OPT-060 FAILED: $PASS passed, $FAIL failed"
exit 1
