#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-040] Chat moderation — block enforcement + message report
# (migration 226_chat_moderation)
# Verifies:
#   A) a blocked pair CANNOT open a new direct chat
#      (create_direct_chat -> {"status":"blocked"})
#   B) after unblocking, create_direct_chat returns a chatId
#   C) a direct message inserts/reads back when not blocked
#   D) once blocked, the direct-message INSERT is refused by the
#      assert_message_not_blocked trigger (BLOCKED, either direction)
#   E) report_message writes the reports queue row + the moderator-only
#      message_reports snapshot (plaintext) and flags messages.reported
#   F) a NON-participant report is rejected (not_allowed)
#   G) anon CANNOT call report_message (EXECUTE revoked from PUBLIC/anon)
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup).
# Live run: make start && bash test/opt-040-chat-report-block.sh
#
# Keys resolved at runtime by test/dev_env.sh from supabase/.env.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

UUID_A="66666666-6666-6666-6666-666666666661"
UUID_B="66666666-6666-6666-6666-666666666662"
UUID_C="66666666-6666-6666-6666-666666666663"
EMAIL_A="user_a_opt040@samay.test"
EMAIL_B="user_b_opt040@samay.test"
EMAIL_C="user_c_opt040@samay.test"
PW="Pass1234!"
MSG_1="66666666-6666-6666-6666-666666666501"
ENV_1="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMk.Opt040Msg1"

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

# Robust JSON field reader (PostgREST prints `"key": "value"` with a space, and
# arrays wrap rows): reads stdin, resolves a dotted path, prints the value (or
# nothing). Never fails the test on malformed input.
pyget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, list):
        d = d[0] if d else None
    d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        break
print("" if d is None else d)
' "$1"
}

svc_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}
svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t"
}
auth_post() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Prefer: return=representation" -d "$d"
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}
anon_rpc() {
  local f=$1 d=$2
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -d "$d"
}

cleanup() {
  svc_delete_quiet "message_reports?reporter_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "reports?reporter_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "messages?sender_id=in.($UUID_A,$UUID_B)"
  svc_delete_quiet "chat_participants?user_id=in.($UUID_A,$UUID_B)"
  svc_delete_quiet "chats?type=eq.direct"
  svc_delete_quiet "friendships?requester_id=in.($UUID_A,$UUID_B)"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C)"
  for uid in $UUID_A $UUID_B $UUID_C; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

# ---------------------------------------------------------------------------
h1 "SETUP: users"
trap cleanup EXIT
cleanup

for pair in "A $UUID_A user_a_opt040 $EMAIL_A" "B $UUID_B user_b_opt040 $EMAIL_B" "C $UUID_C user_c_opt040 $EMAIL_C"; do
  set -- $pair
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$4\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$2\"}")
  echo "$resp" | grep -q '"id"' || nok "auth create $1: $(echo "$resp" | head -c 80)"
  svc_post "users" "{\"id\":\"$2\",\"username\":\"$3\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":100}" > /dev/null
done
ok "3 users seeded"

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
  ok "auth tokens obtained"
else
  nok "failed to obtain auth tokens"
fi

# =========================================================================
h1 "TEST A — blocked pair cannot open a direct chat"
# =========================================================================
svc_post "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_B\",\"status\":\"blocked\"}" > /dev/null

status=$(auth_rpc "$TOKEN_A" "create_direct_chat" "{\"p_peer_id\":\"$UUID_B\"}" | pyget status)
if [ "$status" = "blocked" ]; then
  ok "create_direct_chat -> blocked (A blocked B)"
else
  nok "expected blocked, got status='$status'"
fi

status=$(auth_rpc "$TOKEN_B" "create_direct_chat" "{\"p_peer_id\":\"$UUID_A\"}" | pyget status)
if [ "$status" = "blocked" ]; then
  ok "create_direct_chat -> blocked (reverse direction)"
else
  nok "expected blocked (reverse), got status='$status'"
fi

# =========================================================================
h1 "TEST B — unblocked pair opens a direct chat"
# =========================================================================
svc_delete_quiet "friendships?requester_id=eq.$UUID_A&addressee_id=eq.$UUID_B"
CHAT_ID=$(auth_rpc "$TOKEN_A" "create_direct_chat" "{\"p_peer_id\":\"$UUID_B\"}" | pyget chatId)
if [ -n "$CHAT_ID" ]; then
  ok "create_direct_chat -> chatId $CHAT_ID"
else
  nok "create_direct_chat did not return a chatId"
fi

# =========================================================================
h1 "TEST C — direct message inserts/reads when not blocked"
# =========================================================================
msg_id=$(auth_post "$TOKEN_A" "messages" "{\"id\":\"$MSG_1\",\"chat_id\":\"$CHAT_ID\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_1\"}" | pyget id)
if [ "$msg_id" = "$MSG_1" ]; then
  ok "A inserted a direct message"
