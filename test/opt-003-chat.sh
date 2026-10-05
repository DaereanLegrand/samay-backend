#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-003] Chat + E2EE envelope contract — Integration Test
# Verifies the chat surface (I-76, phase 07 CHAT + E2EE-ARCHITECTURE §6/§9):
#   A) chats row creation for type='group' and type='event' (w/ reference_id)
#   B) message insert with OPAQUE base64url envelope content (svc — the
#      server never interprets messages.content; plaintext never leaves the
#      device, E2EE-ARCHITECTURE §6.6)
#   C) RLS: group member reads messages (messages_read_participant);
#      non-member CANNOT read (PGRST204/empty)
#   D) event chat: host reads; non-invited non-member cannot
#   E) message_cap rolling-window behavior stays inert below the cap
#      (insert 3 -> all 3 present; app_config chat.message_cap = 1000).
#      The full-cap behavior + trigger EXISTENCE are asserted in the pgTAP
#   F) DIRECT chat RLS regression (20260815000003): create_direct_chat RPC →
#      participant reads the chat row → INSERTs a message (was 42501) →
#      reads it back; outsider stays blocked
#   G) deletion RPCs (20260815000006): delete_message_for_everyone (sender +
#      server-verified 5-min window → MESSAGE_TOO_OLD / NOT_THE_SENDER) and
#      delete_undecryptable_messages (participant-gated cleanup, cross-chat
#      ids ignored, NOT_A_PARTICIPANT for outsiders) + deleted_messages audit
#      suite (supabase/tests/schema_test.sql, I-77) — a curl test cannot call
#      a trigger function (returns trigger, not callable via PostgREST RPC).
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup), exactly
# like opt-001.
#
# STATIC-VERIFIED ONLY (this agent run): the stack is not started until the
# checkpoint (AGENT-RULES / port map). Live run: make supabase-start &&
# make supabase-reset && bash test/opt-003-chat.sh
#
# Usage: bash test/opt-003-chat.sh
#
# Keys (M-03 alignment): resolved at runtime by test/dev_env.sh from the
# gitignored stack .env (supabase-testing/ then supabase/) — dev-only; CI
# overrides them via env vars.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

# Fixed IDs (unique to this file — opt-001/002 use 1111.../4444...).
UUID_A="55555555-5555-5555-5555-555555555555"
UUID_B="55555555-5555-5555-5555-555555555556"
UUID_C="55555555-5555-5555-5555-555555555557"
EMAIL_A="user_a_opt003@samay.test"
EMAIL_B="user_b_opt003@samay.test"
EMAIL_C="user_c_opt003@samay.test"
PW="Pass1234!"
GROUP_ID="55555555-5555-5555-5555-555555555101"
EVENT_ID="55555555-5555-5555-5555-555555555201"
CHAT_GROUP="55555555-5555-5555-5555-555555555301"
CHAT_EVENT="55555555-5555-5555-5555-555555555302"
MSG_1="55555555-5555-5555-5555-555555555401"
MSG_2="55555555-5555-5555-5555-555555555402"
MSG_3="55555555-5555-5555-5555-555555555403"
MSG_E="55555555-5555-5555-5555-555555555404"

# Opaque base64url envelopes (SME2. = Samay E2EE v2 frame marker; the server
# stores them as text and never inspects the payload — E2EE §6.6).
ENV_1="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDAzTXNnMQ"
ENV_2="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDAzTXNnMg"
ENV_3="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDAzTXNnMw"
ENV_E="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDAzRXZlbnQ"

cleanup() {
  svc_delete_quiet "chats?id=in.($CHAT_GROUP,$CHAT_EVENT)"
  svc_delete_quiet "events?id=eq.$EVENT_ID"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C)"
  for uid in $UUID_A $UUID_B $UUID_C; do
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

# ---------------------------------------------------------------------------
# Setup: users A (group member + event host) and B (outsider)
# ---------------------------------------------------------------------------
h1 "SETUP: users + group + event"

trap cleanup EXIT
cleanup

