#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-014] Profile-RPC lockdown — Integration Test (baseline 020_core/
# 02_users.sql, 2026-08-25 directive)
# -----------------------------------------------------------------------------
# Verifies that clients can ONLY mutate public.users through the SECURITY
# DEFINER RPC family, which sanitizes + validates server-side:
#
#   1) create_my_profile: happy path (sanitized username + economy defaults +
#      atomic shard_ledger grant), duplicate block, username policy raises,
#      DOB rules
#   2) update_my_profile: bio set/clear/cap + DOB set-once enforcement
#   3) DIRECT table writes by clients are DENIED (table-level REVOKE):
#      PATCH users and POST users with a real user/anon token must fail with
#      permission denied — THE core pin of the lockdown
#   4) setter RPCs (avatar/discovery/read_receipts/profile_public) persist
#   5) delete_my_account tombstones the row; re-create stays blocked
#   6) own-row SELECT still works through RLS (read path unchanged)
#
# SELF-CONTAINED (fixed UUIDs unique to this file — 1414... family).
# Cleanup removes the auth user + users rows on exit.
#
# Usage: bash test/opt-014-profile-rpc.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0

# GoTrue assigns the uuid on admin-create — every row-level check below
# uses the RETURNED id (UID_A), never a client-chosen constant.
UID_A=""
EMAIL_A="user_a_opt014@samay.test"
PW="Pass1234!"

cleanup() {
  if [ -n "$UID_A" ]; then
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$UID_A" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
    svc_delete_quiet "users?id=eq.$UID_A"
  fi
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$f" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
    -H "Content-Type: application/json" -d "$d"
}
anon_rpc() {
  local f=$1 d=$2
  curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$f" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" -d "$d"
}
svc_get() {
  curl -s "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
}

trap cleanup EXIT

echo ""
h1 "0) Fixture: auth user + login"
# Self-heal: remove any orphan from a previous aborted run (lookup by email).
ORPHAN=$(curl -s "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);u=[x for x in d.get('users',[]) if x.get('email')=='$EMAIL_A'];print(u[0]['id'] if u else '')")
if [ -n "$ORPHAN" ]; then
  curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$ORPHAN" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null
  svc_delete_quiet "users?id=eq.$ORPHAN"
fi
CREATE_CODE=$(curl -s -o /tmp/opt014_user.json -w "%{http_code}" \
  -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\",\"email_confirm\":true}")
if [ "$CREATE_CODE" = "200" ] || [ "$CREATE_CODE" = "201" ]; then
  UID_A=$(python3 -c "import json;print(json.load(open('/tmp/opt014_user.json'))['id'])")
  ok "auth user created ($CREATE_CODE) id=$UID_A"
else
  nok "auth user creation failed ($CREATE_CODE)"; cat /tmp/opt014_user.json; exit 1
fi

