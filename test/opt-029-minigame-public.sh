#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-029] Minigame: public (open) partidas (211_minigame_public)
# Verifies the published-partida surface end-to-end:
#   A) only the HOST publishes (set_minigame_public) and only DIRECT sessions
#      can be published (a group partida → group_session)
#   B) list_public_minigames returns the published, open, direct partida with
#      the host username and is_member=false for a non-participant
#   C) a signed-in stranger joins a published partida (join_minigame_session
#      → joined) and is_member flips true
#   D) after the host UNPUBLISHES, the partida leaves the feed and a
#      stranger's join is rejected not_allowed
#
# Usage: bash test/opt-029-minigame-public.sh
# Requires the stack with migration 211 applied.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  [ -n "${GROUP_ID:-}" ] && svc_delete "group_members?group_id=eq.$GROUP_ID" > /dev/null 2>&1 || true
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  for sid in ${SESSION_ID:-} ${GSESSION_ID:-}; do
    [ -n "$sid" ] && svc_delete "minigame_reactions?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_answers?session_id=eq.$sid" > /dev/null 2>&1 || true
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
h1 "SETUP: users + a direct partida"

UUID_A="99999999-9999-4999-9999-999999999999"
UUID_B="99999999-9999-4999-9999-999999999998"
UUID_C="99999999-9999-4999-9999-999999999997"
EMAIL_A="user_a_opt029@samay.test"
EMAIL_B="user_b_opt029@samay.test"
EMAIL_C="user_c_opt029@samay.test"
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

for pair in "UUID_A:user_opt029_a" "UUID_B:user_opt029_b" "UUID_C:user_opt029_c"; do
  uid_var="${pair%%:*}"; uname="${pair##*:}"; uid="${!uid_var}"
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":1000,\"preshards\":10}" > /dev/null
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

# --- Test A: publish / permissions ---
h1 "TEST A: set_minigame_public — host-only, direct-only"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_name\":\"abierta opt029\",\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\",\"p_anonymous\":false}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$SESSION_ID" ] && echo "$resp" | grep -q '"status":"created"'; then
  ok "A created a direct partida ($SESSION_ID)"
else
  nok "create_minigame_session failed: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "set_minigame_public" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_is_public\":true}")
if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q '"is_public":true'; then
  ok "host published the partida (set_minigame_public ok)"
else
  nok "publish failed: $resp"
fi

resp=$(auth_rpc "$TOKEN_B" "set_minigame_public" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_is_public\":true}")
if echo "$resp" | grep -q '"status":"not_creator"'; then
  ok "non-host publish rejected (not_creator)"
else
  nok "non-host publish was not rejected: $resp"
fi

GROUP_ID=$(python3 -c "import uuid;print(uuid.uuid4())")
svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"opt029 group\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_name\":\"g opt029\",\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\",\"p_anonymous\":false}")
GSESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_A" "set_minigame_public" \
  "{\"p_session_id\":\"$GSESSION_ID\",\"p_is_public\":true}")
if echo "$resp" | grep -q '"status":"group_session"'; then
  ok "group partida cannot be published (group_session)"
else
  nok "group publish was not rejected: $resp"
fi

# --- Test B: the open lobby feed ---
h1 "TEST B: list_public_minigames"

resp=$(auth_rpc "$TOKEN_B" "list_public_minigames" "{\"p_game_type\":\"truth_dare\"}")
if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q "$SESSION_ID"; then
  ok "published partida appears in the feed"
else
  nok "published partida missing from the feed: $(echo "$resp" | head -c 160)"
fi
if echo "$resp" | grep -q '"host_username":"user_opt029_a"'; then
  ok "feed row carries the host username"
else
  nok "feed row missing host_username: $(echo "$resp" | head -c 160)"
fi
if echo "$resp" | grep -q '"is_member":false'; then
  ok "a non-participant reads is_member=false"
else
  nok "is_member should be false before joining: $(echo "$resp" | head -c 160)"
fi

# --- Test C: a stranger joins the published partida ---
h1 "TEST C: public join"

resp=$(auth_rpc "$TOKEN_B" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"joined"'; then
  ok "stranger joined the published partida (joined)"
else
  nok "public join failed: $resp"
fi

resp=$(auth_rpc "$TOKEN_B" "list_public_minigames" "{\"p_game_type\":\"truth_dare\"}")
if echo "$resp" | grep -q "$SESSION_ID" && echo "$resp" | grep -q '"is_member":true'; then
  ok "the joiner now reads is_member=true"
else
  nok "is_member did not flip after joining: $(echo "$resp" | head -c 160)"
fi

# --- Test D: unpublish closes the lobby door ---
h1 "TEST D: unpublish"

resp=$(auth_rpc "$TOKEN_A" "set_minigame_public" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_is_public\":false}")
if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q '"is_public":false'; then
  ok "host unpublished the partida"
else
  nok "unpublish failed: $resp"
fi

resp=$(auth_rpc "$TOKEN_B" "list_public_minigames" "{\"p_game_type\":\"truth_dare\"}")
if echo "$resp" | grep -q "$SESSION_ID"; then
  nok "unpublished partida still in the feed"
else
  ok "unpublished partida left the feed"
fi

resp=$(auth_rpc "$TOKEN_C" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "a stranger can no longer join an unpublished partida (not_allowed)"
else
  nok "unpublished join was not rejected: $resp"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
