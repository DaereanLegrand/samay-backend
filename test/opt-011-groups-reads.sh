#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-011] Group Read Receipts — Integration Test (20260817000006)
# -----------------------------------------------------------------------------
# Verifies the per-member read-receipt contract (the ISSUE 2026-08-17 fix:
# in a GROUP chat the sender's blue check must require EVERY other member's
# read — the 1:1 messages.read_at column cannot express that, so reads are
# tracked per (message, reader) in `message_reads`):
#
#   1) a group participant calling mark_group_messages_read writes exactly
#      ONE message_reads row per other member's message (idempotent)
#   1b) a member cannot SELF-STAMP a receipt on their own message (the
#      direct-insert path is closed by message_reads_insert_own)
#   2) the SENDER sees the read rows (participant SELECT policy — the UI
#      counts them for the blue check)
#   3) another participant sees them too (everyone sees who read what)
#   4) a NON-participant cannot mark reads (RPC) nor read the rows (RLS)
#   5) the group RPC does NOT stamp the 1:1 messages.read_at column — the
#      group read state lives in message_reads only
#   6) the 1:1 path is unchanged: mark_messages_read still stamps
#      messages.read_at in a DIRECT chat
#   7) distribution rows (recipient_id IS NOT NULL) are never marked read
#   8) anon is denied the RPC and the message_reads table
#
# SELF-CONTAINED (fixed UUIDs unique to this file — 8888... family).
# Cleanup runs in dependency order (message_reads → messages → participants
# → chats → group_members → groups → users → auth users).
#
# Usage: bash test/opt-011-groups-reads.sh
#
# Keys: ANON_KEY / SERVICE_KEY default to the DEV values from supabase/.env
# (dev-only); PGURL overrides the psql DSN.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0

# Fixed IDs (8888... family — unique to this file).
UUID_A="88888888-8888-8888-8888-888888888801"
UUID_B="88888888-8888-8888-8888-888888888802"
UUID_C="88888888-8888-8888-8888-888888888803"
UUID_D="88888888-8888-8888-8888-888888888804"   # NON-member (the adversary)
EMAIL_A="user_a_opt011@samay.test"
EMAIL_B="user_b_opt011@samay.test"
EMAIL_C="user_c_opt011@samay.test"
EMAIL_D="user_d_opt011@samay.test"
PW="Pass1234!"
GROUP_ID="88888888-8888-8888-8888-888888888811"
CHAT_GROUP="88888888-8888-8888-8888-888888888821"
CHAT_DIRECT="88888888-8888-8888-8888-888888888822"
MSG_G1="88888888-8888-8888-8888-888888888831"   # A → group (regular message)
MSG_G2="88888888-8888-8888-8888-888888888832"   # B → group
MSG_DIST="88888888-8888-8888-8888-888888888833" # distribution row (recipient_id set)
MSG_D1="88888888-8888-8888-8888-888888888834"   # B → direct chat to A

# Opaque base64url E2EE-style envelopes (the server never inspects content).
ENV_A="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDExQQ"
ENV_B="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDExQg"

cleanup() {
  svc_delete_quiet "message_reads?message_id=in.($MSG_G1,$MSG_G2,$MSG_DIST,$MSG_D1)"
  svc_delete_quiet "messages?chat_id=in.($CHAT_GROUP,$CHAT_DIRECT)"
  svc_delete_quiet "chat_participants?chat_id=in.($CHAT_GROUP,$CHAT_DIRECT)"
  svc_delete_quiet "chats?id=in.($CHAT_GROUP,$CHAT_DIRECT)"
  svc_delete_quiet "group_members?group_id=eq.$GROUP_ID"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C,$UUID_D)"
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

anon_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY"
}
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
svc_patch() {
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}
user_insert_msg() { # $1 token $2 body → http_code
  curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/messages" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d "$2"
}

