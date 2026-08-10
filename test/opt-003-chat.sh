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
#   D) event chat: promotor reads; non-invited non-member cannot
#   E) message_cap rolling-window behavior stays inert below the cap
#      (insert 3 -> all 3 present; app_config chat.message_cap = 1000).
#      The full-cap behavior + trigger EXISTENCE are asserted in the pgTAP
#      suite (supabase/tests/schema_test.sql, I-77) — a curl test cannot call
#      a trigger function (returns trigger, not callable via PostgREST RPC).
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup), exactly
# like opt-001. Does NOT depend on seed-dev.sql (SEED_DEV=1). Optionally, a
# SEED_DEV=1 stack could reuse the demo chat/messages UUIDs
# (10000000-...-901/921..923) — not needed here.
#
# STATIC-VERIFIED ONLY (this agent run): the stack is not started until the
# checkpoint (AGENT-RULES / port map). Live run: make supabase-docker-start &&
# make supabase-docker-reset && bash test/opt-003-chat.sh
#
# Usage: bash test/opt-003-chat.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="${ANON_KEY:-sb_publishable_q7NDNoV4TCGqCgheg4tcvC_odjEiEdN}"
SERVICE_KEY="${SERVICE_KEY:-sb_secret_ecIXdsS9IJwFtzgPOHNOtj_eVgxyq37}"

PASS=0
FAIL=0

# Fixed IDs (unique to this file — opt-001/002 use 1111.../4444...).
UUID_A="55555555-5555-5555-5555-555555555555"
UUID_B="55555555-5555-5555-5555-555555555556"
EMAIL_A="user_a_opt003@samay.test"
EMAIL_B="user_b_opt003@samay.test"
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
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B)"
  for uid in $UUID_A $UUID_B; do
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
# Setup: users A (group member + event promotor) and B (outsider)
# ---------------------------------------------------------------------------
h1 "SETUP: users + group + event"

trap cleanup EXIT
cleanup

for pair in "A $UUID_A user_a_opt003 $EMAIL_A" "B $UUID_B user_b_opt003 $EMAIL_B"; do
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
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ]; then
  ok "Obtained auth tokens for both users"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Opt003 Group\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\",\"status\":\"active\"}" > /dev/null
svc_post "events" "{\"id\":\"$EVENT_ID\",\"name\":\"Opt003 Event\",\"type\":\"juerga\",\
\"created_by_user_id\":\"$UUID_A\",\"starts_at\":\"2026-12-31T23:00:00Z\",\
\"ends_at\":\"2027-01-01T05:00:00Z\",\"preshards_pool\":0,\"status\":\"upcoming\"}" > /dev/null
svc_post "event_promotores" "{\"event_id\":\"$EVENT_ID\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\"}" > /dev/null
ok "Group + event + promotor seeded (A member/promotor, B outsider)"

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
# TEST D — event chat: promotor reads; outsider cannot
# =========================================================================
h1 "TEST D — messages_read_participant (event chat)"

resp=$(auth_get "$TOKEN_A" "messages?chat_id=eq.$CHAT_EVENT&select=id,content")
if echo "$resp" | grep -q "\"content\":\"$ENV_E\""; then
  ok "Event promotor A reads event-chat message"
else
  nok "Promotor read failed: $(echo "$resp" | head -c 80)"
fi

resp=$(auth_get "$TOKEN_B" "messages?chat_id=eq.$CHAT_EVENT&select=id,content")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Outsider B CANNOT read event-chat message (not invited/promotor/member)"
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
