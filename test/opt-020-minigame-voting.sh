#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-020] Minigame rounds + reaction voting + leaderboard (201_minigame_voting)
# Verifies the voting/leaderboard feature end-to-end:
#   A) create_minigame_session accepts p_rounds + p_prize_positions, freezes
#      them on the session row, and seeds the game-state payload with
#      round_target + prize_positions.
#   B) invalid p_rounds (0 / negative) and invalid p_prize_positions are
#      rejected atomically.
#   C) submit_minigame_reaction persists a voter's emoji vote for the current
#      round and mirrors it into state.reactions (realtime); re-voting replaces
#      (one vote per voter per round); a bystander is denied. The 202
#      answer-first contract gates reactions on the subject's answer
#      (answer_pending / own_round negatives) and the mirror now carries
#      {subject: {"list": [...], "count": N}}.
#   D) when EVERY non-subject participant has reacted the round closes and
#      AUTO-ADVANCES (202 by_turns), scoring the round server-side (reaction
#      count) and clearing the reactions payload.
#   E) AUTO-FINISH: when the round counter reaches round_target the game ends
#      automatically via finish_minigame_game (no host tap) — phase + session
#      flip to finished.
#   F) finish_minigame_game writes the minigame_results leaderboard and pays
#      the prize split (HARMONIC 1/rank over N = prize_positions places,
#      integer-exact).
#   H) full ranking (218_minigame_full_ranking): EVERY participant carries a
#      ranked row (rank 1..P, unique); only N = prize_positions are paid and
#      every rank > N writes prize 0; the harmonic split still sums to the pot.
#
# Usage: bash test/opt-020-minigame-voting.sh
# Requires the stack with migration 218 applied.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  for sid in ${SESSION_ID:-} ${SESSION2_ID:-} ${GSESSION_ID:-}; do
    [ -n "$sid" ] && svc_delete "minigame_reactions?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_results?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_game_state?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_sessions?id=eq.$sid" > /dev/null 2>&1 || true
  done
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    svc_delete "users?id=eq.$uid" > /dev/null 2>&1 || true
  done
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
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

# The 207 server reaction spam gate drops a same-voter write inside 250 ms of
# the previous ACCEPTED write (status `too_fast`). API-level cases model
# DELIBERATE spaced taps (the real client's tap timer is 350 ms), so sleep just
# past the server window between consecutive accepted taps by the same voter.
tap_wait() { sleep 0.3; }

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
svc_get() {
  curl -s "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
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
UUID_D="88888888-8888-8888-8888-888888888888"
GROUP_ID="77777777-7777-7777-7777-777777777777"
EMAIL_A="user_a_opt020@samay.test"
EMAIL_B="user_b_opt020@samay.test"
EMAIL_C="user_c_opt020@samay.test"
EMAIL_D="user_d_opt020@samay.test"
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

for pair in "UUID_A:user_opt020_a" "UUID_B:user_opt020_b" "UUID_C:user_opt020_c" "UUID_D:user_opt020_d"; do
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
TOKEN_D=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_D\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ] && [ -n "$TOKEN_D" ]; then
  ok "Obtained auth tokens"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Vote Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_C\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (host) + B + C (members) active; D is NOT a member (bystander)"

# =========================================================================
# TEST A — create with rounds + prize positions
# =========================================================================
h1 "TEST A — create with p_rounds + p_prize_positions"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":50,\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":3,\"p_prize_positions\":3}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "create with rounds=3, prize_positions=3 returned created ($SESSION_ID)"
else
  nok "create failed: $(echo "$resp" | head -c 120)"
fi

# B + C join (accept the invites) so the roster is 3 participants (pot = 150).
INVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
INVITE_C=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION_ID&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B\"}")
resp2=$(auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_C\"}")
if echo "$resp" | grep -q '"status":"accepted"' && echo "$resp2" | grep -q '"status":"accepted"'; then
  ok "B + C accepted the invites (3 participants, pot 150)"
else
  nok "B/C accept failed: $(echo "$resp" | head -c 120) $(echo "$resp2" | head -c 120)"
fi

ROW=$(svc_get "minigame_sessions?id=eq.$SESSION_ID&select=round_target,prize_positions" | norm_json)
if echo "$ROW" | grep -q '"round_target":3' && echo "$ROW" | grep -q '"prize_positions":3'; then
  ok "round_target + prize_positions frozen on the session row"
else
  nok "session row wrong: $ROW"
fi

# The seeded game-state payload carries the round target + prize positions.
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"round_target":3' && echo "$resp" | grep -q '"prize_positions":3'; then
  ok "game-state payload seeded with round_target + prize_positions"
