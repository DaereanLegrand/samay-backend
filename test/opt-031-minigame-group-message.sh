#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-031] minigame group fan-out + group chat notice
# (216_minigame_group_message, 2026-09-15)
#
# Creating a GROUP partida must:
#   A) invite EVERY active group member (creator excluded) — 2a
#   B) notify each auto-invited member
#   C) post a `minigame_group_messages` notice in the group chat — 2b
#   D) a direct table read is DENIED for members and non-members alike
#      (42501); the notice is reachable only through get_chat_inbox
#   E) keep it to ONE notice per session
#
# Usage: bash test/opt-031-minigame-group-message.sh
# Requires the stack with migration 216_minigame_group_message applied.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  if [ -n "${SESSION_ID:-}" ]; then
    svc_delete "minigame_group_messages?session_id=eq.$SESSION_ID" > /dev/null 2>&1 || true
    svc_delete "minigame_invites?session_id=eq.$SESSION_ID" > /dev/null 2>&1 || true
    svc_delete "minigame_game_state?session_id=eq.$SESSION_ID" > /dev/null 2>&1 || true
    svc_delete "minigame_sessions?id=eq.$SESSION_ID" > /dev/null 2>&1 || true
  fi
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    svc_delete "notifications?user_id=eq.$uid" > /dev/null 2>&1 || true
  done
  if [ -n "${GROUP_ID:-}" ]; then
    svc_delete "chats?reference_id=eq.$GROUP_ID&type=eq.group" > /dev/null 2>&1 || true
    svc_delete "group_members?group_id=eq.$GROUP_ID" > /dev/null 2>&1 || true
    svc_delete "groups?id=eq.$GROUP_ID" > /dev/null 2>&1 || true
  fi
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    svc_delete "users?id=eq.$uid" > /dev/null 2>&1 || true
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

