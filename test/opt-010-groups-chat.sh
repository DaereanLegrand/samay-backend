#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-010] Group Chat Support — Integration Test (ISSUE 4, DB layer, D1)
# -----------------------------------------------------------------------------
# Verifies the group-chat participant-sync contract (migration
# 20260817000002_group_chat_support.sql):
#
#   1) createGroup order (groups → group_members → chats) yields a
#      chat_participants row for the active creator (D1c backfill trigger)
#   2) an INVITED member gets NO participant row (D1b insert branch)
#   3) accepting the invite (status → 'active') CREATES the participant row
#   4) the accepted member can INSERT a message into the group chat and read
#      it back (active-gated messages RLS)
#   5) an INVITED member CANNOT read (empty) or insert (42501) group-chat
#      messages — the active-only RLS gate (D1e)
#   6) kicking the member (row DELETE) removes their participant row and their
#      read access (D1b delete branch)
#   7) get_chat_inbox shows the group chat with peer_username = groups.name
#      and peer_id = NULL (D1d), with the unread badge = 1
#   8) group_members is in the supabase_realtime publication (the psql check
#      is needed because pg_publication_tables is NOT exposed via PostgREST —
#      PGRST205 on this stack)
#   9) mark_chat_read / mark_messages_read succeed for a group participant
#  10) messages.recipient_id (20260817000003): column exists; an active member
#      inserts a distribution row addressed to another member and reads it
#      back; the INVITED user stays blocked (RLS unchanged)
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs unique to this file
# (6666... family — opt-003 uses 5555, opt-001/002 use 1111/4444), exactly
# like opt-001/opt-003. Cleanup runs in dependency order (messages →
# participants→ chats → group_members → groups → users → auth users).
#
# Usage: bash test/opt-010-groups-chat.sh
#
# Keys (M-03 alignment): ANON_KEY / SERVICE_KEY default to the DEV values
# from supabase/.env — dev-only; CI/checkpoint overrides them via env vars.
# PGURL overrides the psql DSN for check 8 (default: the live 54382 DB).
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0

# Fixed IDs (unique to this file — opt-003 uses 5555..., opt-001/002 use 1111/4444).
UUID_A="66666666-6666-6666-6666-666666666601"
UUID_B="66666666-6666-6666-6666-666666666602"
UUID_C="66666666-6666-6666-6666-666666666603"
EMAIL_A="user_a_opt010@samay.test"
EMAIL_B="user_b_opt010@samay.test"
EMAIL_C="user_c_opt010@samay.test"
PW="Pass1234!"
GROUP_ID="66666666-6666-6666-6666-666666666611"
CHAT_GROUP="66666666-6666-6666-6666-666666666621"
MSG_A="66666666-6666-6666-6666-666666666631"
MSG_B="66666666-6666-6666-6666-666666666632"
DIST_MSG="66666666-6666-6666-6666-666666666633"
FR_AC="66666666-6666-6666-6666-666666666640"

# Opaque base64url E2EE-style envelopes (the server never inspects content).
ENV_A="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDEwQQ"
ENV_B="SME2.AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5.OkVudmVsb3BlT3B0MDEwQg"

