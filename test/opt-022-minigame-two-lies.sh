#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-022] Minigame: Two Lies, One Truth (206_minigame_two_lies_one_truth)
# Verifies the "2 mentiras, 1 verdad" game type end-to-end:
#   A) create_minigame_session accepts game_type = 'two_lies_one_truth'
#   B) The subject submits an encrypted payload with 3 statements via
#      submit_minigame_answer
#   C) Other participants vote for one of the statements using 'vote_0',
#      'vote_1', or 'vote_2' via submit_minigame_reaction
#   D) When all non-subject participants have voted, the round advances
#   E) Settle and finish via finish_minigame_game
#
# Usage: bash test/opt-022-minigame-two-lies.sh
# Requires the stack with migration 206 applied.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  for sid in ${SESSION_ID:-}; do
    [ -n "$sid" ] && svc_delete "minigame_reactions?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_results?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_answers?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_aliases?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_e2ee_bundles?session_id=eq.$sid" > /dev/null 2>&1 || true
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

wait_playing() {
  local sid=$1 token=$2 tries=0
  while [ "$tries" -lt 20 ]; do
    resp=$(auth_rpc "$token" "start_minigame_match" "{\"p_session_id\":\"$sid\"}")
    if echo "$resp" | grep -q '"status":"started"'; then
      return 0
    fi
    sleep 0.5
    tries=$((tries + 1))
  done
  return 1
}

# --- Setup ---
h1 "SETUP: users + session for two_lies_one_truth"

UUID_A="88888888-8888-4888-8888-888888888888"
UUID_B="88888888-8888-4888-8888-888888888889"
UUID_C="88888888-8888-4888-8888-88888888888a"
EMAIL_A="user_a_opt022@samay.test"
EMAIL_B="user_b_opt022@samay.test"
EMAIL_C="user_c_opt022@samay.test"
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

for pair in "UUID_A:user_opt022_a" "UUID_B:user_opt022_b" "UUID_C:user_opt022_c"; do
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

# --- Test A: Session creation with game_type = 'two_lies_one_truth' ---
h1 "TEST A: Create session with game_type = 'two_lies_one_truth'"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"two_lies_one_truth\",\"p_wager\":0,\"p_name\":\"partida 2 mentiras\",\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\",\"p_anonymous\":false}")
SESSION_ID=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -n "$SESSION_ID" ] && echo "$resp" | grep -q '"status":"created"'; then
  ok "create_minigame_session accepted 'two_lies_one_truth' (session $SESSION_ID)"
else
  nok "create_minigame_session failed: $resp"
fi

# --- Test B: Lobby invites + join ---
h1 "TEST B: Lobby invite and start"

resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
if echo "$resp" | grep -q '"status":"ok"'; then
  ok "Invited B and C from lobby"
else
  nok "Invite players failed: $resp"
fi

auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_session_id\":\"$SESSION_ID\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_session_id\":\"$SESSION_ID\"}" > /dev/null
ok "B and C accepted invite"

auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}" > /dev/null
if wait_playing "$SESSION_ID" "$TOKEN_A"; then
  ok "Match started and flipped to playing"
else
  nok "Failed to flip match to playing"
fi

# --- Test C: Answer + Vote mechanics ---
h1 "TEST C: Answer statements + vote_0..2 reactions"

state_resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
SUBJECT_ID=$(echo "$state_resp" | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
info "Server-selected subject: $SUBJECT_ID"

SUBJ_TOKEN="$TOKEN_A"
VOTER1_TOKEN="$TOKEN_B"
VOTER2_TOKEN="$TOKEN_C"
if [ "$SUBJECT_ID" = "$UUID_B" ]; then
  SUBJ_TOKEN="$TOKEN_B"; VOTER1_TOKEN="$TOKEN_A"; VOTER2_TOKEN="$TOKEN_C"
elif [ "$SUBJECT_ID" = "$UUID_C" ]; then
  SUBJ_TOKEN="$TOKEN_C"; VOTER1_TOKEN="$TOKEN_A"; VOTER2_TOKEN="$TOKEN_B"
fi

# Subject submits 3 statements payload
PAYLOAD='{"statements":[{"index":0,"text":"Mentira 1","is_truth":false},{"index":1,"text":"Verdad real","is_truth":true},{"index":2,"text":"Mentira 2","is_truth":false}],"truth_index":1}'
resp=$(auth_rpc "$SUBJ_TOKEN" "submit_minigame_answer" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"$PAYLOAD\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "Subject submitted 3 statements ciphertext"
else
  nok "Subject submit failed: $resp"
fi

# Voter 1 votes for option 1 ('vote_1')
resp=$(auth_rpc "$VOTER1_TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"vote_1\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "Voter 1 voted for truth ('vote_1')"
else
  nok "Voter 1 vote failed: $resp"
fi

# Voter 2 votes for option 0 ('vote_0') -> auto-advances the round!
resp=$(auth_rpc "$VOTER2_TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"vote_0\"}")
if echo "$resp" | grep -q '"status":"advanced"'; then
  ok "Voter 2 voted ('vote_0') and round auto-advanced"
else
  nok "Voter 2 vote / auto-advance failed: $resp"
fi

# --- Test D: Settlement ---
h1 "TEST D: Settle match"

resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"finished"'; then
  ok "finish_minigame_game settled match with 'two_lies_one_truth'"
else
  nok "Settlement failed: $resp"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
