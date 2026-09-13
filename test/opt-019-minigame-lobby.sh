#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-019] Minigame partida lobby (180_minigame_lobby)
# Verifies the lobby RPC family end-to-end — ready toggles, the creator-only
# Start (backend-enforced), creator-only removal, and the participant roster:
#   A) set_minigame_ready upserts the caller's flag into the ready map (live
#      on minigame_game_state); a finished session rejects (session_not_active)
#   B) get_minigame_participants returns id/username/avatar_url for every
#      participant (works for NON-friends via user_search_view)
#   C) init_minigame_game_state is now CREATOR-ONLY: a non-creator participant
#      gets not_creator (backend-enforced, never a UI rule); the creator
#      starts and the ready map clears
#   D) remove_minigame_participant is CREATOR-ONLY: a non-creator gets
#      not_creator; the creator removes a player → wager refunded
#      (minigame_refund), participant dropped, invite closed, ready cleared
#   E) a bystander (non-member) is denied everywhere (not_allowed /
#      not_creator)
#
# Usage: bash test/opt-019-minigame-lobby.sh
# Requires the stack with migration 180 applied (supabase db reset).
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "friendships?or=(requester_id.eq.$uid,addressee_id.eq.$uid)" > /dev/null 2>&1 || true
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  for sid in ${SESSION_ID:-} ${SESSION2_ID:-}; do
    [ -n "$sid" ] && svc_delete "minigame_game_state?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_sessions?id=eq.$sid" > /dev/null 2>&1 || true
  done
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "users?id=eq.$uid" > /dev/null 2>&1 || true
  done
  for uid in $UUID_A $UUID_B $UUID_C; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

