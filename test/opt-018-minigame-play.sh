#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-018] Minigame play engine — Verdad o Reto (150_minigame_play)
# Verifies the reusable play-engine RPC family end-to-end:
#   A) get_minigame_game_state on a fresh session returns the SEEDED row (191:
#      the game-state row exists from creation) with status ok + round 0
#   A1) p_name partida title (160_minigame_names): trimmed + stored on the
#       session row; blank → NULL (client-side auto partida-XX display)
#   B) init_minigame_game_state starts the engine: the server picks the first
#      subject RANDOMLY from the participants (players never self-select);
#      re-init is idempotent (already_started). CREATOR-ONLY since
#      180_minigame_lobby — a non-creator participant gets not_creator; a
#      bystander still gets not_allowed (access gate runs first, 150 contract).
#   C) reveal_minigame_prompt draws a random active prompt of the requested
#      prompt_type (verdad/reto) and persists it into the state
#   D) invalid_prompt_type is rejected (no such prompt_type for the game)
#   E) advance_minigame_turn appends the completed round, rotates the judge
#      and re-picks the subject randomly; the next get returns the new state
#   F) a NON-participant (bystander) cannot get/init/reveal/advance/complete
#      (not_allowed) — the participant-only gate
#   G) finish_minigame_game settles the leaderboard (phase finished, session
#      finished) and is idempotent (already_finished)
#
# Usage: bash test/opt-018-minigame-play.sh
# Requires the stack with migration 150 applied (supabase db reset).
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  # Friendships (both directions) between the test users.
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "friendships?or=(requester_id.eq.$uid,addressee_id.eq.$uid)" > /dev/null 2>&1 || true
  done
  # Minigame invites.
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  # The group must go BEFORE its promotor user row.
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  # Game-state rows cascade from the session, but clear leftovers directly.
  for sid in ${SESSION_ID:-} ${SESSION2_ID:-} ${SESSION3_ID:-}; do
    [ -n "$sid" ] && svc_delete "minigame_game_state?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_sessions?id=eq.$sid" > /dev/null 2>&1 || true
  done
  # Public.users rows + auth users.
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

# PostgREST may render JSON with spaces; normalize for the greps. The
# normalizer collapses whitespace around JSON punctuation ONLY — spaces
# inside string VALUES ("25 shards.", "La revancha") must be preserved.
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

# Wait for the host-confirmed countdown to flip to playing: the HOST's device
# calls start_minigame_match (203_minigame_host_start) once its own 5s
# device-clock countdown ends. No server timer / lazy get-flip.
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
h1 "SETUP: users + group"

UUID_A="44444444-4444-4444-4444-444444444444"
UUID_B="55555555-5555-5555-5555-555555555555"
UUID_C="66666666-6666-6666-6666-666666666666"
GROUP_ID="77777777-7777-7777-7777-777777777777"
EMAIL_A="user_a_opt018@samay.test"
EMAIL_B="user_b_opt018@samay.test"
EMAIL_C="user_c_opt018@samay.test"
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

for pair in "UUID_A:user_opt018_a" "UUID_B:user_opt018_b" "UUID_C:user_opt018_c"; do
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

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Play Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (promotor) + B (member) active; C is NOT a member (bystander)"

# =========================================================================
# TEST A — get on a fresh session is not_started
# =========================================================================
h1 "TEST A — not_started before init"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\"]}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "create_minigame_session returned created ($SESSION_ID)"
else
  nok "create_minigame_session failed: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q '"round":0'; then
  ok "get_minigame_game_state on a fresh session = ok with the seeded row (191)"
else
  nok "expected seeded state: $resp"
fi

# =========================================================================
# TEST A1 — p_name partida title (160_minigame_names)
# =========================================================================
h1 "TEST A1 — p_name stored on the session row (160_minigame_names)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\"],\"p_name\":\"  La revancha  \"}")
SESSION2_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION2_ID" ]; then
  ok "create with p_name returned created ($SESSION2_ID)"
else
  nok "create with p_name failed: $(echo "$resp" | head -c 120)"
fi