cleanup() {
  svc_delete_quiet "messages?chat_id=eq.$CHAT_GROUP"
  svc_delete_quiet "chats?id=eq.$CHAT_GROUP"
  svc_delete_quiet "group_members?group_id=eq.$GROUP_ID"
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
svc_patch() {
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}

# $1 token $2 body → http_code (message insert as a user)
user_insert_msg() {
  curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/messages" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d "$2"
}

# ---------------------------------------------------------------------------
h1 "SETUP: users A (creator), B (invitee), C (invited-only)"
# ---------------------------------------------------------------------------
trap cleanup EXIT
cleanup

for pair in "A $UUID_A user_a_opt010 $EMAIL_A" "B $UUID_B user_b_opt010 $EMAIL_B" "C $UUID_C user_c_opt010 $EMAIL_C"; do
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
  ok "Obtained auth tokens for all users"
else
  nok "Failed to get auth tokens"
fi

# Group creation in GroupService.createGroup order: groups → group_members
# (creator, status default 'active') → chats (type='group', reference_id).
svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Opt010 Group\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" > /dev/null
svc_post "chats" "{\"id\":\"$CHAT_GROUP\",\"type\":\"group\",\"reference_id\":\"$GROUP_ID\"}" > /dev/null
ok "Group + creator membership + group chat seeded (createGroup order)"

# =========================================================================
h1 "1) Creator is a chat participant (D1c backfill on chats INSERT)"
# =========================================================================
row=$(svc_get "chat_participants?chat_id=eq.$CHAT_GROUP&user_id=eq.$UUID_A&select=id")
if echo "$row" | grep -q '"id"'; then
  ok "Creator A has a chat_participants row in the group chat"
else
  nok "No participant row for creator A: $(echo "$row" | head -c 120)"
fi

# =========================================================================
h1 "2) Invited member gets NO participant row (D1b INSERT branch)"
# =========================================================================
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"invited\"}" > /dev/null
row=$(svc_get "chat_participants?chat_id=eq.$CHAT_GROUP&user_id=eq.$UUID_B&select=id")
if [ "$row" = "[]" ]; then
  ok "Invited B has NO participant row yet"
else
  nok "Invited B already has a participant row: $(echo "$row" | head -c 120)"
fi

# =========================================================================
h1 "3) Accepting the invite creates the participant row (D1b UPDATE branch)"
# =========================================================================
svc_patch "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B" '{"status":"active"}' > /dev/null
row=$(svc_get "chat_participants?chat_id=eq.$CHAT_GROUP&user_id=eq.$UUID_B&select=id")
if echo "$row" | grep -q '"id"'; then
  ok "Accepted B now has a participant row"
else
  nok "No participant row after accept: $(echo "$row" | head -c 120)"
fi

# =========================================================================
h1 "4) Active member B can INSERT + read group-chat messages"
# =========================================================================
code=$(user_insert_msg "$TOKEN_B" "{\"id\":\"$MSG_B\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_B\",\"content\":\"$ENV_B\"}")
if [ "$code" = "201" ]; then
  ok "B INSERTs a message into the group chat (http $code)"
else
  nok "B INSERT rejected (http $code) — messages_insert_participant/42501"
fi
readback=$(auth_get "$TOKEN_B" "messages?chat_id=eq.$CHAT_GROUP&select=id,content")
if echo "$readback" | grep -q "$ENV_B"; then
  ok "B reads the message back (envelope preserved byte-for-byte)"
else
  nok "B readback failed: $(echo "$readback" | head -c 120)"
fi

# =========================================================================
h1 "5) INVITED user C CANNOT read or insert group-chat messages"
# =========================================================================
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_C\",\"role\":\"member\",\"status\":\"invited\"}" > /dev/null
resp=$(auth_get "$TOKEN_C" "messages?chat_id=eq.$CHAT_GROUP&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Invited C CANNOT read group-chat messages (empty/denied)"
else
  nok "Invited C CAN read group-chat messages: $(echo "$resp" | head -c 80)"
fi
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -w "\n%{http_code}" -d "{\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_C\",\"content\":\"$ENV_B\"}")
body=$(echo "$resp" | head -1)
code=$(echo "$resp" | tail -1)
if [ "$code" = "403" ]; then
  ok "Invited C CANNOT insert into the group chat (http 403 — RLS WITH CHECK)"
else
  nok "Invited C insert returned http $code (expected 403): $(echo "$body" | head -c 120)"
fi

# =========================================================================
h1 "7) Inbox: B sees the group with groups.name, peer_id NULL, unread 1"
# ---------------------------------------------------------------------------
# Runs while B is still active — the inbox row exists only for participants.
# A sends a message so B's unread badge is 1 (B's watermark = accept time).
# =========================================================================
svc_post "messages" "{\"id\":\"$MSG_A\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_A\"}" > /dev/null
inbox_b=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d '{}')
if echo "$inbox_b" | grep -q "\"chat_id\":\"$CHAT_GROUP\""; then
  ok "B's inbox contains the group chat"
else
  nok "Group chat missing from B's inbox: $(echo "$inbox_b" | head -c 120)"
fi
if echo "$inbox_b" | grep -q '"peer_username":"Opt010 Group"' && echo "$inbox_b" | grep -q '"peer_id":null'; then
  ok "Inbox shows peer_username = groups.name, peer_id = NULL"
else
  nok "Inbox peer fields wrong: $(echo "$inbox_b" | grep -o '"peer_username":[^,]*\|"peer_id":[^,]*' | head -2)"
fi
if echo "$inbox_b" | grep -q "\"unread_count\":1"; then
  ok "B's unread_count is 1 (A's message newer than B's watermark)"
else
  nok "unread_count wrong: $(echo "$inbox_b" | grep -o '"unread_count":[0-9]*' | head -1)"
fi

# =========================================================================
h1 "6) Kick B: participant row removed + read access revoked (D1b DELETE)"
# =========================================================================
svc_delete_quiet "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B"
row=$(svc_get "chat_participants?chat_id=eq.$CHAT_GROUP&user_id=eq.$UUID_B&select=id")
if [ "$row" = "[]" ]; then
  ok "Kicked B's participant row is gone"