# ---------------------------------------------------------------------------
h1 "SETUP: users A (group creator), B, C (members), D (non-member)"
# ---------------------------------------------------------------------------
trap cleanup EXIT
cleanup

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
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_C\",\"role\":\"member\",\"status\":\"active\"}"
svc_post "chats" "{\"id\":\"$CHAT_GROUP\",\"type\":\"group\",\"reference_id\":\"$GROUP_ID\"}"
# The chats INSERT trigger backfills chat_participants for active members
# (20260817000002 D1c) — the group chat is first-class immediately.
# A's message (regular) + B's message + one DISTRIBUTION row (recipient_id).
user_insert_msg "$TOK_A" "{\"id\":\"$MSG_G1\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_A\"}" > /dev/null
user_insert_msg "$TOK_B" "{\"id\":\"$MSG_G2\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_B\"}" > /dev/null
svc_post "messages" "{\"id\":\"$MSG_DIST\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_A\",\"recipient_id\":\"$UUID_B\"}"

# A DIRECT chat A↔B (the 1:1 read_at path must stay untouched).
svc_post "chats" "{\"id\":\"$CHAT_DIRECT\",\"type\":\"direct\",\"reference_id\":null}"
svc_post "chat_participants" "{\"chat_id\":\"$CHAT_DIRECT\",\"user_id\":\"$UUID_A\"}"
svc_post "chat_participants" "{\"chat_id\":\"$CHAT_DIRECT\",\"user_id\":\"$UUID_B\"}"
user_insert_msg "$TOK_B" "{\"id\":\"$MSG_D1\",\"chat_id\":\"$CHAT_DIRECT\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_B\"}" > /dev/null

# ---------------------------------------------------------------------------
h1 "1) mark_group_messages_read writes one receipt per OTHER member's message"
# ---------------------------------------------------------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_group_messages_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOK_B" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
if [ "$CODE" = "204" ]; then ok "B marks the group chat read (204)"; else nok "B marks the group chat read (got $CODE)"; fi

# B's own message (MSG_G2) must NOT be marked; A's message (MSG_G1) must; the
# distribution row (MSG_DIST) must NEVER be marked (control row).
ROWS=$(svc_get "message_reads?message_id=in.($MSG_G1,$MSG_G2,$MSG_DIST,$MSG_D1)&select=message_id,user_id&order=message_id")
if echo "$ROWS" | grep -q '"message_id":"'$(echo $MSG_G1 | tr 'A-F' 'a-f')'"' \
   || echo "$ROWS" | grep -q '"message_id":"'$MSG_G1'"'; then
  ok "message_reads contains a row for A's message"
else
  nok "message_reads contains a row for A's message ($ROWS)"
fi
COUNT=$(echo "$ROWS" | grep -o '"message_id"' | wc -l | tr -d ' ')
if [ "$COUNT" = "1" ]; then
  ok "exactly 1 receipt after B's first mark (own message excluded)"
else
  nok "exactly 1 receipt after B's first mark (got $COUNT: $ROWS)"
fi
if echo "$ROWS" | grep -qi "$(echo $MSG_DIST | tr 'A-F' 'a-f')" || echo "$ROWS" | grep -qi "$MSG_DIST"; then
  nok "distribution rows are never marked read"
else
  ok "distribution rows are never marked read"
fi

# Idempotent: a second mark adds nothing.
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_group_messages_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOK_B" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
COUNT2=$(svc_get "message_reads?message_id=in.($MSG_G1,$MSG_G2,$MSG_DIST,$MSG_D1)&select=message_id" | grep -o '"message_id"' | wc -l | tr -d ' ')
if [ "$COUNT2" = "1" ]; then
  ok "marking twice is idempotent (still 1 receipt)"
else
  nok "marking twice is idempotent (got $COUNT2)"
fi

# ---------------------------------------------------------------------------
h1 "1b) a member cannot SELF-STAMP a receipt on their own message (verifier "
h1 "     fix 2026-08-17: message_reads_insert_own excludes sender_id = me)"
# ---------------------------------------------------------------------------
# B directly POSTs a receipt for B's OWN message (MSG_G2) — the INSERT
# policy's `m.sender_id <> auth.uid()` term must reject it (the RPC already
# excludes own messages; this closes the direct-insert path).
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/message_reads" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOK_B" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"message_id\":\"$MSG_G2\",\"user_id\":\"$UUID_B\"}")
COUNT_SELF=$(svc_get "message_reads?message_id=in.($MSG_G1,$MSG_G2,$MSG_DIST,$MSG_D1)&select=message_id" | grep -o '"message_id"' | wc -l | tr -d ' ')
if [ "$COUNT_SELF" = "1" ]; then
  ok "self-stamping a receipt on one's OWN message is rejected (count stays 1)"
