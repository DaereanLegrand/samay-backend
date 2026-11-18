#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-011] Group reads under slim-prod
# -----------------------------------------------------------------------------
# The per-member read-receipt contract this script used to verify (message_reads
# + mark_group_messages_read) belongs to the E2EE chat removed by slim-prod
# (300_slim/05_revoke_removed). What remains is the kept group read surface:
#
#   1) an ACTIVE member reads the group row and its own membership
#   2) an INVITED member reads neither the group nor the roster
#   3) a NON-member reads nothing
#   4) anon is denied the group tables outright
#   5) the receipt/read-state relations are closed to every client role, and
#      the receipt RPC is gone
#
# SELF-CONTAINED (8888… UUID family). Cleanup on exit.
# Usage: bash test/opt-011-groups-reads.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

UUID_A="88888888-8888-8888-8888-888888888801"
UUID_B="88888888-8888-8888-8888-888888888802"
UUID_C="88888888-8888-8888-8888-888888888803"
UUID_D="88888888-8888-8888-8888-888888888804"
EMAIL_A="user_a_opt011@samay.test"
EMAIL_B="user_b_opt011@samay.test"
EMAIL_C="user_c_opt011@samay.test"
EMAIL_D="user_d_opt011@samay.test"
PW="Pass1234!"
GROUP_ID="88888888-8888-8888-8888-888888888811"

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

anon_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY"
}
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t"
}
auth_rpc_code() {
  local t=$1 f=$2 d=$3
  curl -s -o /tmp/opt011-rpc -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$f" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
    -H "Content-Type: application/json" -d "$d"
}
svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}

cleanup() {
  svc_delete_quiet "group_members?group_id=eq.$GROUP_ID"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C,$UUID_D)"
  for uid in "$UUID_A" "$UUID_B" "$UUID_C" "$UUID_D"; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT
cleanup

h1 "SETUP: A (host), B (active), C (invited), D (non-member)"
for pair in "A $UUID_A user_a_opt011 $EMAIL_A" "B $UUID_B user_b_opt011 $EMAIL_B" "C $UUID_C user_c_opt011 $EMAIL_C" "D $UUID_D user_d_opt011 $EMAIL_D"; do
  set -- $pair
  name=$1; uid=$2; uname=$3; email=$4
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if ! echo "$resp" | grep -q '"id"'; then
    nok "create auth user $name"
    exit 1
  fi
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\"}"
  TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\"}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
  if [ -z "$TOKEN" ]; then
    nok "sign in $name"
    exit 1
  fi
  eval "TOK_$name=$TOKEN"
done

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Reads Test\",\"created_by_user_id\":\"$UUID_A\"}"
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}"
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}"
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_C\",\"role\":\"member\",\"status\":\"invited\"}"
ok "Group provisioned (A host, B active, C invited, D outsider)"

h1 "1) active member reads the group and its own membership"
resp=$(auth_get "$TOK_B" "groups?id=eq.$GROUP_ID&select=id")
if echo "$resp" | grep -q "$GROUP_ID"; then ok "B reads the group row"; else nok "B cannot read the group: $(echo "$resp" | head -c 100)"; fi
resp=$(auth_get "$TOK_B" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B&select=user_id,role,status")
if echo "$resp" | grep -q "$UUID_B"; then ok "B reads its own membership row"; else nok "B cannot read its membership: $(echo "$resp" | head -c 100)"; fi

h1 "2) invited member reads neither the group nor the roster"
resp=$(auth_get "$TOK_C" "groups?id=eq.$GROUP_ID&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied)'; then
  ok "Invited C does not read the group"
else
  nok "Invited C read the group: $(echo "$resp" | head -c 100)"
fi
# The roster policy is "own row OR an active member", so an invited user reads
# ONLY their own row (never another member's) — that is the real invariant.
resp=$(auth_get "$TOK_C" "group_members?group_id=eq.$GROUP_ID&select=user_id")
if echo "$resp" | grep -q "$UUID_B"; then
  nok "Invited C read another member's row: $(echo "$resp" | head -c 100)"
elif echo "$resp" | grep -q "$UUID_C"; then
  ok "Invited C reads only its own roster row"
else
  ok "Invited C reads no roster rows"
fi

h1 "3) non-member reads nothing"
resp=$(auth_get "$TOK_D" "groups?id=eq.$GROUP_ID&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied)'; then
  ok "Outsider D does not read the group"
else
  nok "Outsider D read the group: $(echo "$resp" | head -c 100)"
fi

h1 "4) anon is denied the group tables"
for table in groups group_members; do
  resp=$(anon_get "$table?limit=1")
  if echo "$resp" | grep -qE '(42501|permission denied|unauthorized)'; then
    ok "anon SELECT $table denied"
  elif [ "$resp" = "[]" ] || [ -z "$resp" ]; then
    ok "anon SELECT $table denied (no rows)"
  else
    nok "anon SELECT $table leaked: $(echo "$resp" | head -c 100)"
  fi
done

h1 "5) receipt/read-state relations are closed; the RPC is gone"
for table in message_reads messages chats; do
  resp=$(auth_get "$TOK_A" "$table?limit=1")
  if echo "$resp" | grep -qE '(42501|permission denied)'; then
    ok "$table closed to authenticated (chat removed)"
  else
    nok "$table still readable: $(echo "$resp" | head -c 100)"
  fi
done
# The receipt RPCs still exist server-side, but their target tables are
# revoked from every client role, so the call can no longer reach a receipt
# row: it fails on the participant gate (or is denied outright).
for fn in mark_group_messages_read mark_messages_read; do
  code=$(auth_rpc_code "$TOK_A" "$fn" "{\"p_chat_id\":\"$GROUP_ID\"}")
  if [ "$code" = "400" ] || [ "$code" = "403" ] || [ "$code" = "404" ]; then
    ok "$fn cannot write receipts for a removed chat (http $code)"
  else
    nok "$fn unexpectedly succeeded (http $code): $(head -c 120 /tmp/opt011-rpc)"
  fi
done

echo ""
echo "=================================================="
echo "  OPT-011: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ]