else
  nok "Kicked B still has a participant row: $(echo "$row" | head -c 120)"
fi
resp=$(auth_get "$TOKEN_B" "messages?chat_id=eq.$CHAT_GROUP&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Kicked B can no longer read group-chat messages"
else
  nok "Kicked B CAN read group-chat messages: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
h1 "8) group_members is in the supabase_realtime publication"
# =========================================================================
if command -v psql > /dev/null 2>&1; then
  cnt=$(psql "$PGURL" -tA -c "SELECT count(*) FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='group_members';" 2>/dev/null)
  if [ "$cnt" = "1" ]; then
    ok "group_members is in supabase_realtime (pg_publication_tables)"
  else
    nok "group_members NOT in supabase_realtime (count=$cnt)"
  fi
else
  nok "psql not available — cannot verify the publication membership"
fi

# =========================================================================
h1 "9) mark_chat_read / mark_messages_read succeed for a participant"
# =========================================================================
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_chat_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
code2=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_messages_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
if [ "$code" = "204" ] && [ "$code2" = "204" ]; then
  ok "mark_chat_read + mark_messages_read both succeed for participant A (204)"
else
  nok "Read-marking failed: mark_chat_read=$code mark_messages_read=$code2"
fi

# =========================================================================
h1 "10) recipient_id distribution column (20260817000003, D3)"
# ---------------------------------------------------------------------------
# Sender-key distribution addressing: bundles travel as ordinary messages rows
# carrying the TARGET member in recipient_id. Column existence via psql
# (information_schema is NOT exposed via PostgREST — same pattern as check 8).
# =========================================================================
if command -v psql > /dev/null 2>&1; then
  cnt=$(psql "$PGURL" -tA -c "SELECT count(*) FROM information_schema.columns WHERE table_name='messages' AND column_name='recipient_id';" 2>/dev/null)
  if [ "$cnt" = "1" ]; then
    ok "messages.recipient_id column exists (20260817000003)"
  else
    nok "messages.recipient_id column MISSING (count=$cnt)"
  fi
else
  nok "psql not available — cannot verify the recipient_id column"
fi

# An ACTIVE member (A) inserts a distribution-style row addressed to B and
# reads it back with the recipient_id intact (the envelope + client-side skip
# provide the privacy — RLS treats it like any group message).
DIST_MSG="66666666-6666-6666-6666-666666666633"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"id\":\"$DIST_MSG\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_A\",\"recipient_id\":\"$UUID_B\"}")
if [ "$code" = "201" ]; then
  ok "Active A INSERTs a distribution row with recipient_id = B (http $code)"
else
  nok "Distribution insert rejected (http $code): $(echo "$body" | head -c 120)"
fi
readback=$(auth_get "$TOKEN_A" "messages?chat_id=eq.$CHAT_GROUP&id=eq.$DIST_MSG&select=id,recipient_id")
if echo "$readback" | grep -q "\"recipient_id\":\"$UUID_B\""; then
  ok "A reads the distribution row back with recipient_id intact"
else
  nok "recipient_id round-trip failed: $(echo "$readback" | head -c 120)"
fi

# The INVITED (still non-active) user C remains blocked even with the new
# column populated — the active-only RLS gate (D1e) is unchanged.
resp=$(auth_get "$TOKEN_C" "messages?chat_id=eq.$CHAT_GROUP&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Invited C still CANNOT read group-chat messages (recipient_id rows included)"
else
  nok "Invited C CAN read recipient_id rows: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
h1 "11) Inbox preview skips distribution rows (0004/F5 + 0005 preview filter)"
# ---------------------------------------------------------------------------
# Re-activate B (kicked in check 6) so the inbox row exists again; the newest
# message in the chat is the DIST_MSG distribution row from section 10
# (recipient_id = B). Since 20260818000001 the preview is the last REAL
# content message (recipient_id IS NULL) — a control envelope as preview was
# meaningless/undecryptable for non-targets — so the preview must be MSG_A
# with last_message_recipient_id NULL, not the distribution row.
# =========================================================================
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" > /dev/null
inbox_b=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d '{}')
if echo "$inbox_b" | grep -q "\"last_message_id\":\"$MSG_A\"" \
   && echo "$inbox_b" | grep -q "\"last_message_recipient_id\":null"; then
  ok "Inbox preview is the last content message (MSG_A), recipient_id NULL"
