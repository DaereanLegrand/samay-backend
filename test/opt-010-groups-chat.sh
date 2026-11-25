#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-010] Group membership surface under slim-prod
# -----------------------------------------------------------------------------
# Slim-prod removed E2EE chat (300_slim/05_revoke_removed revokes chats,
# message_reads, messages and minigame_group_messages from every client role),
# so the group-chat participant-sync contract this script used to verify is
# gone. What remains — and is asserted here — is the kept group surface:
#
#   1) the removed chat relations are closed to client roles (42501)
#   2) get_chat_inbox still answers for an onboarded user (server-mediated
#      inbox; the minigame-notice path is covered by opt-031)
#   3) group_members is still in the supabase_realtime publication
#   4) an ACTIVE member reads the group; an INVITED member does not
#   5) accept_friend_request stays addressee-only / pending-only
#
# SELF-CONTAINED (6666… UUID family). Cleanup on exit.
# Usage: bash test/opt-010-groups-chat.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
# Default matches the testing-local stack these scripts hit (Kong 54396 →
# Postgres 54392); override PGURL to point psql at another stack.
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54392/postgres}"

PASS=0
FAIL=0

UUID_A="66666666-6666-6666-6666-666666666601"
UUID_B="66666666-6666-6666-6666-666666666602"
UUID_C="66666666-6666-6666-6666-666666666603"
EMAIL_A="user_a_opt010@samay.test"
EMAIL_B="user_b_opt010@samay.test"
EMAIL_C="user_c_opt010@samay.test"
PW="Pass1234!"
GROUP_ID="66666666-6666-6666-6666-666666666611"
FR_AC="66666666-6666-6666-6666-666666666641"

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t"
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}
svc_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
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
  svc_delete_quiet "friendships?id=eq.$FR_AC"
  svc_delete_quiet "friendships?requester_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "friendships?addressee_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "group_members?group_id=eq.$GROUP_ID"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C)"
  for uid in "$UUID_A" "$UUID_B" "$UUID_C"; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT
cleanup

h1 "SETUP: users A (host), B (active member), C (invited member)"
for pair in "A $UUID_A user_a_opt010 $EMAIL_A" "B $UUID_B user_b_opt010 $EMAIL_B" "C $UUID_C user_c_opt010 $EMAIL_C"; do
  set -- $pair
  name=$1; uid=$2; uname=$3; email=$4
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if echo "$resp" | grep -q '"id"'; then ok "Created auth user $name"; else nok "Create user $name: $(echo "$resp" | head -c 80)"; fi
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\",\"age_confirmed_at\":\"2026-01-01T00:00:00Z\",\"terms_accepted_at\":\"2026-01-01T00:00:00Z\"}" > /dev/null
done
svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Opt010 Group\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_C\",\"role\":\"member\",\"status\":\"invited\"}" > /dev/null
ok "Group provisioned (A host, B active, C invited)"

TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_B=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_C=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_C\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ]; then
  ok "Obtained auth tokens"
else
  nok "Failed to get auth tokens"
fi

h1 "1) removed chat relations are closed to client roles"
for table in chats messages message_reads minigame_group_messages; do
  resp=$(auth_get "$TOKEN_A" "$table?limit=1")
  if echo "$resp" | grep -qE '(42501|permission denied)'; then
    ok "$table closed to authenticated (removed feature)"
  else
    nok "$table still readable by a client role: $(echo "$resp" | head -c 100)"
  fi
done

h1 "2) get_chat_inbox still answers (server-mediated)"
code=$(curl -s -o /tmp/opt010-inbox -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d '{}')
if [ "$code" = "200" ]; then
  ok "get_chat_inbox returns 200 for an onboarded user"
else
  nok "get_chat_inbox returned $code: $(head -c 120 /tmp/opt010-inbox)"
fi
if [ "$(cat /tmp/opt010-inbox)" = "[]" ] || [ "$(cat /tmp/opt010-inbox)" = "" ]; then
  ok "Inbox is empty (no chats in slim-prod)"
else
  info "Inbox payload: $(head -c 160 /tmp/opt010-inbox)"
fi

h1 "3) group_members is still in the supabase_realtime publication"
if command -v psql > /dev/null 2>&1; then
  cnt=$(psql "$PGURL" -tA -c "SELECT count(*) FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='group_members';" 2>/dev/null)
  if [ "$cnt" = "1" ]; then
    ok "group_members is in supabase_realtime"
  else
    nok "group_members NOT in supabase_realtime (count=$cnt)"
  fi
else
  nok "psql not available — cannot verify the publication"
fi

h1 "4) active member reads the group; invited member does not"
resp=$(auth_get "$TOKEN_B" "groups?id=eq.$GROUP_ID&select=id")
if echo "$resp" | grep -q "$GROUP_ID"; then
  ok "Active member B reads the group"
else
  nok "Active member B cannot read the group: $(echo "$resp" | head -c 100)"
fi
resp=$(auth_get "$TOKEN_C" "groups?id=eq.$GROUP_ID&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied)'; then
  ok "Invited member C does not read the group"
else
  nok "Invited member C read the group: $(echo "$resp" | head -c 100)"
fi

h1 "5) accept_friend_request: addressee-only, pending-only"
svc_post "friendships" "{\"id\":\"$FR_AC\",\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"pending\"}" > /dev/null
resp=$(auth_rpc "$TOKEN_A" "accept_friend_request" "{\"p_friendship_id\":\"$FR_AC\"}")
if echo "$resp" | grep -q "NOT_THE_ADDRESSEE"; then
  ok "Requester A is rejected (NOT_THE_ADDRESSEE)"
else
  nok "Requester A was NOT rejected: $(echo "$resp" | head -c 120)"
fi
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/accept_friend_request" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" -d "{\"p_friendship_id\":\"$FR_AC\"}")
row=$(svc_get "friendships?id=eq.$FR_AC&select=status")
if [ "$code" = "204" ] && echo "$row" | grep -q '"status":"accepted"'; then
  ok "Addressee C accepts and the row flips to accepted"
else
  nok "Addressee C accept failed (http $code): $(echo "$row" | head -c 120)"
fi
resp=$(auth_rpc "$TOKEN_C" "accept_friend_request" "{\"p_friendship_id\":\"$FR_AC\"}")
if echo "$resp" | grep -q "NOT_PENDING"; then
  ok "Accepting an already-accepted row is rejected (NOT_PENDING)"
else
  nok "NOT_PENDING guard missing: $(echo "$resp" | head -c 120)"
fi

echo ""
echo "=================================================="
echo "  OPT-010: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ]