else
  nok "self-stamping a receipt on one's OWN message is rejected (got $COUNT_SELF, code $CODE)"
fi

# ---------------------------------------------------------------------------
h1 "2) participants can READ the receipts (sender + other members)"
# ---------------------------------------------------------------------------
A_ROWS=$(auth_get "$TOK_A" "message_reads?select=message_id,user_id")
if echo "$A_ROWS" | grep -q '"user_id"' && ! echo "$A_ROWS" | grep -q "permission denied"; then
  ok "the SENDER (A) sees the read rows"
else
  nok "the SENDER (A) sees the read rows ($A_ROWS)"
fi
C_ROWS=$(auth_get "$TOK_C" "message_reads?select=message_id,user_id")
if echo "$C_ROWS" | grep -q '"user_id"' && ! echo "$C_ROWS" | grep -q "permission denied"; then
  ok "another member (C) sees the read rows"
else
  nok "another member (C) sees the read rows ($C_ROWS)"
fi

# ---------------------------------------------------------------------------
h1 "3) a NON-member cannot mark reads nor read the receipts"
# ---------------------------------------------------------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_group_messages_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOK_D" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
if [ "$CODE" = "403" ] || [ "$CODE" = "400" ]; then
  ok "non-member D is denied the RPC (got $CODE)"
else
  nok "non-member D is denied the RPC (got $CODE)"
fi
D_ROWS=$(auth_get "$TOK_D" "message_reads?select=message_id,user_id")
if echo "$D_ROWS" | grep -qE '^\[\]|permission denied|42501'; then
  ok "non-member D sees NO receipts (RLS)"
else
  nok "non-member D sees NO receipts ($D_ROWS)"
fi

# ---------------------------------------------------------------------------
h1 "4) the group RPC never touches the 1:1 read_at column"
# ---------------------------------------------------------------------------
READ_AT=$(svc_get "messages?select=read_at&id=eq.$MSG_G1")
if echo "$READ_AT" | grep -q '"read_at":null'; then
  ok "messages.read_at stays NULL in the group chat (reads live in message_reads)"
else
  nok "messages.read_at stays NULL in the group chat ($READ_AT)"
fi

# ---------------------------------------------------------------------------
h1 "5) the 1:1 path is unchanged (mark_messages_read stamps read_at)"
# ---------------------------------------------------------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_messages_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOK_A" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_DIRECT\"}")
if [ "$CODE" = "204" ]; then ok "A marks the direct chat read (204)"; else nok "A marks the direct chat read (got $CODE)"; fi
READ_AT1=$(svc_get "messages?select=read_at&id=eq.$MSG_D1")
if echo "$READ_AT1" | grep -q '"read_at":' && ! echo "$READ_AT1" | grep -q '"read_at":null'; then
  ok "the direct-chat message received a read_at stamp (1:1 unchanged)"
else
  nok "the direct-chat message received a read_at stamp ($READ_AT1)"
fi

# ---------------------------------------------------------------------------
h1 "6) anon is denied the RPC and the table"
# ---------------------------------------------------------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_group_messages_read" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
# Denial shapes observed on this stack: 401 (Kong/JWT gate — no session),
# 403 (PostgREST — EXECUTE revoked from anon), 400 (the function raised).
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ] || [ "$CODE" = "400" ]; then
  ok "anon is denied the RPC (got $CODE)"
else
  nok "anon is denied the RPC (got $CODE)"
fi
ANON_ROWS=$(anon_get "message_reads?select=message_id")
if echo "$ANON_ROWS" | grep -qE '^\[\]|permission denied|42501'; then
  ok "anon sees NO receipts"
else
  nok "anon sees NO receipts ($ANON_ROWS)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  OPT-011 RESULT: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