else
  nok "Inbox preview wrong: $(echo "$inbox_b" | grep -o '"last_message_recipient_id":[^,]*\|"last_message_id":[^,]*' | head -2)"
fi

# =========================================================================
h1 "12) accept_friend_request RPC: addressee-only, pending-only (0004/F6)"
# ---------------------------------------------------------------------------
# The server previously let the REQUESTER flip an outbound pending row to
# accepted (friendships_update_own covers requester or addressee). The new
# SECURITY DEFINER RPC verifies auth.uid() is the ADDressee of a 'pending'
# row. A is the requester, C is the addressee.
# =========================================================================
svc_post "friendships" "{\"id\":\"$FR_AC\",\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"pending\"}" > /dev/null
# (a) The REQUESTER (A) is rejected.
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/accept_friend_request" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" \
  -d "{\"p_friendship_id\":\"$FR_AC\"}")
if echo "$resp" | grep -q "NOT_THE_ADDRESSEE"; then
  ok "Requester A is rejected (NOT_THE_ADDRESSEE)"
else
  nok "Requester A was NOT rejected: $(echo "$resp" | head -c 120)"
fi
# (b) The ADDRESSEE (C) succeeds and the row flips to accepted.
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/accept_friend_request" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" \
  -d "{\"p_friendship_id\":\"$FR_AC\"}")
row=$(svc_get "friendships?id=eq.$FR_AC&select=status")
if [ "$code" = "204" ] && echo "$row" | grep -q '"status":"accepted"'; then
  ok "Addressee C accepts (http $code) and the row flips to accepted"
else
  nok "Addressee C accept failed (http $code): $(echo "$row" | head -c 120)"
fi
# (c) Accepting a NON-pending row is rejected too.
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/accept_friend_request" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" \
  -H "Content-Type: application/json" \
  -d "{\"p_friendship_id\":\"$FR_AC\"}")
if echo "$resp" | grep -q "NOT_PENDING"; then
  ok "Accepting the already-accepted row is rejected (NOT_PENDING)"
else
  nok "NOT_PENDING guard missing: $(echo "$resp" | head -c 120)"
fi

# =========================================================================
h1 "13) message cap: recipient_id rows survive the rolling window (0004/F7)"
# ---------------------------------------------------------------------------
# enforce_message_cap previously counted distribution rows toward the cap and
# pruned them like chat content. Behavioral check inside ONE rolled-back psql
# transaction (psql-only — like checks 8/10): cap=3, insert 2 recipient_id
# rows FIRST (oldest — the old trigger would prune them) + 4 ordinary rows →
# only the ordinary rows are pruned, the distribution rows survive. Nothing
# persists.
# =========================================================================
if command -v psql > /dev/null 2>&1; then
  cap_out=$(psql "$PGURL" -tA <<'SQL' 2>/dev/null
BEGIN;
UPDATE public.app_config SET value = '3' WHERE key = 'chat.message_cap';
INSERT INTO public.users (id, username) VALUES ('66666666-6666-6666-6666-6666666666c0', 'cap_sender_opt010');
INSERT INTO public.chats (id, type) VALUES ('66666666-6666-6666-6666-6666666666c1', 'direct');
INSERT INTO public.messages (id, chat_id, sender_id, content, recipient_id, created_at) VALUES
  ('66666666-6666-6666-6666-6666666666d5', '66666666-6666-6666-6666-6666666666c1', '66666666-6666-6666-6666-6666666666c0', 'r1', '66666666-6666-6666-6666-666666666601', '2026-08-17T00:00:01Z'),
  ('66666666-6666-6666-6666-6666666666d6', '66666666-6666-6666-6666-6666666666c1', '66666666-6666-6666-6666-6666666666c0', 'r2', '66666666-6666-6666-6666-666666666601', '2026-08-17T00:00:02Z'),
  ('66666666-6666-6666-6666-6666666666d1', '66666666-6666-6666-6666-6666666666c1', '66666666-6666-6666-6666-6666666666c0', 'm1', NULL, '2026-08-17T00:00:03Z'),
  ('66666666-6666-6666-6666-6666666666d2', '66666666-6666-6666-6666-6666666666c1', '66666666-6666-6666-6666-6666666666c0', 'm2', NULL, '2026-08-17T00:00:04Z'),
  ('66666666-6666-6666-6666-6666666666d3', '66666666-6666-6666-6666-6666666666c1', '66666666-6666-6666-6666-6666666666c0', 'm3', NULL, '2026-08-17T00:00:05Z'),
  ('66666666-6666-6666-6666-6666666666d4', '66666666-6666-6666-6666-6666666666c1', '66666666-6666-6666-6666-6666666666c0', 'm4', NULL, '2026-08-17T00:00:06Z');
SELECT 'recipient_rows=' || count(*) FROM public.messages WHERE chat_id = '66666666-6666-6666-6666-6666666666c1' AND recipient_id IS NOT NULL;
SELECT 'total_rows=' || count(*) FROM public.messages WHERE chat_id = '66666666-6666-6666-6666-6666666666c1';
SELECT 'oldest_pruned=' || count(*) FROM public.messages WHERE id IN ('66666666-6666-6666-6666-6666666666d1', '66666666-6666-6666-6666-6666666666d2', '66666666-6666-6666-6666-6666666666d3');
ROLLBACK;
SQL
)
  if echo "$cap_out" | grep -q 'recipient_rows=2' \
     && echo "$cap_out" | grep -q 'total_rows=3' \
     && echo "$cap_out" | grep -q 'oldest_pruned=0'; then
    ok "Cap prunes only ordinary rows: 2 recipient rows survive, total 3, oldest 3 pruned"
  else
    nok "Cap behavior wrong: $(echo "$cap_out" | tr '\n' ' ')"
  fi