LOGIN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}")
TOKEN=$(echo "$LOGIN" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN" ]; then ok "login OK (token acquired)"; else
  nok "login failed"; exit 1; fi

# ─── 1) create_my_profile ──────────────────────────────────────────────
h1 "1) create_my_profile"
BODY=$(auth_rpc "$TOKEN" "create_my_profile" '{"p_username":"  Sofia  ","p_date_of_birth":"2000-01-15"}')
CODE=$(echo "$BODY" | tail -1)
if [ "$CODE" = "204" ]; then ok "happy path → 204"; else nok "expected 204 got $CODE: $BODY"; fi

ROW=$(svc_get "users?id=eq.$UID_A&select=username,personal_shards,preshards,subscription_tier,bio,avatar_url,banned_at,deleted_at")
if echo "$ROW" | grep -q '"username":"Sofia"' && echo "$ROW" | grep -q '"subscription_tier":"free"' && echo "$ROW" | grep -q '"preshards":0'; then
  ok "row sanitized + defaults (username=Sofia, free tier, preshards=0)"
else nok "row shape wrong: $ROW"; fi

LEDGER=$(PGPASSWORD=postgres psql -tA "$PGURL" -c "SELECT delta >= 0 AND reason = 'admin_grant' FROM shard_ledger WHERE user_id='$UID_A'")
if [ "$LEDGER" = "t" ]; then ok "shard_ledger signup grant written atomically"; else nok "ledger grant missing: $LEDGER"; fi

BODY=$(auth_rpc "$TOKEN" "create_my_profile" '{"p_username":"sofia","p_date_of_birth":"2000-01-15"}')
if echo "$BODY" | grep -q "Tu perfil ya existe"; then ok "duplicate blocked"; else nok "duplicate not blocked: $BODY"; fi

BODY=$(auth_rpc "$TOKEN" "create_my_profile" '{"p_username":"abc","p_date_of_birth":"2000-01-15"}')
if echo "$BODY" | grep -q "Debe tener al menos 5 caracteres"; then ok "short username raised"; else nok "short username: $BODY"; fi

LONG=$(python3 -c "print('x'*65)")
BODY=$(auth_rpc "$TOKEN" "create_my_profile" "{\"p_username\":\"$LONG\",\"p_date_of_birth\":\"2000-01-15\"}")
if echo "$BODY" | grep -q "demasiado largo"; then ok "65-char username raised"; else nok "long username: $BODY"; fi

BODY=$(auth_rpc "$TOKEN" "create_my_profile" '{"p_username":"sofia","p_date_of_birth":"2020-01-01"}')
if echo "$BODY" | grep -q "18 años"; then ok "underage DOB raised"; else nok "underage DOB: $BODY"; fi

BODY=$(anon_rpc "create_my_profile" '{"p_username":"sofia","p_date_of_birth":"2000-01-15"}')
if echo "$BODY" | grep -q "No autenticado\|permission denied\|401\|403"; then ok "anon create denied"; else nok "anon create: $BODY"; fi

# ─── 2) update_my_profile ──────────────────────────────────────────────
h1 "2) update_my_profile"
BODY=$(auth_rpc "$TOKEN" "update_my_profile" '{"p_bio":"  Hola mundo ","p_date_of_birth":null}')
CODE=$(echo "$BODY" | tail -1)
BIO=$(svc_get "users?id=eq.$UID_A&select=bio" | grep -o '"bio":"[^"]*"')
if [ "$CODE" = "204" ] && [ "$BIO" = '"bio":"Hola mundo"' ]; then ok "bio set + trimmed"; else nok "bio set: $CODE $BIO"; fi

BODY=$(auth_rpc "$TOKEN" "update_my_profile" '{"p_bio":"","p_date_of_birth":null}')
BIO=$(svc_get "users?id=eq.$UID_A&select=bio")
if echo "$BODY" | tail -1 | grep -q "204" && echo "$BIO" | grep -q '"bio":null'; then ok "empty bio clears to NULL"; else nok "bio clear: $BODY $BIO"; fi

LONG_BIO=$(python3 -c "print('b'*161)")
BODY=$(auth_rpc "$TOKEN" "update_my_profile" "{\"p_bio\":\"$LONG_BIO\",\"p_date_of_birth\":null}")
if echo "$BODY" | grep -q "no puede superar 160"; then ok "161-char bio raised"; else nok "long bio: $BODY"; fi

# Profile was created WITH a DOB → identical re-submission is an allowed
# no-op; ANY different value is refused (set-once, age gate stays unfarmable).
BODY=$(auth_rpc "$TOKEN" "update_my_profile" '{"p_bio":null,"p_date_of_birth":"2000-01-15"}')
BODY2=$(auth_rpc "$TOKEN" "update_my_profile" '{"p_bio":null,"p_date_of_birth":"1999-06-06"}')
if echo "$BODY" | tail -1 | grep -q "204" && echo "$BODY2" | grep -q "no puede modificarse"; then
  ok "DOB set-once enforced (identical no-op allowed, change refused)"
else nok "DOB set-once: $BODY / $BODY2"; fi

# ─── 3) DIRECT writes are DENIED ───────────────────────────────────────
h1 "3) Direct client writes are DENIED (core pin)"
PATCH=$(curl -s -w "\n%{http_code}" -X PATCH "$SUPABASE_URL/rest/v1/users?id=eq.$UID_A" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d '{"personal_shards":999999,"bio":"hacked"}')
PATCH_CODE=$(echo "$PATCH" | tail -1)
if [ "$PATCH_CODE" = "403" ] || echo "$PATCH" | grep -qi "permission denied"; then
  ok "authenticated direct PATCH denied ($PATCH_CODE)"
else nok "direct PATCH NOT denied: $PATCH"; fi

ANON_INS=$(curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/users" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"id\":\"$UID_A\",\"username\":\"hacker\"}")
if echo "$ANON_INS" | grep -qi "permission denied" || [ "$(echo "$ANON_INS" | tail -1)" = "403" ]; then
  ok "anon direct INSERT denied"
else nok "anon INSERT NOT denied: $ANON_INS"; fi

SEL=$(curl -s -o /dev/null -w "%{http_code}" "$SUPABASE_URL/rest/v1/users?id=eq.$UID_A&select=username" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN")
if [ "$SEL" = "200" ]; then ok "own-row SELECT still works (RLS read path intact)"; else nok "own-row SELECT broken: $SEL"; fi

# ─── 4) setter RPCs ────────────────────────────────────────────────────
h1 "4) Setter RPCs"
for pair in \
  "set_avatar_url|{\"p_avatar_url\":\"https://cdn.example/a.png\"}|avatar_url|https://cdn.example/a.png" \
  "set_discovery_opt_in|{\"p_value\":true}|discovery_opt_in|true" \
  "set_read_receipts_enabled|{\"p_value\":false}|read_receipts_enabled|false" \
  "set_profile_public|{\"p_value\":true}|profile_public|true"; do
  IFS='|' read -r fn payload col want <<< "$pair"
  BODY=$(auth_rpc "$TOKEN" "$fn" "$payload")
  GOT=$(svc_get "users?id=eq.$UID_A&select=$col" | grep -o "\"$col\":[^}]*")
  if echo "$BODY" | tail -1 | grep -q "204" && echo "$GOT" | grep -q "$want"; then
    ok "$fn persists"
  else nok "$fn: $BODY / $GOT"; fi
done

BODY=$(auth_rpc "$TOKEN" "set_avatar_url" '{"p_avatar_url":"http://insecure.example/a.png"}')
if echo "$BODY" | grep -q "La URL del avatar no es válida"; then ok "non-https avatar rejected"; else nok "insecure URL: $BODY"; fi

# ─── 5) delete_my_account ──────────────────────────────────────────────
h1 "5) delete_my_account"
BODY=$(auth_rpc "$TOKEN" "delete_my_account" '{}')
CODE=$(echo "$BODY" | tail -1)
ROW=$(svc_get "users?id=eq.$UID_A&select=id")
if [ "$CODE" = "204" ] && [ "$ROW" = "[]" ]; then
  ok "Q1 hard delete removes the users row immediately"
else nok "delete: $CODE $ROW"; fi

BODY=$(auth_rpc "$TOKEN" "create_my_profile" '{"p_username":"sofia2","p_date_of_birth":"2000-01-15"}')
if echo "$BODY" | tail -1 | grep -q "204"; then ok "Q1: identity can create a fresh profile (no tombstone/restore)"; else nok "re-create: $BODY"; fi

# ─── Summary ───────────────────────────────────────────────────────────
echo ""
echo "═════════════════════════════════════════════════════════════"
echo "  OPT-014: $PASS passed, $FAIL failed"
echo "═════════════════════════════════════════════════════════════"
[ "$FAIL" = "0" ] && exit 0 || exit 1