else
  nok "direct message insert failed (id='$msg_id')"
fi
content=$(auth_get "$TOKEN_B" "messages?id=eq.$MSG_1&select=content" | pyget content)
if [ "$content" = "$ENV_1" ]; then
  ok "B reads the direct message"
else
  nok "B could not read the message (content='$content')"
fi

# =========================================================================
h1 "TEST D — blocked pair cannot exchange direct messages"
# =========================================================================
svc_post "friendships" "{\"requester_id\":\"$UUID_B\",\"addressee_id\":\"$UUID_A\",\"status\":\"blocked\"}" > /dev/null

resp=$(auth_post "$TOKEN_A" "messages" "{\"chat_id\":\"$CHAT_ID\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_1\"}")
if echo "$resp" | grep -qE 'BLOCKED|P0001|42501'; then
  ok "A's direct message refused while blocked"
else
  nok "expected BLOCKED on A's insert, got: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_post "$TOKEN_B" "messages" "{\"chat_id\":\"$CHAT_ID\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_1\"}")
if echo "$resp" | grep -qE 'BLOCKED|P0001|42501'; then
  ok "B's direct message refused while blocked"
else
  nok "expected BLOCKED on B's insert, got: $(echo "$resp" | head -c 120)"
fi

# Unblock so messaging is allowed again for the report step.
svc_delete_quiet "friendships?requester_id=eq.$UUID_B&addressee_id=eq.$UUID_A"

# =========================================================================
h1 "TEST E — report_message writes queue + moderator snapshot"
# =========================================================================
resp=$(auth_rpc "$TOKEN_B" "report_message" "{\"p_message_id\":\"$MSG_1\",\"p_reason\":\"harassment\",\"p_plaintext\":\"hola\"}")
status=$(printf '%s' "$resp" | pyget status)
REPORT_ID=$(printf '%s' "$resp" | pyget report_id)
if [ "$status" = "ok" ] && [ -n "$REPORT_ID" ]; then
  ok "report_message -> ok (report $REPORT_ID)"
else
  nok "report_message failed: $(echo "$resp" | head -c 120)"
fi

tt=$(svc_get "reports?id=eq.$REPORT_ID&select=target_type,target_id,status" | pyget target_type)
tid=$(svc_get "reports?id=eq.$REPORT_ID&select=target_type,target_id,status" | pyget target_id)
st=$(svc_get "reports?id=eq.$REPORT_ID&select=target_type,target_id,status" | pyget status)
if [ "$tt" = "message" ] && [ "$tid" = "$MSG_1" ] && [ "$st" = "pending" ]; then
  ok "reports queue row is target_type=message + pending"
else
  nok "reports row wrong (type=$tt id=$tid status=$st)"
fi

pt=$(svc_get "message_reports?report_id=eq.$REPORT_ID&select=plaintext,sender_id,reporter_id" | pyget plaintext)
sid=$(svc_get "message_reports?report_id=eq.$REPORT_ID&select=plaintext,sender_id,reporter_id" | pyget sender_id)
rid=$(svc_get "message_reports?report_id=eq.$REPORT_ID&select=plaintext,sender_id,reporter_id" | pyget reporter_id)
if [ "$pt" = "hola" ] && [ "$sid" = "$UUID_A" ] && [ "$rid" = "$UUID_B" ]; then
  ok "message_reports snapshot carries the reported plaintext"
else
  nok "message_reports snapshot wrong (plaintext=$pt sender=$sid reporter=$rid)"
fi

reported=$(svc_get "messages?id=eq.$MSG_1&select=reported" | pyget reported)
if [ "$reported" = "True" ]; then
  ok "messages.reported flagged"
else
  nok "messages.reported not set (reported='$reported')"
fi

# =========================================================================
h1 "TEST F — non-participant report rejected"
# =========================================================================
status=$(auth_rpc "$TOKEN_C" "report_message" "{\"p_message_id\":\"$MSG_1\",\"p_reason\":\"spam\",\"p_plaintext\":\"x\"}" | pyget status)
if [ "$status" = "not_allowed" ]; then
  ok "outsider C cannot report the message (not_allowed)"
else
  nok "expected not_allowed, got status='$status'"
fi

# =========================================================================
h1 "TEST G — anon cannot call report_message"
# =========================================================================
resp=$(anon_rpc "report_message" "{\"p_message_id\":\"$MSG_1\",\"p_reason\":\"spam\",\"p_plaintext\":\"x\"}")
if echo "$resp" | grep -qE 'permission denied|PGRST|42501|not_authenticated'; then
  ok "anon report_message denied"
else
  nok "anon report_message was not denied: $(echo "$resp" | head -c 120)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-040: PASS=$PASS FAIL=$FAIL"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