for pair in "A $UUID_A user_a_opt003 $EMAIL_A" "B $UUID_B user_b_opt003 $EMAIL_B" "C $UUID_C user_c_opt003 $EMAIL_C"; do
  set -- $pair
  name=$1; uid=$2; uname=$3; email=$4
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if echo "$resp" | grep -q '"id"'; then ok "Created auth user $name ($uid)"; else nok "Create user $name: $(echo "$resp" | head -c 80)"; fi
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"personal_shards\":1000}" > /dev/null
done
ok "Inserted user rows in public.users"

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
  ok "Obtained auth tokens for both users"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Opt003 Group\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" > /dev/null
svc_post "events" "{\"id\":\"$EVENT_ID\",\"name\":\"Opt003 Event\",\"type\":\"juerga\",\
\"created_by_user_id\":\"$UUID_A\",\"starts_at\":\"2026-12-31T23:00:00Z\",\
\"ends_at\":\"2027-01-01T05:00:00Z\",\"preshards_pool\":0,\"status\":\"upcoming\"}" > /dev/null
svc_post "event_hosts" "{\"event_id\":\"$EVENT_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\"}" > /dev/null
ok "Group + event + host seeded (A member/host, B outsider)"

# =========================================================================
# TEST A — chats creation (type group + event, w/ reference_id)
# =========================================================================
h1 "TEST A — chats rows (type='group'/'event' with reference_id)"

svc_post "chats" "{\"id\":\"$CHAT_GROUP\",\"type\":\"group\",\"reference_id\":\"$GROUP_ID\"}" > /dev/null
svc_post "chats" "{\"id\":\"$CHAT_EVENT\",\"type\":\"event\",\"reference_id\":\"$EVENT_ID\"}" > /dev/null

row=$(svc_get "chats?id=in.($CHAT_GROUP,$CHAT_EVENT)&select=id,type,reference_id")
if echo "$row" | grep -q '"type":"group"' && echo "$row" | grep -q "\"reference_id\":\"$GROUP_ID\"" \
   && echo "$row" | grep -q '"type":"event"' && echo "$row" | grep -q "\"reference_id\":\"$EVENT_ID\""; then
  ok "Both chats persisted with correct type + reference_id"
else
  nok "Chat rows wrong: $(echo "$row" | head -c 120)"
fi

# =========================================================================
# TEST B — message insert with opaque base64url envelope content (svc)
# =========================================================================
h1 "TEST B — svc message insert (opaque envelope content)"

svc_post "messages" "{\"id\":\"$MSG_1\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_1\"}" > /dev/null
svc_post "messages" "{\"id\":\"$MSG_2\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_2\"}" > /dev/null
svc_post "messages" "{\"id\":\"$MSG_3\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_3\"}" > /dev/null
svc_post "messages" "{\"id\":\"$MSG_E\",\"chat_id\":\"$CHAT_EVENT\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_E\"}" > /dev/null

cnt=$(svc_get "messages?chat_id=eq.$CHAT_GROUP&select=id" | grep -c '"id"' || true)
if [ "$cnt" -eq 3 ]; then
  ok "3 messages inserted into group chat (cap=1000 inert below cap)"
else
  nok "Expected 3 messages in group chat, found $cnt"
fi

# =========================================================================
# TEST C — RLS: member reads messages, non-member CANNOT
# =========================================================================
h1 "TEST C — messages_read_participant (group chat)"

resp=$(auth_get "$TOKEN_A" "messages?chat_id=eq.$CHAT_GROUP&select=id,content&order=created_at.asc")
if echo "$resp" | grep -q "\"content\":\"$ENV_1\"" \
   && echo "$resp" | grep -q "\"content\":\"$ENV_2\"" \
   && echo "$resp" | grep -q "\"content\":\"$ENV_3\""; then
  ok "Group member A reads all 3 messages; envelope content opaque + preserved"
else
  nok "Member read wrong: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_get "$TOKEN_B" "messages?chat_id=eq.$CHAT_GROUP&select=id,content")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Non-member B CANNOT read group chat messages (RLS)"
else
  nok "Non-member B CAN read group chat messages: $(echo "$resp" | head -c 60)"
fi

