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

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
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
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":1000,\"preshards\":10,\"age_confirmed_at\":\"2026-01-01T00:00:00Z\",\"terms_accepted_at\":\"2026-01-01T00:00:00Z\"}" > /dev/null
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

# --- Test A: the open lobby is gone; discovery is code-only (239) ---
h1 "TEST A: public lobby removed — 6-character code only"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_name\":\"abierta opt029\",\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\",\"p_anonymous\":false}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$SESSION_ID" ] && echo "$resp" | grep -q '"status":"created"'; then
  ok "A created a direct partida ($SESSION_ID)"
else
  nok "create_minigame_session failed: $resp"
fi

resp=$(auth_rpc "$TOKEN_B" "set_minigame_public" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_is_public\":true}")
if echo "$resp" | grep -q "PGRST202"; then
  ok "set_minigame_public was removed"
else
  nok "set_minigame_public still exists: $resp"
fi
resp=$(auth_rpc "$TOKEN_B" "list_public_minigames" "{\"p_game_type\":\"truth_dare\"}")
if echo "$resp" | grep -q "PGRST202"; then
  ok "list_public_minigames was removed"
else
  nok "list_public_minigames still exists: $resp"
fi
resp=$(curl -s "$SUPABASE_URL/rest/v1/minigame_sessions?select=is_public&limit=1" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A")
if echo "$resp" | grep -qE "PGRST204|does not exist"; then
  ok "minigame_sessions.is_public was dropped"
else
  nok "is_public still selectable: $resp"
fi

# --- Test B: host-only code issuance ---
h1 "TEST B: set_minigame_join_code is host-only"

resp=$(auth_rpc "$TOKEN_B" "set_minigame_join_code" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_creator"'; then
  ok "a non-host cannot issue a join code"
else
  nok "non-host code issuance: $resp"
fi

SET=$(auth_rpc "$TOKEN_A" "set_minigame_join_code" "{\"p_session_id\":\"$SESSION_ID\"}")
CODE=$(echo "$SET" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("code",""))')
if [[ "$CODE" =~ ^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$ ]]; then
  ok "host received a valid 6-character code"
else
  nok "code shape: $SET"
fi

# --- Test C: join by code ---
h1 "TEST C: join_minigame_by_code"

resp=$(auth_rpc "$TOKEN_B" "join_minigame_by_code" "{\"p_code\":\"ZZZZZ2\"}")
if echo "$resp" | grep -q '"status":"invalid_code"'; then
  ok "a wrong code is rejected (invalid_code)"
else
  nok "wrong code: $resp"
fi
resp=$(auth_rpc "$TOKEN_B" "join_minigame_by_code" "{\"p_code\":\"$CODE\"}")
if echo "$resp" | grep -q '"status":"joined"' && echo "$resp" | grep -q "$SESSION_ID"; then
  ok "the matching code joins the partida"
else
  nok "join by code: $resp"
fi
PARTS=$(curl -s "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION_ID&select=participants" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
if echo "$PARTS" | grep -q "$UUID_B"; then
  ok "the joiner is appended to participants"
else
  nok "participants: $PARTS"
fi

# --- Test D: rotate / revoke ---
h1 "TEST D: rotate and revoke"

SET2=$(auth_rpc "$TOKEN_A" "set_minigame_join_code" "{\"p_session_id\":\"$SESSION_ID\"}")
CODE2=$(echo "$SET2" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("code",""))')
resp=$(auth_rpc "$TOKEN_C" "join_minigame_by_code" "{\"p_code\":\"$CODE\"}")
if echo "$resp" | grep -q '"status":"invalid_code"'; then
  ok "rotation invalidates the previous code"
else
  nok "old code after rotation: $resp"
fi
resp=$(auth_rpc "$TOKEN_C" "join_minigame_by_code" "{\"p_code\":\"$CODE2\"}")
if echo "$resp" | grep -q '"status":"joined"'; then
  ok "the rotated code joins"
else
  nok "rotated code: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "revoke_minigame_join_code" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"ok"'; then
  ok "the host revoked the code"
else
  nok "revoke: $resp"
fi
resp=$(auth_rpc "$TOKEN_B" "join_minigame_by_code" "{\"p_code\":\"$CODE2\"}")
if echo "$resp" | grep -q '"status":"invalid_code"'; then
  ok "a revoked code cannot join"
else
  nok "revoked code: $resp"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