norm_json() {
  sed -E 's/([][,{}:])[[:space:]]+/\1/g; s/[[:space:]]+([][,{}:])/\1/g'
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d" | norm_json
}
svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_delete() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" 2>/dev/null
}
svc_get() {
  curl -s "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}
auth_get() {
  curl -s "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $2"
}
count_rows() { echo "$1" | grep -o '"id"' | wc -l | tr -d ' '; }

# --- Setup ---
h1 "SETUP: users + group + group chat"

UUID_A="a1a1a1a1-1111-1111-1111-111111111101"
UUID_B="b2b2b2b2-2222-2222-2222-222222222202"
UUID_C="c3c3c3c3-3333-3333-3333-333333333303"
UUID_D="d4d4d4d4-4444-4444-4444-444444444404"
GROUP_ID="e5e5e5e5-5555-5555-5555-555555555505"
EMAIL_A="user_a_opt029@samay.test"
EMAIL_B="user_b_opt029@samay.test"
EMAIL_C="user_c_opt029@samay.test"
EMAIL_D="user_d_opt029@samay.test"
PW="Pass1234!"

trap cleanup EXIT
cleanup

for pair in "UUID_A:EMAIL_A" "UUID_B:EMAIL_B" "UUID_C:EMAIL_C" "UUID_D:EMAIL_D"; do
  uid_var="${pair%%:*}"; email_var="${pair##*:}"
  uid="${!uid_var}"; email="${!email_var}"
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if echo "$resp" | grep -q '"id"'; then ok "Created auth user ($uid)"; else nok "Create user: $(echo "$resp" | head -c 80)"; fi
done

for pair in "UUID_A:user_opt029_a" "UUID_B:user_opt029_b" "UUID_C:user_opt029_c" "UUID_D:user_opt029_d"; do
  uid_var="${pair%%:*}"; uname="${pair##*:}"; uid="${!uid_var}"
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":1000,\"preshards\":10,\"age_confirmed_at\":\"2026-01-01T00:00:00Z\",\"terms_accepted_at\":\"2026-01-01T00:00:00Z\"}" > /dev/null
done
ok "Inserted user rows in public.users"

TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_B=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_D=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_D\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_D" ]; then
  ok "Obtained auth tokens"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Group Msg Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_C\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A host + B/C members; D bystander; NO chat row (trigger must create it)"

# =========================================================================
# TEST A/B/C — group match creation fans out + posts the notice
# =========================================================================
h1 "TEST A/B/C — group match creation"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"poke_chain\",\"p_invitees\":[]}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "Group session created ($SESSION_ID)"
else
  nok "Group create failed: $(echo "$resp" | head -c 140)"
fi
info "create returned: $resp"

INVITES=$(svc_get "minigame_invites?session_id=eq.$SESSION_ID&select=invitee_id")
if echo "$INVITES" | grep -q "\"$UUID_B\"" && echo "$INVITES" | grep -q "\"$UUID_C\""; then
  ok "Every active member (B, C) auto-invited"
else
  nok "Auto-invite fan-out missing a member: $(echo "$INVITES" | head -c 160)"
fi
if echo "$INVITES" | grep -q "\"$UUID_A\""; then
  nok "Creator was invited (should be excluded)"
else
  ok "Creator excluded from the fan-out"
fi

NOTIFS_B=$(svc_get "notifications?user_id=eq.$UUID_B&type=eq.minigame_invite&select=id")
NOTIFS_C=$(svc_get "notifications?user_id=eq.$UUID_C&type=eq.minigame_invite&select=id")
if [ "$(count_rows "$NOTIFS_B")" -ge 1 ] && [ "$(count_rows "$NOTIFS_C")" -ge 1 ]; then
  ok "Auto-invited members got a minigame_invite notification"
else
  nok "Missing invite notifications (B=$(count_rows "$NOTIFS_B"), C=$(count_rows "$NOTIFS_C"))"
fi

MSG=$(svc_get "minigame_group_messages?session_id=eq.$SESSION_ID&select=id,group_id,actor_id,chat_id")
if echo "$MSG" | grep -q '"id"' && echo "$MSG" | grep -q "\"actor_id\":\"$UUID_A\""; then
  ok "Group chat notice posted with the creator as actor"
else
  nok "No group chat notice: $(echo "$MSG" | head -c 160)"
fi

# P1: the group had NO chat before the match — the notice trigger must create
# it (server guarantee) so the notice always has somewhere to land.
CHAT=$(svc_get "chats?type=eq.group&reference_id=eq.$GROUP_ID&select=id")
if [ "$(count_rows "$CHAT")" -eq 1 ]; then
  ok "Notice trigger auto-created the group chat"
else
  nok "Group chat not auto-created: $(echo "$CHAT" | head -c 140)"
fi

# =========================================================================
# TEST D — RLS: members read, non-members do not
# =========================================================================
h1 "TEST D — notice visibility"

# Slim-prod revoked direct client table access to minigame_group_messages
# (300_slim/05_revoke_removed): the notice is reached through the
# SECURITY-DEFINER inbox, never a raw PostgREST read.
B_READ=$(auth_get "minigame_group_messages?group_id=eq.$GROUP_ID&select=id" "$TOKEN_B")
if echo "$B_READ" | grep -q '42501\|permission denied'; then
  ok "Direct notice read denied to the client role (inbox-mediated only)"
else
  nok "Direct notice read not denied: $(echo "$B_READ" | head -c 140)"
fi

# P1: the inbox treats the notice as chat activity (preview/bump/unread).
INBOX_B=$(auth_rpc "$TOKEN_B" "get_chat_inbox" "{}")
if echo "$INBOX_B" | grep -q '"last_activity_kind":"minigame_notice"'; then
  ok "Inbox surfaces the minigame notice as chat activity (P1)"
else
  nok "Inbox missing notice activity: $(echo "$INBOX_B" | head -c 220)"
fi

D_READ=$(auth_get "minigame_group_messages?group_id=eq.$GROUP_ID&select=id" "$TOKEN_D")
if echo "$D_READ" | grep -q '42501\|permission denied'; then
  ok "Non-member D is denied too (table revoked for every client role)"
else
  nok "Non-member D read path unexpected: $(echo "$D_READ" | head -c 140)"
fi

SVC_READ=$(svc_get "minigame_group_messages?session_id=eq.$SESSION_ID&select=id")
if [ "$(count_rows "$SVC_READ")" -eq 1 ]; then
  ok "Exactly one notice per session (unique)"
else
  nok "Unexpected notice count: $(count_rows "$SVC_READ")"
fi

# =========================================================================
echo ""
echo "━━━ SUMMARY ━━━"
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