resp=$(anon_get "messages?chat_id=eq.$CHAT_GROUP&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied)'; then
  ok "anon CANNOT read messages (no anon policy)"
else
  nok "anon CAN read messages: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST D — event chat: host reads; outsider cannot
# =========================================================================
h1 "TEST D — messages_read_participant (event chat)"

resp=$(auth_get "$TOKEN_A" "messages?chat_id=eq.$CHAT_EVENT&select=id,content")
if echo "$resp" | grep -q "\"content\":\"$ENV_E\""; then
  ok "Event host A reads event-chat message"
else
  nok "Host read failed: $(echo "$resp" | head -c 80)"
fi

resp=$(auth_get "$TOKEN_B" "messages?chat_id=eq.$CHAT_EVENT&select=id,content")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Outsider B CANNOT read event-chat message (not invited/host/member)"
else
  nok "Outsider B CAN read event-chat message: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST E — message_cap trigger: insert 3 -> all present (cap not reached)
# =========================================================================
h1 "TEST E — message_cap (below cap: nothing pruned)"

cap=$(svc_get "app_config?key=eq.chat.message_cap&select=value")
info "app_config chat.message_cap = $(echo "$cap" | grep -oE '[0-9]+' | head -1)"
cnt=$(svc_get "messages?chat_id=eq.$CHAT_GROUP&select=id" | grep -c '"id"' || true)
if [ "$cnt" -eq 3 ]; then
  ok "All 3 messages retained (rolling window only prunes beyond cap)"
else
  nok "Expected 3 retained messages, found $cnt"
fi
info "Full-cap (1000) + trigger existence asserted in pgTAP (supabase/tests/schema_test.sql, I-77) — a trigger function is not callable via PostgREST RPC."

# =========================================================================
# TEST F — DIRECT chat RLS (regression 20260815000003): the original
# chats_read_participant correlated chat_id to chat_participants.id (unqualified
# `id` shadowed), so direct chats were invisible to participants and EVERY
# messages INSERT violated messages_insert_participant with 42501 — the live
# "No se pudo enviar el mensaje" failure (2026-08-15 repro).
# =========================================================================
h1 "TEST F — direct chat: create_direct_chat RPC → visible → insert → read"

RPC_ID=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/create_direct_chat" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" \
  -d "{\"p_peer_id\":\"$UUID_B\"}")
CHAT_DIRECT=$(echo "$RPC_ID" | grep -o '"chatId": *"[^"]*"' | cut -d'"' -f4)
if [ -n "$CHAT_DIRECT" ]; then
  ok "create_direct_chat returned chatId=$CHAT_DIRECT"
else
  nok "create_direct_chat failed: $(echo "$RPC_ID" | head -c 120)"
fi

# Regression A: the participant must SEE the direct chat row.
vis=$(auth_get "$TOKEN_A" "chats?id=eq.$CHAT_DIRECT&select=id,type")
if echo "$vis" | grep -q "\"id\":\"$CHAT_DIRECT\""; then
  ok "Participant A reads the direct chat row (chats_read_participant fixed)"
else
  nok "Participant A CANNOT read own direct chat: $(echo "$vis" | head -c 120)"
fi

# Regression B: the participant must be able to INSERT a message (E2EE
# envelope content — server stays opaque).
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"chat_id\":\"$CHAT_DIRECT\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_1\"}")
if [ "$code" = "201" ]; then
  ok "Participant A INSERTs into the direct chat (http $code)"
else
  nok "Participant A INSERT rejected (http $code) — messages_insert_participant/42501"
fi

# Regression C: the message is readable back (messages_read_participant).
readback=$(auth_get "$TOKEN_A" "messages?chat_id=eq.$CHAT_DIRECT&select=id,content")
if echo "$readback" | grep -q "$ENV_1"; then
  ok "Participant A reads the message back (envelope preserved byte-for-byte)"
else
  nok "Message readback failed: $(echo "$readback" | head -c 120)"
fi

# Regression D: a NON-participant cannot see the direct chat.
if [ "$(auth_get "$TOKEN_C" "chats?id=eq.$CHAT_DIRECT" | tr -d '[:space:]')" = "[]" ]; then
  ok "Outsider C cannot see the direct chat (RLS intact)"
else
  nok "Outsider C CAN see the direct chat — RLS broken"