else
  nok "game-state payload wrong: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST B — validation gates
# =========================================================================
h1 "TEST B — invalid rounds / prize positions rejected"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_rounds\":0}")
if echo "$resp" | grep -q '"status":"invalid_rounds"'; then
  ok "p_rounds=0 rejected (invalid_rounds)"
else
  nok "invalid_rounds NOT rejected: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_prize_positions\":0}")
if echo "$resp" | grep -q '"status":"invalid_prize_positions"'; then
  ok "p_prize_positions=0 rejected (invalid_prize_positions)"
else
  nok "invalid_prize_positions NOT rejected: $resp"
fi

# =========================================================================
# TEST C — answer-first + reaction voting (202 contract)
# =========================================================================
h1 "TEST C — answer-first gate + submit_minigame_reaction (realtime votes)"

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
SUBJECT=$(echo "$resp" | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"started"' && [ -n "$SUBJECT" ]; then
  ok "init started with subject $SUBJECT"
else
  nok "init failed: $(echo "$resp" | head -c 120)"
fi

# 190: the init seeds a 5s countdown — wait for the playing flip.
if wait_playing "$SESSION_ID" "$TOKEN_A"; then
  ok "countdown flipped to playing"
else
  nok "countdown never flipped to playing"
fi

resp=$(auth_rpc "$TOKEN_A" "reveal_minigame_prompt" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"verdad\"}")
if echo "$resp" | grep -q '"status":"revealed"'; then
  ok "reveal(verdad) = revealed"
else
  nok "reveal failed: $(echo "$resp" | head -c 120)"
fi

# The two non-subject participants are the voters (3 players → 2 required).
VOTER1=$([ "$SUBJECT" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
V1TOKEN=$([ "$VOTER1" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
VOTER2=$([ "$SUBJECT" = "$UUID_A" ] && echo "$UUID_C" || echo "$UUID_C")
V2TOKEN=$([ "$VOTER2" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_C")
if [ "$SUBJECT" = "$UUID_B" ]; then
  VOTER2="$UUID_C"; V2TOKEN="$TOKEN_C"
fi
if [ "$SUBJECT" = "$UUID_C" ]; then
  VOTER2="$UUID_B"; V2TOKEN="$TOKEN_B"
fi
S_TOKEN=$([ "$SUBJECT" = "$UUID_A" ] && echo "$TOKEN_A" || ([ "$SUBJECT" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C"))
info "Round subject=$SUBJECT, voters=$VOTER1/$VOTER2"

# Negative gate 1: a reaction BEFORE the subject answers is rejected.
resp=$(auth_rpc "$V1TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"answer_pending"'; then
  ok "reaction before the answer rejected (answer_pending)"
else
  nok "answer_pending NOT enforced: $resp"
fi

# Negative gate 2: the subject can never react to their own round.
resp=$(auth_rpc "$S_TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"own_round"'; then
  ok "subject own-round reaction rejected (own_round)"
else
  nok "own_round NOT enforced: $resp"
fi

# The subject submits their answer → reactions open.
resp=$(auth_rpc "$S_TOKEN" "submit_minigame_answer" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"cipher_$SUBJECT\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "subject answer submitted"
else
  nok "subject answer failed: $(echo "$resp" | head -c 120)"
fi

# VOTER1 votes → mirror carries the vote list + distinct-voter count.
resp=$(auth_rpc "$V1TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "VOTER1 submitted a heart vote (submitted — not all voters yet)"
else
  nok "VOTER1 submit failed: $(echo "$resp" | head -c 120)"
fi

# The mirror shape: {<subject_id>: {"list": [...], "count": N}}.
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q "\"$SUBJECT\"" && echo "$resp" | grep -q '"count":1' && echo "$resp" | grep -q '"list":'; then
  ok "mirrored reactions carry {subject: {\"list\": [...], \"count\": 1}}"
else
  nok "reactions mirror wrong: $(echo "$resp" | head -c 200)"
fi

# VOTER1 re-votes (heart -> excited) — replaces, count stays 1 (distinct).
tap_wait
resp=$(auth_rpc "$V1TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"excited\"}")
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"excited"' && echo "$resp" | grep -q '"count":1' && ! echo "$resp" | grep -q '"heart"'; then
  ok "re-vote replaces the voter's emoji (count stays 1 distinct)"
else
  nok "re-vote did not replace: $(echo "$resp" | head -c 200)"
fi

# A bystander (D, non-member) cannot vote.
resp=$(auth_rpc "$TOKEN_D" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"sad\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "bystander vote denied (not_allowed)"
else
  nok "bystander vote NOT denied: $resp"
fi

# Invalid emoji key rejected (by a non-subject voter after the answer).
resp=$(auth_rpc "$V1TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"bogus\"}")
if echo "$resp" | grep -q '"status":"invalid_reaction"'; then
  ok "invalid emoji rejected (invalid_reaction)"
else
  nok "invalid_reaction NOT rejected: $resp"
fi

# =========================================================================
# TEST D — last-required vote auto-advances the round (202 by_turns)
# =========================================================================
h1 "TEST D — the last required reaction auto-advances + scores the round"

# VOTER2's reaction closes the round (2 required voters → both voted).
resp=$(auth_rpc "$V2TOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"sad\"}")
if echo "$resp" | grep -q '"status":"advanced"'; then
  ok "last-required reaction auto-advanced the round"
else
  nok "all-reacted auto-advance failed: $(echo "$resp" | head -c 160)"
fi

# The round record carries the server-computed score (2 distinct voters here).
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"score":2'; then
  ok "round record scored 2 (reaction count)"
else
  nok "expected score:2 in the round record: $(echo "$resp" | head -c 200)"
fi

# =========================================================================
# TEST G — reactor-side Pasar (204_minigame_pasar): a voter passes instead of
# emoji-reacting; the subject scores emoji_count - 0.5 per passer; passers
# count as "reacted" for the all-reacted auto-advance. Uses a DEDICATED
# session so it never consumes rounds from TEST E's auto-finish flow.
# =========================================================================
h1 "TEST G — reactor Pasar (pass counts toward advance + scores -0.5 to the subject)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":2,\"p_prize_positions\":3}")
GSESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$GSESSION_ID" ]; then
  ok "G: dedicated Pasar session created ($GSESSION_ID)"
else
  nok "G: create failed: $(echo "$resp" | head -c 160)"
fi
GINVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$GSESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
GINVITE_C=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$GSESSION_ID&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$GINVITE_B\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$GINVITE_C\"}" > /dev/null
info "G: B + C accepted the Pasar-session invites (3 participants)"

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$GSESSION_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then
  ok "G: init started"
else
  nok "G: init failed: $(echo "$resp" | head -c 120)"
fi
if wait_playing "$GSESSION_ID" "$TOKEN_A"; then
  ok "G: countdown flipped to playing"
else
  nok "G: countdown never flipped"
fi

resp=$(auth_rpc "$TOKEN_A" "reveal_minigame_prompt" \
  "{\"p_session_id\":\"$GSESSION_ID\",\"p_prompt_type\":\"verdad\"}")
GSUB=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$GSESSION_ID\"}" \
  | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
GSTOKEN=$([ "$GSUB" = "$UUID_A" ] && echo "$TOKEN_A" || ([ "$GSUB" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C"))
GV1=$([ "$GSUB" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
GV1T=$([ "$GV1" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
GV2=$([ "$GSUB" = "$UUID_B" ] && echo "$UUID_C" || echo "$UUID_C")
[ "$GSUB" = "$UUID_A" ] && GV2="$UUID_C"
[ "$GSUB" = "$UUID_C" ] && GV2="$UUID_B"
GV2T=$([ "$GV2" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C")
info "G: round subject=$GSUB, voters=$GV1/$GV2"

# A pass BEFORE the subject answers is still rejected (answer-first applies).
resp=$(auth_rpc "$GV2T" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$GSESSION_ID\",\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"answer_pending"'; then
  ok "G: reactor pass before the answer rejected (answer_pending)"
else
  nok "G: pass before answer NOT rejected: $resp"
fi

# The subject can never pass their own round (own_round gate holds for pass).
resp=$(auth_rpc "$GSTOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$GSESSION_ID\",\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"own_round"'; then
  ok "G: subject own-round pass rejected (own_round)"
else
  nok "G: subject own-round pass NOT rejected: $resp"
fi

# The subject answers, then VOTER1 emoji-reacts and VOTER2 PASSES. VOTER2's
# pass is the last required action → auto-advance; the round scores 0.5
# (1 emoji - 0.5 for the pass).
resp=$(auth_rpc "$GSTOKEN" "submit_minigame_answer" \
  "{\"p_session_id\":\"$GSESSION_ID\",\"p_answer_ciphertext\":\"cipher_g_$GSUB\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "G: subject answer submitted"
else
  nok "G: subject answer failed: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_rpc "$GV1T" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$GSESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "G: VOTER1 emoji-voted (heart)"
else
  nok "G: VOTER1 emoji vote failed: $(echo "$resp" | head -c 120)"
fi

# VOTER2 passes on the answered round — the last required action advances.
resp=$(auth_rpc "$GV2T" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$GSESSION_ID\",\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"advanced"'; then
  ok "G: reactor pass auto-advanced the round (passer counts as reacted)"
else
  nok "G: pass auto-advance failed: $(echo "$resp" | head -c 160)"
fi

# The round record carries 0.5 (1 emoji - 0.5 pass).
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$GSESSION_ID\"}")
if echo "$resp" | grep -q '"score":0.5'; then
  ok "G: round scored 0.5 (1 emoji - 0.5 pass)"
else
  nok "G: expected score 0.5: $(echo "$resp" | head -c 240)"
fi

# The final leaderboard carries the fractional total (0.5 for the subject's
# single scored round — the other two players have no rounds → 0). The game
# is not finished yet (round_target 2) — no results row expected.
results=$(svc_get "minigame_results?session_id=eq.$GSESSION_ID&select=results" 2>/dev/null || true)
if [ "$results" = "[]" ] || [ -z "$results" ] || echo "$results" | grep -q '"message"'; then
  ok "G: no results row yet (game still active, target 2)"
else
  nok "G: unexpected results row while active: $results"
fi

# =========================================================================
# TEST E — auto-finish at the round target (each round = answer + all react)
# =========================================================================
h1 "TEST E — AUTO-FINISH when the round counter reaches round_target"

# Two more full rounds reach round 3 == round_target → the game finishes on
# the final auto-advance (no host tap). Each round: reveal → subject answers
# → the two non-subject voters react (last one auto-advances).
for i in 2 3; do
  resp=$(auth_rpc "$TOKEN_A" "reveal_minigame_prompt" \
    "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"verdad\"}")
  if ! echo "$resp" | grep -q '"status":"revealed"'; then
    nok "reveal on round $i failed: $(echo "$resp" | head -c 160)"
    continue
  fi
  SUBJ=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}" \
    | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
  STOKEN=$([ "$SUBJ" = "$UUID_A" ] && echo "$TOKEN_A" || ([ "$SUBJ" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C"))
  V1=$([ "$SUBJ" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
  V1T=$([ "$V1" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
  V2=$([ "$SUBJ" = "$UUID_B" ] && echo "$UUID_C" || echo "$UUID_C")
  [ "$SUBJ" = "$UUID_A" ] && V2="$UUID_C"
  [ "$SUBJ" = "$UUID_C" ] && V2="$UUID_B"
  V2T=$([ "$V2" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C")
  # Subject answers, then the two voters react (last one auto-advances).
  auth_rpc "$STOKEN" "submit_minigame_answer" \
    "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"cipher_r${i}_$SUBJ\"}" > /dev/null
  auth_rpc "$V1T" "submit_minigame_reaction" \
    "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}" > /dev/null
  resp=$(auth_rpc "$V2T" "submit_minigame_reaction" \
    "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
  if echo "$resp" | grep -q '"status":"finished"'; then
    ok "advance on round $i auto-finished the game"
  elif echo "$resp" | grep -q '"status":"advanced"'; then
    ok "advance on round $i still playing (target 3)"
  else
    nok "advance on round $i unexpected: $(echo "$resp" | head -c 160)"
  fi
done

resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"phase":"finished"'; then
  ok "phase flipped to finished"
else
  nok "expected finished phase: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST F — leaderboard + prize payout (harmonic N)
# =========================================================================
h1 "TEST F — minigame_results leaderboard + prize payout"

results=$(svc_get "minigame_results?session_id=eq.$SESSION_ID&select=results")
if echo "$results" | grep -q '"rank"'; then
  ok "minigame_results leaderboard row written"
else
  nok "minigame_results missing: $(echo "$results" | head -c 160)"
fi

# The pot was 50 x 3 = 150. The subject is server-random each round, so the
# exact per-player split is non-deterministic — the invariant is that the FULL
# pot is preserved (three players wagered 50 → total 3000 shards across them,
# back to exactly 3000 after the settlement, with the pot paid out).
shards_a=$(svc_get "users?id=eq.$UUID_A&select=personal_shards" | norm_json)
shards_b=$(svc_get "users?id=eq.$UUID_B&select=personal_shards" | norm_json)
shards_c=$(svc_get "users?id=eq.$UUID_C&select=personal_shards" | norm_json)
A_VAL=$(echo "$shards_a" | grep -o '"personal_shards":[0-9]*' | cut -d: -f2)
B_VAL=$(echo "$shards_b" | grep -o '"personal_shards":[0-9]*' | cut -d: -f2)
C_VAL=$(echo "$shards_c" | grep -o '"personal_shards":[0-9]*' | cut -d: -f2)
if [ "$((A_VAL + B_VAL + C_VAL))" = "3000" ] && [ "$A_VAL" -ne 950 ] && [ "$B_VAL" -ne 950 ] && [ "$C_VAL" -ne 950 ]; then
  ok "The full 150-shard pot was paid out (A+B+C back to 3000, winners credited)"
else
  nok "Pot not preserved: A=$A_VAL B=$B_VAL C=$C_VAL (want sum 3000)"
fi

# The winners got minigame_win ledger entries summing to the pot.
ledger=$(svc_get "shard_ledger?reference_id=eq.$SESSION_ID&select=reason,delta" | norm_json)
WIN_TOTAL=$(echo "$ledger" | grep -o '"reason":"minigame_win"' | wc -l | tr -d ' ')
if [ "$WIN_TOTAL" -ge 1 ]; then
  ok "minigame_win ledger rows written for the prize split"
else
  nok "no minigame_win ledger rows: $ledger"
fi

# =========================================================================
# TEST H — full ranking (218_minigame_full_ranking): EVERY participant gets a
# ranked row, but only N = prize_positions are paid; rank > N writes prize 0.
# =========================================================================
h1 "TEST H — full ranking: all participants ranked, only N paid"

# Dedicated 3-player session with N = 2 so exactly one player is UNPAID.
# Settled straight from create (status active, no rounds) — every score is 0
# and the tie-break is participant order (A=1, B=2, C=3), fully deterministic.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":50,\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":3,\"p_prize_positions\":2}")
SESSION2_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION2_ID" ]; then
  ok "H: 3-player session with N=2 created ($SESSION2_ID)"
else
  nok "H: create failed: $(echo "$resp" | head -c 160)"
fi
HINV_B=$(svc_get "minigame_invites?select=id&session_id=eq.$SESSION2_ID&invitee_id=eq.$UUID_B" \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
HINV_C=$(svc_get "minigame_invites?select=id&session_id=eq.$SESSION2_ID&invitee_id=eq.$UUID_C" \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$HINV_B\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$HINV_C\"}" > /dev/null

resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION2_ID\"}")
if echo "$resp" | grep -q '"status":"finished"'; then
  ok "H: session settled (finished)"
else
  nok "H: finish failed: $(echo "$resp" | head -c 160)"
fi

results=$(svc_get "minigame_results?session_id=eq.$SESSION2_ID&select=results" | norm_json)
RANK_ROWS=$(echo "$results" | grep -o '"rank":[0-9]*' | wc -l | tr -d ' ')
if [ "$RANK_ROWS" = "3" ]; then
  ok "H: ALL 3 participants carry a ranked row (was top-N only before 218)"
else
  nok "H: expected 3 ranked rows, got $RANK_ROWS: $(echo "$results" | head -c 220)"
fi
if echo "$results" | grep -q '"rank":1' && echo "$results" | grep -q '"rank":2' && echo "$results" | grep -q '"rank":3'; then
  ok "H: ranks 1..3 are all present (unique positions)"
else
  nok "H: ranks 1..3 missing: $(echo "$results" | head -c 220)"
fi

# Pot = 50 x 3 = 150, split harmonically across N = 2 (250/3 -> 100 + 50).
PRIZES=$(echo "$results" | grep -o '"prize":[0-9]*' | cut -d: -f2)
NONZERO=$(echo "$PRIZES" | awk '$1>0{c++} END{print c+0}')
ZEROS=$(echo "$PRIZES" | awk '$1==0{c++} END{print c+0}')
PRIZE_SUM=$(echo "$PRIZES" | awk '{s+=$1} END{print s+0}')
if [ "$NONZERO" = "2" ] && [ "$ZEROS" = "1" ]; then
  ok "H: exactly N=2 players paid, the rank-3 player wrote prize 0"
else
  nok "H: expected 2 paid + 1 zero, got nonzero=$NONZERO zeros=$ZEROS: $PRIZES"
fi
if [ "$PRIZE_SUM" = "150" ]; then
  ok "H: harmonic split still sums to the full pot (150)"
else
  nok "H: prize sum $PRIZE_SUM != pot 150: $PRIZES"
fi

# The unpaid rank-3 player (C, participant order) is the one with prize 0.
UNPAID_RANK3_PRIZE=$(echo "$results" | grep -o '"rank":3,"prize":[0-9]*' | grep -o '[0-9]*$')
if [ "$UNPAID_RANK3_PRIZE" = "0" ]; then
  ok "H: rank 3 (unpaid) carries prize 0"
else
  nok "H: rank 3 prize unexpected: $UNPAID_RANK3_PRIZE"
fi

# =========================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-020 SUMMARY: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