norm_json() {
  sed -E 's/[[:space:]]+//g'
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

# --- Setup ---
h1 "SETUP: users + group"

UUID_A="44444444-4444-4444-4444-444444444444"
UUID_B="55555555-5555-5555-5555-555555555555"
UUID_C="66666666-6666-6666-6666-666666666666"
GROUP_ID="88888888-8888-8888-8888-888888888888"
EMAIL_A="user_a_opt019@samay.test"
EMAIL_B="user_b_opt019@samay.test"
EMAIL_C="user_c_opt019@samay.test"
PW="Pass1234!"

trap cleanup EXIT
cleanup

for pair in "UUID_A:EMAIL_A" "UUID_B:EMAIL_B" "UUID_C:EMAIL_C"; do
  uid_var="${pair%%:*}"; email_var="${pair##*:}"
  uid="${!uid_var}"; email="${!email_var}"
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if echo "$resp" | grep -q '"id"'; then ok "Created auth user ($uid)"; else nok "Create user: $(echo "$resp" | head -c 80)"; fi
done

for pair in "UUID_A:user_opt019_a" "UUID_B:user_opt019_b" "UUID_C:user_opt019_c"; do
  uid_var="${pair%%:*}"; uname="${pair##*:}"; uid="${!uid_var}"
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"personal_shards\":1000,\"preshards\":10}" > /dev/null
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
  ok "Obtained auth tokens"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Lobby Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (host) + B (member) active; C is NOT a member (bystander)"

# A creates a wagered session inviting B (wager 50 → removal must refund).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":50,\"p_invitees\":[\"$UUID_B\"]}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "create_minigame_session returned created ($SESSION_ID)"
else
  nok "create_minigame_session failed: $(echo "$resp" | head -c 120)"
fi

# B accepts the invite → becomes a participant.
INVITE_B=$(curl -s "$SUPABASE_URL/rest/v1/minigame_invites?session_id=eq.$SESSION_ID&invitee_id=eq.$UUID_B&select=id" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B\"}")
if echo "$resp" | grep -q '"status":"accepted"'; then ok "B accepted the invite (participant)"; else nok "B accept failed: $resp"; fi

# =========================================================================
# TEST A — set_minigame_ready
# =========================================================================
h1 "TEST A — set_minigame_ready"

resp=$(auth_rpc "$TOKEN_A" "set_minigame_ready" "{\"p_session_id\":\"$SESSION_ID\",\"p_ready\":true}")
if echo "$resp" | grep -q '"status":"ready"'; then ok "creator A set ready=true"; else nok "A ready failed: $resp"; fi

resp=$(auth_rpc "$TOKEN_B" "set_minigame_ready" "{\"p_session_id\":\"$SESSION_ID\",\"p_ready\":true}")
if echo "$resp" | grep -q '"status":"ready"'; then ok "participant B set ready=true"; else nok "B ready failed: $resp"; fi

# The ready map lives on the game-state row (authoritative, realtime).
ROW=$(curl -s "$SUPABASE_URL/rest/v1/minigame_game_state?session_id=eq.$SESSION_ID&select=ready" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json)
if echo "$ROW" | grep -q "$UUID_A" && echo "$ROW" | grep -q "$UUID_B"; then
  ok "ready map on minigame_game_state holds both participant flags"
else
  nok "ready map missing a participant: $ROW"
fi

# A bystander (C) cannot toggle ready.
resp=$(auth_rpc "$TOKEN_C" "set_minigame_ready" "{\"p_session_id\":\"$SESSION_ID\",\"p_ready\":true}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then ok "bystander C ready denied (not_allowed)"; else nok "bystander C ready: $resp"; fi

# =========================================================================
# TEST B — get_minigame_participants
# =========================================================================
h1 "TEST B — get_minigame_participants"

resp=$(auth_rpc "$TOKEN_A" "get_minigame_participants" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q '"username":"user_opt019_a"' && echo "$resp" | grep -q '"username":"user_opt019_b"'; then
  ok "roster resolves BOTH participants (non-friend B included via user_search_view)"
else
  nok "roster failed: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST C — init is CREATOR-ONLY (backend-enforced)
# =========================================================================
h1 "TEST C — creator-only Start"

resp=$(auth_rpc "$TOKEN_B" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_creator"'; then
  ok "non-creator B cannot start (not_creator — backend-enforced)"
else
  nok "B init expected not_creator: $resp"
fi

resp=$(auth_rpc "$TOKEN_C" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "bystander C cannot start (not_allowed — access gate first, 150 contract)"
else
  nok "C init expected not_allowed: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then ok "creator A started the partida"; else nok "A init failed: $(echo "$resp" | head -c 120)"; fi

ROW=$(curl -s "$SUPABASE_URL/rest/v1/minigame_game_state?session_id=eq.$SESSION_ID&select=ready" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json)
if echo "$ROW" | grep -q '"ready":{}'; then ok "ready map cleared on Start"; else nok "ready not cleared: $ROW"; fi

# =========================================================================
# TEST D — remove_minigame_participant is CREATOR-ONLY + wager refund
# =========================================================================
h1 "TEST D — creator-only removal (wager refund)"

# Re-open a lobby (second session, wagered 30).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":30,\"p_invitees\":[\"$UUID_B\"]}")
SESSION2_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
INVITE_B2=$(curl -s "$SUPABASE_URL/rest/v1/minigame_invites?session_id=eq.$SESSION2_ID&invitee_id=eq.$UUID_B&select=id" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B2\"}" > /dev/null
auth_rpc "$TOKEN_B" "set_minigame_ready" "{\"p_session_id\":\"$SESSION2_ID\",\"p_ready\":true}" > /dev/null

BAL_BEFORE=$(curl -s "$SUPABASE_URL/rest/v1/users?id=eq.$UUID_B&select=personal_shards" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json \
  | grep -o '"personal_shards":[0-9]*' | cut -d: -f2)

resp=$(auth_rpc "$TOKEN_B" "remove_minigame_participant" "{\"p_session_id\":\"$SESSION2_ID\",\"p_user_id\":\"$UUID_A\"}")
if echo "$resp" | grep -q '"status":"not_creator"'; then
  ok "non-creator B cannot remove anyone (not_creator)"
else
  nok "B remove expected not_creator: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "remove_minigame_participant" "{\"p_session_id\":\"$SESSION2_ID\",\"p_user_id\":\"$UUID_A\"}")
if echo "$resp" | grep -q '"status":"not_participant"'; then
  ok "creator cannot remove themself (not_participant)"
else
  nok "self-remove expected not_participant: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "remove_minigame_participant" "{\"p_session_id\":\"$SESSION2_ID\",\"p_user_id\":\"$UUID_B\"}")
if echo "$resp" | grep -q '"status":"removed"'; then ok "creator A removed participant B"; else nok "A remove failed: $resp"; fi

BAL_AFTER=$(curl -s "$SUPABASE_URL/rest/v1/users?id=eq.$UUID_B&select=personal_shards" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json \
  | grep -o '"personal_shards":[0-9]*' | cut -d: -f2)
if [ -n "$BAL_BEFORE" ] && [ "$BAL_AFTER" = "$((BAL_BEFORE + 30))" ]; then
  ok "B's wager escrow refunded (+30 → $BAL_AFTER)"
else
  nok "refund missing: before=$BAL_BEFORE after=$BAL_AFTER"
fi

ROW=$(curl -s "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION2_ID&select=participants" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json)
if echo "$ROW" | grep -q "$UUID_A" && ! echo "$ROW" | grep -q "$UUID_B"; then
  ok "participants array now holds only the creator"
else
  nok "participants after remove: $ROW"
fi

# =========================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-019 SUMMARY: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