else
  nok "psql not available — cannot verify the cap behavior"
fi

# =========================================================================
h1 "14) Inbox unread_count ignores sender-key distribution rows (0005)"
# ---------------------------------------------------------------------------
# get_chat_inbox previously counted EVERY row from others newer than the
# watermark toward unread_count — including sender-key DISTRIBUTION rows and
# KEY-REQUEST rows (recipient_id IS NOT NULL, the same class F7 exempts from
# the message-cap rolling window). Control rows have no user-visible message,
# so they must not inflate the badge. A marks read (both watermark = now),
# then inserts ONE real content row + ONE distribution row (recipient_id = B);
# B must see unread_count 1 (content ONLY), A must see 0 (own messages).
# =========================================================================
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_chat_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
code2=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_chat_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
if [ "$code" = "204" ] && [ "$code2" = "204" ]; then
  ok "A + B reset their read watermark via mark_chat_read (204)"
else
  nok "Watermark reset failed: A=$code B=$code2"
fi

MSG_NEW="66666666-6666-6666-6666-666666666634"
DIST_NEW="66666666-6666-6666-6666-666666666635"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"id\":\"$MSG_NEW\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_A\"}")
code3=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"id\":\"$DIST_NEW\",\"chat_id\":\"$CHAT_GROUP\",\"sender_id\":\"$UUID_A\",\"content\":\"$ENV_A\",\"recipient_id\":\"$UUID_B\"}")
if [ "$code" = "201" ] && [ "$code3" = "201" ]; then
  ok "A inserts one content row + one distribution row after the watermark (201)"
else
  nok "Insert failed: content=$code distribution=$code3"
fi

chat_unread() {
  local t=$1 cid=$2
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
    -H "Content-Type: application/json" -d '{}' \
    | grep -o "\"chat_id\":\"$cid\"[^}]*\"unread_count\":[0-9]*" \
    | grep -o '"unread_count":[0-9]*' | cut -d: -f2
}

uc_b=$(chat_unread "$TOKEN_B" "$CHAT_GROUP")
if [ "$uc_b" = "1" ]; then
  ok "B's unread_count is 1 (content row ONLY — distribution row excluded)"
else
  nok "B's unread_count is $uc_b (expected 1 — distribution row must NOT count)"
fi

uc_a=$(chat_unread "$TOKEN_A" "$CHAT_GROUP")
if [ "$uc_a" = "0" ]; then
  ok "A's unread_count is 0 (own messages are sender-excluded)"
else
  nok "A's unread_count is $uc_a (expected 0 — own messages excluded)"
fi

preview=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_chat_inbox" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d '{}')
if echo "$preview" | grep -q "\"last_message_id\":\"$MSG_NEW\""; then
  ok "B's inbox preview is the last REAL content message (not the distribution row)"
else
  nok "Inbox preview is not the last content message: $(echo "$preview" | grep -o '"last_message_id":[^,]*' | head -1)"
fi

code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/mark_chat_read" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_B" \
  -H "Content-Type: application/json" -d "{\"p_chat_id\":\"$CHAT_GROUP\"}")
uc_b2=$(chat_unread "$TOKEN_B" "$CHAT_GROUP")
if [ "$code" = "204" ] && [ "$uc_b2" = "0" ]; then
  ok "After mark_chat_read B's unread_count drops to 0"
else
  nok "mark_chat_read→0 failed: http=$code unread=$uc_b2"
fi

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