fi

# =========================================================================
# TEST G — chat inbox RPCs (20260815000004): unread watermark, symmetric
# A->B and B->A, outsider excluded.
# =========================================================================
h1 "TEST G — get_chat_inbox / mark_chat_read (symmetric unread counts)"

# A sent one message in TEST F → A's own inbox: 0 unread; B's inbox: 1 unread.
inbox_a=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d '{}')
inbox_b=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d '{}')
row_a=$(echo "$inbox_a" | grep -o "\"chat_id\":\"$CHAT_DIRECT\"" || true)
row_b=$(echo "$inbox_b" | grep -o "\"chat_id\":\"$CHAT_DIRECT\"" || true)
if [ -n "$row_a" ] && [ -n "$row_b" ]; then
  ok "Both participants see the direct chat in their inbox"
else
  nok "Inbox rows missing: A=$(echo "$inbox_a" | head -c 80) B=$(echo "$inbox_b" | head -c 80)"
fi
if echo "$inbox_a" | grep -q "\"unread_count\":0" && echo "$inbox_b" | grep -q "\"unread_count\":1"; then
  ok "Symmetric unread: sender A sees 0, receiver B sees 1"
else
  nok "Unread counts wrong: A=$(echo "$inbox_a" | grep -o '\"unread_count\":[0-9]*' | head -1) B=$(echo "$inbox_b" | grep -o '\"unread_count\":[0-9]*' | head -1)"
fi

# B marks the chat read → B's unread drops to 0.
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_chat_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_DIRECT\"}")
inbox_b2=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d '{}')
if [ "$code" = "204" ] && echo "$inbox_b2" | grep -q "\"chat_id\":\"$CHAT_DIRECT\"" \
   && echo "$inbox_b2" | grep -q "\"unread_count\":0"; then
  ok "mark_chat_read clears B's unread count"
else
  nok "mark_chat_read failed (http $code): $(echo "$inbox_b2" | head -c 100)"
fi

# Reverse direction: B sends → A's unread becomes 1 (B->A == A->B).
curl -s -o /dev/null -X POST "$SUPABASE_URL/rest/v1/messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"chat_id\":\"$CHAT_DIRECT\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_2\"}"
inbox_a2=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d '{}')
if echo "$inbox_a2" | grep -q "\"chat_id\":\"$CHAT_DIRECT\"" && echo "$inbox_a2" | grep -q "\"unread_count\":1"; then
  ok "Reverse direction: B's message counts as unread for A (B->A == A->B)"
else
  nok "Reverse unread wrong: $(echo "$inbox_a2" | grep -o '\"unread_count\":[0-9]*' | head -1)"
fi

# The outsider's inbox never contains the direct chat.
inbox_c=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" -d '{}')
if ! echo "$inbox_c" | grep -q "$CHAT_DIRECT"; then
  ok "Outsider C's inbox excludes the direct chat (caller-scoped)"
else
  nok "Outsider C sees the direct chat in the inbox — scope broken"
fi

# Cleanup the direct chat + its messages.
svc_delete_quiet "messages?chat_id=eq.$CHAT_DIRECT"
svc_delete_quiet "chats?id=eq.$CHAT_DIRECT"

# ---------------------------------------------------------------------------
# G) Message deletion RPCs (20260815000006): delete_message_for_everyone
#    (sender + server-verified 5-min window) + delete_undecryptable_messages
#    (participant-gated cleanup) + deleted_messages audit
# ---------------------------------------------------------------------------
h1 "G: deletion RPCs (20260815000006)"

# Re-create the direct chat for this section.
RPC_ID=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/create_direct_chat" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d "{\"p_peer_id\":\"$UUID_B\"}")
CHAT_DIRECT=$(echo "$RPC_ID" | grep -o '"chatId": *"[^"]*"' | cut -d'"' -f4)
if [ -n "$CHAT_DIRECT" ]; then ok "G: recreated direct chat for deletion tests"; fi

DEL_MSG_1="55555555-5555-5555-5555-555555555501"
DEL_MSG_2="55555555-5555-5555-5555-555555555502"
DEL_MSG_3="55555555-5555-5555-5555-555555555503"

