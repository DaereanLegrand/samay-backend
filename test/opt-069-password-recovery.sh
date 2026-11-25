#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-069] In-app password recovery — Mailpit delivery + app redirect (E3/D4)
# -----------------------------------------------------------------------------
#   1) /auth/v1/recover accepts the request for a real account
#   2) Mailpit receives the recovery email
#   3) the link carries the allow-listed samay://reset-password redirect
#   4) an unknown email still returns 200 (anti-enumeration)
#
# SELF-CONTAINED (7676… UUID family). Cleanup on exit.
# Usage: bash test/opt-069-password-recovery.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAILPIT_PORT="$(awk -F= '/^MAILPIT_PORT=/{print $2}' "$ROOT/.env/testing-local.env" | awk '{print $1}')"
MAILPIT_URL="${MAILPIT_URL:-http://127.0.0.1:${MAILPIT_PORT:-54384}}"
# Default matches the testing-local stack these scripts hit (Kong 54396 →
# Postgres 54392); override PGURL to point psql at another stack.
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54392/postgres}"

PASS=0
FAIL=0
ok()  { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
h1()  { echo ""; echo "━━━ $1 ━━━"; }
q()   { PGPASSWORD=postgres psql "$PGURL" -Atq -v ON_ERROR_STOP=1 -c "$1"; }

UUID="76767676-7676-4676-8676-767676690001"
EMAIL="recovery_opt069_${RANDOM}_$$@samay.test"
PW="Pass1234!"
REDIRECT="samay://reset-password"

cleanup() {
  curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$UUID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
  q "DELETE FROM public.users WHERE id = '$UUID';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

h1 "SETUP: account + a clean Mailpit inbox"
curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID\"}" >/dev/null
q "INSERT INTO public.users (id, username, date_of_birth)
   VALUES ('$UUID', 'opt069_user', '1990-01-01');" >/dev/null
curl -s -X DELETE "$MAILPIT_URL/api/v1/messages" >/dev/null 2>&1

h1 "1) the recovery request is accepted"
# GoTrue's own per-IP flood guard persists between test runs; use a fresh
# Forwarded-For bucket so the suite is idempotent (the E3 per-account reset
# limit is exercised separately).
FORWARD_IP="10.$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1))"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$SUPABASE_URL/auth/v1/recover?redirect_to=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("samay://reset-password",safe=""))')" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -H "X-Forwarded-For: $FORWARD_IP" \
  -d "{\"email\":\"$EMAIL\"}")
[ "$CODE" = "200" ] && ok "recover accepted (200)" || nok "recover (got $CODE)"

h1 "2) Mailpit receives the recovery email"
MSG_ID=""
for _ in $(seq 1 20); do
  MSG_ID=$(curl -s "$MAILPIT_URL/api/v1/messages?limit=20" \
    | python3 -c "import sys,json;
try:
 d=json.load(sys.stdin)
 msgs=d.get('messages') or []
 print(next((m['ID'] for m in msgs if '$EMAIL' in (m.get('To') or [{}])[0].get('Address','')), ''))
except Exception: print('')")
  [ -n "$MSG_ID" ] && break
  sleep 0.5
done
[ -n "$MSG_ID" ] && ok "recovery email delivered" || { nok "recovery email not found"; exit 1; }

h1 "3) the email carries the allow-listed app redirect"
BODY=$(curl -s "$MAILPIT_URL/api/v1/message/$MSG_ID")
python3 - "$BODY" <<'PY'
import json,sys,urllib.parse
d=json.loads(sys.argv[1])
raw=json.dumps(d)
text=d.get('Text','') or ''
ok = ('reset' in raw.lower() or 'recuper' in raw.lower())
red = 'samay%3A%2F%2Freset-password' in raw or 'samay://reset-password' in raw
url_ok = ('reset-password' in text) or ('type=recovery' in text)
print('EMAIL_CHECK', 'ok' if (ok and (red or url_ok)) else 'fail')
PY
CHECK=$(python3 - "$BODY" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); raw=json.dumps(d); text=d.get('Text','') or ''
print('ok' if (('reset' in raw.lower() or 'recuper' in raw.lower()) and
              ('reset-password' in raw or 'type=recovery' in raw or 'reset-password' in text)) else 'fail')
PY
)
[ "$CHECK" = "ok" ] && ok "recovery link points at the app reset screen" || nok "recovery link/redirect missing"

h1 "4) an unknown email still returns 200 (anti-enumeration)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SUPABASE_URL/auth/v1/recover" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d '{"email":"nobody_opt069@samay.test"}')
[ "$CODE" = "200" ] && ok "unknown email is accepted" || nok "unknown email (got $CODE)"

echo ""
echo "=================================================="
echo "  OPT-069: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ]