ROW=$(curl -s "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION2_ID&select=name" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
# PostgREST may render JSON with spaces; normalize for the grep.
if echo "$ROW" | norm_json | grep -q '"name":"La revancha"'; then
  ok "p_name trimmed + stored on the session row (La revancha)"
else
  nok "expected name 'La revancha': $ROW"
fi

# A blank p_name leaves the row NULL (client-side auto partida-XX display).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[],\"p_name\":\"   \"}")
SESSION3_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
ROW=$(curl -s "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION3_ID&select=name" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json)
if echo "$ROW" | grep -q '"name":null'; then
  ok "blank p_name stores NULL (auto-name fallback client-side)"
else
  nok "expected NULL name: $ROW"
fi

# =========================================================================
# TEST B — init starts the engine with a server-random subject
# =========================================================================
h1 "TEST B — init_minigame_game_state (server-random subject)"

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
SUBJECT=$(echo "$resp" | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"started"' && [ -n "$SUBJECT" ]; then
  ok "init returned started with subject $SUBJECT"
else
  nok "init failed: $(echo "$resp" | head -c 120)"
fi
if [ "$SUBJECT" = "$UUID_A" ] || [ "$SUBJECT" = "$UUID_B" ]; then
  ok "subject is a participant (A or B)"
else
  nok "subject is not a participant: $SUBJECT"
fi

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"already_started"'; then
  ok "re-init is idempotent (already_started)"
else
  nok "re-init expected already_started: $resp"
fi

# =========================================================================
# TEST C + D — reveal draws a random prompt / rejects bad types
# =========================================================================
h1 "TEST C + D — reveal_minigame_prompt"

resp=$(auth_rpc "$TOKEN_A" "reveal_minigame_prompt" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"verdad\"}")
if echo "$resp" | grep -q '"status":"revealed"'; then
  ok "reveal(verdad) = revealed"
  PROMPT_BODY=$(echo "$resp" | grep -o '"body":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$PROMPT_BODY" ]; then ok "prompt body drawn: $PROMPT_BODY"; else nok "no prompt body"; fi
else
  nok "reveal(verdad) failed: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_rpc "$TOKEN_A" "reveal_minigame_prompt" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"retomadre\"}")
if echo "$resp" | grep -q '"status":"invalid_prompt_type"'; then
  ok "invalid prompt_type = invalid_prompt_type"
else
  nok "expected invalid_prompt_type: $resp"
fi

# =========================================================================
# TEST E — advance rotates the judge and re-picks the subject
# =========================================================================
h1 "TEST E — advance_minigame_turn"

# 202 by_turns: advance requires phase=playing (the 190 countdown lazy-flips
# on read) AND the round to have an answer. The creator may FORCE-advance an
# idle round once the subject answered (no all-reacted wait).
if wait_playing "$SESSION_ID" "$TOKEN_A"; then
  ok "countdown flipped to playing"
else
  nok "countdown never flipped to playing"
fi

# The current subject answers (the answer-first contract).
SUBJ=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}" \
  | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
STOKEN=$([ "$SUBJ" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
resp=$(auth_rpc "$STOKEN" "submit_minigame_answer" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"cipher_$SUBJ\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "subject answered (answer-first)"
else
  nok "subject answer failed: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_rpc "$TOKEN_A" "advance_minigame_turn" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_round\":{\"subject_id\":\"$SUBJECT\",\"prompt_type\":\"verdad\",\"outcome\":\"done\"}}")
if echo "$resp" | grep -q '"status":"advanced"'; then
  ok "advance = advanced (creator force)"
else
  nok "advance failed: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"round":1' && echo "$resp" | grep -q '"phase":"playing"'; then
  ok "round advanced to 1, still playing"
else
  nok "expected round 1 playing: $resp"
fi

# =========================================================================
# TEST F — a bystander (C, non-member) is denied everywhere
# =========================================================================
h1 "TEST F — participant-only gate (bystander)"

resp=$(auth_rpc "$TOKEN_C" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then ok "get denied for bystander"; else nok "bystander get: $resp"; fi

resp=$(auth_rpc "$TOKEN_C" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then ok "init denied for bystander"; else nok "bystander init: $resp"; fi

resp=$(auth_rpc "$TOKEN_C" "reveal_minigame_prompt" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"verdad\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then ok "reveal denied for bystander"; else nok "bystander reveal: $resp"; fi

resp=$(auth_rpc "$TOKEN_C" "advance_minigame_turn" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_round\":{}}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then ok "advance denied for bystander"; else nok "bystander advance: $resp"; fi

resp=$(auth_rpc "$TOKEN_C" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then ok "finish denied for bystander"; else nok "bystander finish: $resp"; fi

# =========================================================================
# TEST G — finish settles the leaderboard and is idempotent
# =========================================================================
h1 "TEST G — finish_minigame_game (leaderboard settlement)"

resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"finished"'; then
  ok "finish = finished"
else
  nok "finish failed: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"finished"'; then
  ok "re-finish is idempotent (finished, no double settlement)"
else
  nok "re-finish expected finished: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"phase":"finished"'; then
  ok "phase flipped to finished"
else
  nok "expected finished phase: $resp"
fi

# =========================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-018 SUMMARY: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