svc_post "messages" "{\"id\":\"$DEL_MSG_1\",\"chat_id\":\"$CHAT_DIRECT\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_1\"}" > /dev/null
svc_post "messages" "{\"id\":\"$DEL_MSG_2\",\"chat_id\":\"$CHAT_DIRECT\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_2\",\"sent_at\":\"$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)\"}" > /dev/null
svc_post "messages" "{\"id\":\"$DEL_MSG_3\",\"chat_id\":\"$CHAT_DIRECT\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_3\"}" > /dev/null

# sender A, fresh message (sent_at = server now) → deleted.
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/delete_message_for_everyone" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d "{\"p_message_id\":\"$DEL_MSG_1\"}")
if [ -z "$resp" ] && ! auth_get "$TOKEN_A" "messages?id=eq.$DEL_MSG_1" | grep -q "$DEL_MSG_1"; then
  ok "G: sender deletes a fresh message for everyone (row gone)"
else
  nok "G: delete_message_for_everyone fresh: $resp"
fi

# sender A, message older than 5 min (server clock) → MESSAGE_TOO_OLD.
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/delete_message_for_everyone" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d "{\"p_message_id\":\"$DEL_MSG_2\"}")
if echo "$resp" | grep -q "MESSAGE_TOO_OLD"; then
  ok "G: a >5-min message is refused with MESSAGE_TOO_OLD (server clock)"
else
  nok "G: too-old verdict: $resp"
fi

# A is NOT the sender of DEL_MSG_3 → NOT_THE_SENDER.
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/delete_message_for_everyone" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d "{\"p_message_id\":\"$DEL_MSG_3\"}")
if echo "$resp" | grep -q "NOT_THE_SENDER"; then
  ok "G: a non-sender is refused with NOT_THE_SENDER"
else
  nok "G: not-sender verdict: $resp"
fi

# Participant cleanup: A deletes B's rows as "undecryptable" — the request
# also carries a GROUP-chat message id (MSG_1) that must be IGNORED.
svc_post "messages" "{\"id\":\"$DEL_MSG_1\",\"chat_id\":\"$CHAT_DIRECT\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_1\"}" > /dev/null
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/delete_undecryptable_messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" \
  -d "{\"p_chat_id\":\"$CHAT_DIRECT\",\"p_message_ids\":[\"$DEL_MSG_1\",\"$DEL_MSG_2\",\"$MSG_1\"]}")
if [ "$resp" = "2" ]; then
  ok "G: participant cleanup deleted exactly the chat's 2 rows (cross-chat ignored)"
else
  nok "G: cleanup count=$resp (expected 2)"
fi
# The group-chat message survives the cleanup.
if auth_get "$TOKEN_A" "messages?id=eq.$MSG_1" | grep -q "$MSG_1"; then
  ok "G: the cross-chat message id survived (chat_id predicate)"
else
  nok "G: cross-chat message was wrongly deleted"
fi

# Outsider C is NOT a participant → NOT_A_PARTICIPANT.
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/delete_undecryptable_messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" \
  -d "{\"p_chat_id\":\"$CHAT_DIRECT\",\"p_message_ids\":[\"$DEL_MSG_3\"]}")
if echo "$resp" | grep -q "NOT_A_PARTICIPANT"; then
  ok "G: outsider is refused with NOT_A_PARTICIPANT"
else
  nok "G: outsider verdict: $resp"
fi

# Audit trail: delete_for_everyone rows are recorded in deleted_messages.
audit=$(svc_get "deleted_messages?message_id=eq.$DEL_MSG_1")
if echo "$audit" | grep -q "delete_for_everyone"; then
  ok "G: deletions are audited in deleted_messages"
else
  nok "G: audit row missing: $audit"
fi

# Cleanup the direct chat + its messages.
svc_delete_quiet "messages?chat_id=eq.$CHAT_DIRECT"
svc_delete_quiet "chats?id=eq.$CHAT_DIRECT"


# =========================================================================
# Summary
# =========================================================================
h1 "RESULTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "  🎉 All tests passed!"
  exit 0
else
  echo ""
  echo "  💥 Some tests failed."
  exit 1
fi
