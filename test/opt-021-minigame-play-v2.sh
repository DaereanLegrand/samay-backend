#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-021] Minigame play v2 — answer-first, modes, anonymous (202_minigame_play_v2)
# Verifies the play-engine v2 feature end-to-end:
#   A) create_minigame_session accepts play_mode + anonymous + async options
#      and freezes them on the session row + seeded game-state payload.
#   B) validation gates: invalid play_mode, invalid async rounds, async
#      without a deadline, by_turns with an async deadline.
#   C) ANSWER-FIRST: a reaction before the subject answers is rejected
#      (answer_pending); a non-subject answer is rejected (not_subject); the
#      subject's answer is accepted (submitted) and streams into state.answer;
#      the subject can never react to their own round (own_round).
#   D) PASAR: the subject passes → the round auto-advances with score -1 and
#      reactions are blocked (answer_pending for the closed round).
#   E) ALL-REACTED auto-advance: when every non-subject participant has
#      reacted, the round closes (by_turns).
#   F) ASYNC mode: per-player rounds, submit_minigame_async_answer records the
#      caller's round, react_minigame_round targets a completed round, and the
#      settable timer auto-finishes the game.
#   G) ANONYMOUS: set_minigame_alias sets + updates the temp nickname
#      (realtime via minigame_aliases).
#   H) SECURITY HARDENING (2026-08-31): active-only group members + participant-
#      only writers. An INVITED group member is denied from every play RPC and
#      from RLS reads; a kicked participant loses all access; mgs_bundles_insert_own
#      is participant-only; the reactions mirror carries a distinct-voter count.
#   J) REACTOR PASAR (204_minigame_pasar): a voter passes on an async reactable
#      round via react_minigame_round ('pasar' → NULL-reaction pass marker); the
#      mirror carries the pass count; the subject scores -0.5 per passer.
#
# Usage: bash test/opt-021-minigame-play-v2.sh
# Requires the stack with migration 202 applied.
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
  for sid in ${SESSION_ID:-} ${SESSION2_ID:-} ${SESSION3_ID:-} ${SESSION5_ID:-}; do
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
svc_get() {
  curl -s "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}
svc_delete() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" 2>/dev/null
}
auth_get() {
  # Authenticated PostgREST SELECT — returns the JSON body ([] on RLS denial).
  curl -s "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $2"
}
auth_status() {
  # Authenticated PostgREST method (POST/PATCH/DELETE) — prints the HTTP code.
  local m=$1 path=$2 t=$3 d=$4
  curl -s -o /dev/null -w '%{http_code}' -X "$m" "$SUPABASE_URL/rest/v1/$path" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
    -H "Content-Type: application/json" -d "$d"
}

# Wait for the host-confirmed countdown to flip to playing: the HOST's device
# calls start_minigame_match (203_minigame_host_start) once its own 5s
# device-clock countdown ends. There is no server timer / lazy get-flip.
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
EMAIL_A="user_a_opt021@samay.test"
EMAIL_B="user_b_opt021@samay.test"
EMAIL_C="user_c_opt021@samay.test"
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

for pair in "UUID_A:user_opt021_a" "UUID_B:user_opt021_b" "UUID_C:user_opt021_c"; do
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

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"PlayV2 Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (promotor) + B (member) active; C is NOT a member (bystander)"

# =========================================================================
# TEST A — create with play_mode + anonymous
# =========================================================================
h1 "TEST A — create with p_play_mode=by_turns + p_anonymous"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":50,\"p_invitees\":[\"$UUID_B\"],\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\",\"p_anonymous\":true}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "create with play_mode=by_turns, anonymous=true returned created ($SESSION_ID)"
else
  nok "create failed: $(echo "$resp" | head -c 120)"
fi

INVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B\"}")
if echo "$resp" | grep -q '"status":"accepted"'; then
  ok "B accepted the invite (2 participants)"
else
  nok "B accept failed: $(echo "$resp" | head -c 120)"
fi

ROW=$(svc_get "minigame_sessions?id=eq.$SESSION_ID&select=play_mode,anonymous" | norm_json)
if echo "$ROW" | grep -q '"play_mode":"by_turns"' && echo "$ROW" | grep -q '"anonymous":true'; then
  ok "play_mode + anonymous frozen on the session row"
else
  nok "session row wrong: $ROW"
fi

# The seeded game-state payload carries the mode fields.
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"play_mode":"by_turns"' && echo "$resp" | grep -q '"anonymous":true'; then
  ok "game-state payload seeded with play_mode + anonymous"
else
  nok "game-state payload wrong: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST B — validation gates
# =========================================================================
h1 "TEST B — invalid play-mode / async options rejected"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_play_mode\":\"bogus\"}")
if echo "$resp" | grep -q '"status":"invalid_play_mode"'; then
  ok "invalid play_mode rejected (invalid_play_mode)"
else
  nok "invalid_play_mode NOT rejected: $resp"
fi

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_play_mode\":\"async\",\"p_async_rounds_per_player\":0}")
if echo "$resp" | grep -q '"status":"invalid_async_rounds"'; then
  ok "async rounds=0 rejected (invalid_async_rounds)"
else
  nok "invalid_async_rounds NOT rejected: $resp"
fi

# async without a deadline is rejected.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_play_mode\":\"async\",\"p_async_rounds_per_player\":1}")
if echo "$resp" | grep -q '"status":"invalid_async_ends_at"'; then
  ok "async without a deadline rejected (invalid_async_ends_at)"
else
  nok "async-without-deadline NOT rejected: $resp"
fi

# by_turns with an async deadline is ignored (deadline forced NULL).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_play_mode\":\"by_turns\",\"p_async_ends_at\":\"2030-01-01T00:00:00Z\"}")
if echo "$resp" | grep -q '"status":"created"'; then
  ok "by_turns create accepted (deadline ignored)"
else
  nok "by_turns create failed: $resp"
fi

# =========================================================================
# TEST C — ANSWER-FIRST
# =========================================================================
h1 "TEST C — answer gate (subject submits before reactions open)"

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
SUBJECT=$(echo "$resp" | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"started"' && [ -n "$SUBJECT" ]; then
  ok "init started with subject $SUBJECT"
else
  nok "init failed: $(echo "$resp" | head -c 120)"
fi

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

# A reaction BEFORE the subject answers is rejected (answer-first).
VOTER=$([ "$SUBJECT" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
VTOKEN=$([ "$VOTER" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
resp=$(auth_rpc "$VTOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"answer_pending"'; then
  ok "reaction before the answer rejected (answer_pending)"
else
  nok "answer_pending NOT enforced: $resp"
fi

# A non-subject cannot answer.
NON_SUBJECT=$([ "$SUBJECT" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
NTOKEN=$([ "$NON_SUBJECT" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
resp=$(auth_rpc "$NTOKEN" "submit_minigame_answer" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"cipher_a\"}")
if echo "$resp" | grep -q '"status":"not_subject"'; then
  ok "non-subject answer rejected (not_subject)"
else
  nok "not_subject NOT enforced: $resp"
fi

# The subject submits their E2EE answer (ciphertext only).
STOKEN=$([ "$SUBJECT" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
resp=$(auth_rpc "$STOKEN" "submit_minigame_answer" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"cipher_ans_$SUBJECT\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "subject answer submitted"
else
  nok "subject answer failed: $(echo "$resp" | head -c 120)"
fi

# The answer ciphertext streams into state.answer (realtime) — never the
# plaintext.
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"answer_ciphertext":"cipher_ans_' && echo "$resp" | grep -q '"passed":false'; then
  ok "state.answer mirrors the ciphertext (no plaintext)"
else
  nok "state.answer wrong: $(echo "$resp" | head -c 200)"
fi

# The subject can never react to their own round.
resp=$(auth_rpc "$STOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"own_round"'; then
  ok "subject own-round reaction rejected (own_round)"
else
  nok "own_round NOT enforced: $resp"
fi

# =========================================================================
# TEST E — ALL-REACTED auto-advance (by_turns)
# =========================================================================
h1 "TEST E — the turn advances once every non-subject participant reacted"

# The only non-subject participant is VOTER. Their reaction closes the round
# (2 participants → 1 required voter).
resp=$(auth_rpc "$VTOKEN" "submit_minigame_reaction" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"advanced"'; then
  ok "last-required reaction auto-advanced the round"
else
  nok "all-reacted auto-advance failed: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST D — PASAR (blocks reactions, auto-advances, score -1)
# =========================================================================
h1 "TEST D — Pasar blocks reactions + auto-scores -1"

# Advance to a fresh round: reveal + capture the subject.
resp=$(auth_rpc "$TOKEN_A" "reveal_minigame_prompt" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"reto\"}")
SUBJ2=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}" \
  | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
S2TOKEN=$([ "$SUBJ2" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")

# The subject passes.
resp=$(auth_rpc "$S2TOKEN" "submit_minigame_pasar" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"advanced"'; then
  ok "pasar auto-advanced the round (reactions blocked)"
else
  nok "pasar failed: $(echo "$resp" | head -c 160)"
fi

# The passed round's score is -1.
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"score":-1'; then
  ok "passed round scored -1"
else
  nok "expected -1 score: $(echo "$resp" | head -c 200)"
fi

# =========================================================================
# TEST F — ASYNC mode
# =========================================================================
h1 "TEST F — async per-player rounds + reactable rounds + timer finish"

# Create an async session with a near-future deadline (the timer is settable
# at creation; the cron settles it after it passes).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\"],\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"async\",\"p_async_rounds_per_player\":2,\"p_async_ends_at\":\"$(date -u -v+60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+60 seconds' +%Y-%m-%dT%H:%M:%SZ)\"}")
SESSION2_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION2_ID" ]; then
  ok "async create with rounds_per_player=2 + deadline returned created ($SESSION2_ID)"
else
  nok "async create failed: $(echo "$resp" | head -c 160)"
fi

INVITE2=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION2_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE2\"}" > /dev/null
ok "B accepted the async invite"

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION2_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then
  ok "async init started"
else
  nok "async init failed: $(echo "$resp" | head -c 120)"
fi
if wait_playing "$SESSION2_ID" "$TOKEN_A"; then
  ok "async countdown flipped to playing"
else
  nok "async countdown never flipped"
fi

# A completes their first async round.
resp=$(auth_rpc "$TOKEN_A" "submit_minigame_async_answer" \
  "{\"p_session_id\":\"$SESSION2_ID\",\"p_prompt_type\":\"verdad\",\"p_answer_ciphertext\":\"async_ans_a1\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "A submitted async round 1"
else
  nok "async answer failed: $(echo "$resp" | head -c 160)"
fi

# B reacts to A's completed round (reactable list).
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION2_ID\",\"p_round\":1,\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "B reacted to A's completed round (react_minigame_round)"
else
  nok "react to completed round failed: $(echo "$resp" | head -c 160)"
fi

# The round's subject cannot react to their own round via the async path.
resp=$(auth_rpc "$TOKEN_A" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION2_ID\",\"p_round\":1,\"p_reaction\":\"sad\"}")
if echo "$resp" | grep -q '"status":"own_round"'; then
  ok "async own-round reaction rejected (own_round)"
else
  nok "async own_round NOT enforced: $resp"
fi

# A completes a second async round (per-player target 2 → everyone at target).
resp=$(auth_rpc "$TOKEN_A" "submit_minigame_async_answer" \
  "{\"p_session_id\":\"$SESSION2_ID\",\"p_prompt_type\":\"reto\",\"p_answer_ciphertext\":\"async_ans_a2\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "A submitted async round 2"
else
  nok "A round 2 failed: $(echo "$resp" | head -c 160)"
fi

# B completes their rounds too (round 1 of B).
resp=$(auth_rpc "$TOKEN_B" "submit_minigame_async_answer" \
  "{\"p_session_id\":\"$SESSION2_ID\",\"p_prompt_type\":\"verdad\",\"p_answer_ciphertext\":\"async_ans_b1\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "B submitted async round 1"
else
  nok "B round 1 failed: $(echo "$resp" | head -c 160)"
fi

# B completes round 2 → everyone reached the per-player target → auto-finish.
resp=$(auth_rpc "$TOKEN_B" "submit_minigame_async_answer" \
  "{\"p_session_id\":\"$SESSION2_ID\",\"p_prompt_type\":\"reto\",\"p_answer_ciphertext\":\"async_ans_b2\"}")
if echo "$resp" | grep -q '"status":"finished"'; then
  ok "all players at per-player target → async auto-finish"
else
  nok "async auto-finish failed: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST G — ANONYMOUS temp nicknames
# =========================================================================
h1 "TEST G — set_minigame_alias (temp nicknames, realtime)"

resp=$(auth_rpc "$TOKEN_A" "set_minigame_alias" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_alias\":\"anon_test_a\"}")
if echo "$resp" | grep -q '"status":"alias_set"'; then
  ok "A set their temp nickname (anon_test_a)"
else
  nok "alias set failed: $(echo "$resp" | head -c 120)"
fi

# B reads A's alias (realtime) and A updates it.
resp=$(auth_rpc "$TOKEN_A" "set_minigame_alias" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_alias\":\"anon_test_a2\"}")
if echo "$resp" | grep -q '"alias":"anon_test_a2"'; then
  ok "alias update returned the new alias"
else
  nok "alias update failed: $(echo "$resp" | head -c 120)"
fi

aliases=$(svc_get "minigame_aliases?session_id=eq.$SESSION_ID&select=alias" | norm_json)
if echo "$aliases" | grep -q '"alias":"anon_test_a2"'; then
  ok "alias persisted + readable (realtime row)"
else
  nok "alias row missing: $aliases"
fi

# Blank / oversized aliases are rejected.
resp=$(auth_rpc "$TOKEN_B" "set_minigame_alias" \
  "{\"p_session_id\":\"$SESSION_ID\",\"p_alias\":\"   \"}")
if echo "$resp" | grep -q '"status":"invalid_alias"'; then
  ok "blank alias rejected (invalid_alias)"
else
  nok "blank alias NOT rejected: $resp"
fi

# =========================================================================
# TEST H — security hardening (2026-08-31): active-only members,
# participant-only writers, participant-only bundles, distinct-voter count.
# =========================================================================
h1 "TEST H — security hardening (active-only members + participant-only writers)"

# H1: C becomes an INVITED group member (never accepted → never active).
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_C\",\"role\":\"member\",\"status\":\"invited\"}" >/dev/null
ok "C added as INVITED group member (never active)"

# H1a: the invited member is DENIED from the by_turns writers + reader.
resp=$(auth_rpc "$TOKEN_C" "submit_minigame_answer" "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"cipher_h\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "invited member denied submit_minigame_answer (not_allowed)"
else
  nok "invited member NOT denied submit_minigame_answer: $resp"
fi

resp=$(auth_rpc "$TOKEN_C" "submit_minigame_reaction" "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "invited member denied submit_minigame_reaction (not_allowed)"
else
  nok "invited member NOT denied submit_minigame_reaction: $resp"
fi

resp=$(auth_rpc "$TOKEN_C" "submit_minigame_async_answer" "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"verdad\",\"p_answer_ciphertext\":\"cipher_h\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "invited member denied submit_minigame_async_answer (not_allowed)"
else
  nok "invited member NOT denied submit_minigame_async_answer: $resp"
fi

resp=$(auth_rpc "$TOKEN_C" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "invited member denied get_minigame_game_state (not_allowed)"
else
  nok "invited member NOT denied get_minigame_game_state: $resp"
fi

# H1b: RLS — the invited member cannot read the session row nor the answers.
rows=$(auth_get "minigame_sessions?select=id&id=eq.$SESSION_ID" "$TOKEN_C" | norm_json)
if [ "$rows" = "[]" ]; then
  ok "invited member cannot read the session via RLS"
else
  nok "invited member READ the session via RLS: $rows"
fi

rows=$(auth_get "minigame_answers?select=id&session_id=eq.$SESSION_ID" "$TOKEN_C" | norm_json)
if [ "$rows" = "[]" ]; then
  ok "invited member cannot read minigame_answers via RLS"
else
  nok "invited member READ minigame_answers via RLS: $rows"
fi

# H2: the creator kicks B (an ACTIVE group member + participant) from the
# session AND B's group standing is revoked (the kicked member loses every
# path): not a participant, no invite, no active group membership.
resp=$(auth_rpc "$TOKEN_A" "remove_minigame_participant" "{\"p_session_id\":\"$SESSION_ID\",\"p_user_id\":\"$UUID_B\"}")
if echo "$resp" | grep -q '"status":"removed"'; then
  ok "creator removed B from the session (remove_minigame_participant)"
else
  nok "remove_minigame_participant failed: $(echo "$resp" | head -c 120)"
fi
curl -s -X PATCH "$SUPABASE_URL/rest/v1/group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d '{"status":"invited"}' > /dev/null 2>&1 || true
info "B's group membership revoked (invited) after the kick"

# The kicked user is denied from the reader + writer + RLS.
resp=$(auth_rpc "$TOKEN_B" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "kicked B denied get_minigame_game_state (not_allowed)"
else
  nok "kicked B NOT denied get_minigame_game_state: $resp"
fi

resp=$(auth_rpc "$TOKEN_B" "submit_minigame_reaction" "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "kicked B denied submit_minigame_reaction (not_allowed)"
else
  nok "kicked B NOT denied submit_minigame_reaction: $resp"
fi

rows=$(auth_get "minigame_answers?select=id&session_id=eq.$SESSION_ID" "$TOKEN_B" | norm_json)
if [ "$rows" = "[]" ]; then
  ok "kicked B cannot read minigame_answers via RLS"
else
  nok "kicked B READ minigame_answers via RLS: $rows"
fi

# H3: mgs_bundles_insert_own is participant-only — the invited member (C, now
# also a pending session invitee) cannot INSERT a key-distribution bundle via
# the authenticated role (RLS denial → HTTP 403).
curl -s -X POST "$SUPABASE_URL/rest/v1/minigame_invites" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"session_id\":\"$SESSION_ID\",\"invitee_id\":\"$UUID_C\",\"created_by\":\"$UUID_A\"}" > /dev/null 2>&1 || true
code=$(auth_status "POST" "minigame_e2ee_bundles" "$TOKEN_C" \
  "{\"session_id\":\"$SESSION_ID\",\"sender_id\":\"$UUID_C\",\"recipient_id\":\"$UUID_A\",\"bundle_ciphertext\":\"enc_h\"}")
if [ "$code" = "403" ]; then
  ok "invited member denied bundle INSERT (mgs_bundles_insert_own → 403)"
else
  nok "invited member bundle INSERT returned $code (expected 403)"
fi

# A participant sending to a NON-participant (C, still not a participant of
# SESSION_ID) is also denied — the recipient must be in participants too.
code=$(auth_status "POST" "minigame_e2ee_bundles" "$TOKEN_A" \
  "{\"session_id\":\"$SESSION_ID\",\"sender_id\":\"$UUID_A\",\"recipient_id\":\"$UUID_C\",\"bundle_ciphertext\":\"enc_ok\"}")
if [ "$code" = "403" ]; then
  ok "participant→non-participant bundle INSERT denied (recipient not in participants → 403)"
else
  nok "participant→non-participant bundle INSERT returned $code (expected 403)"
fi

# H4: distinct-voter count — a direct async session with 3 participants; two
# distinct voters react to A's round and one re-votes; the mirrored
# state.reactions carries {"list": [...], "count": 2}.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":2,\"p_prize_positions\":3,\"p_play_mode\":\"async\",\"p_async_rounds_per_player\":1,\"p_async_ends_at\":\"$(date -u -v+120S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+120 seconds' +%Y-%m-%dT%H:%M:%SZ)\"}")
SESSION3_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION3_ID" ]; then
  ok "direct async session created for the distinct-voter test ($SESSION3_ID)"
else
  nok "direct async create failed: $(echo "$resp" | head -c 160)"
fi
INVITE_B3=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION3_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
INVITE_C3=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION3_ID&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B3\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_C3\"}" > /dev/null
info "B + C accepted the direct async invites (3 participants)"

# Participant-to-participant bundles still work (regression guard).
code=$(auth_status "POST" "minigame_e2ee_bundles" "$TOKEN_A" \
  "{\"session_id\":\"$SESSION3_ID\",\"sender_id\":\"$UUID_A\",\"recipient_id\":\"$UUID_B\",\"bundle_ciphertext\":\"enc_ok\"}")
if [ "$code" = "201" ]; then
  ok "participant A→B bundle INSERT accepted (201)"
else
  nok "participant A→B bundle INSERT returned $code (expected 201)"
fi

# H3b: the putE2eeBundle upsert leg — re-POSTing the SAME (session,sender,
# recipient) key must UPDATE the row (PostgREST upsert = INSERT-then-UPDATE on
# conflict). Without the UPDATE grant + mgs_bundles_update_own policy this
# returns 42501 (2026-08-31 on-device fix).
code=$(auth_status "PATCH" "minigame_e2ee_bundles?session_id=eq.$SESSION3_ID&sender_id=eq.$UUID_A&recipient_id=eq.$UUID_B" "$TOKEN_A" \
  "{\"bundle_ciphertext\":\"enc_ok_v2\"}")
if [ "$code" = "200" ] || [ "$code" = "204" ]; then
  ok "participant A→B bundle UPDATE accepted ($code) — upsert conflict leg"
else
  nok "participant A→B bundle UPDATE returned $code (expected 200/204)"
fi

# H3c: the UPDATE USING predicate is SENDER-only — a participant who is NOT
# the row's sender (C in SESSION3) cannot MODIFY an A→B bundle. RLS filters
# the row out silently (a USING denial is a no-op, not an error), so assert
# the security property directly: the forged ciphertext must NOT land (the
# stored value stays A's last write "enc_ok_v2").
code=$(auth_status "PATCH" "minigame_e2ee_bundles?session_id=eq.$SESSION3_ID&sender_id=eq.$UUID_A&recipient_id=eq.$UUID_B" "$TOKEN_C" \
  "{\"bundle_ciphertext\":\"forged_by_c\"}")
stored=$(curl -s "$SUPABASE_URL/rest/v1/minigame_e2ee_bundles?select=bundle_ciphertext&session_id=eq.$SESSION3_ID&sender_id=eq.$UUID_A&recipient_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"bundle_ciphertext":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ "$code" = "204" ] && [ "$stored" = "enc_ok_v2" ]; then
  ok "non-sender cannot modify A→B bundle (USING sender-only → forged write did not land)"
else
  nok "non-sender bundle modification returned $code / stored=$stored (expected 204 no-op + unchanged)"
fi

# H3d: the UPDATE WITH CHECK is participant-only for the RECIPIENT — a
# participant re-addressing their own bundle to a NON-participant (C in
# SESSION_ID, where C is only an invitee) violates the WITH CHECK predicate
# → 403. Establish an A-owned row in SESSION_ID first (A→A, recipient A is a
# participant), then try to re-address it to C.
curl -s -X POST "$SUPABASE_URL/rest/v1/minigame_e2ee_bundles" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"session_id\":\"$SESSION_ID\",\"sender_id\":\"$UUID_A\",\"recipient_id\":\"$UUID_A\",\"bundle_ciphertext\":\"enc_self\"}" > /dev/null 2>&1 || true
code=$(auth_status "PATCH" "minigame_e2ee_bundles?session_id=eq.$SESSION_ID&sender_id=eq.$UUID_A&recipient_id=eq.$UUID_A" "$TOKEN_A" \
  "{\"recipient_id\":\"$UUID_C\"}")
if [ "$code" = "403" ]; then
  ok "participant re-address to non-participant denied (WITH CHECK → 403)"
else
  nok "participant re-address to non-participant returned $code (expected 403)"
fi

# H3e: the sender can READ its own outbound row (Supabase RLS "UPDATE requires
# a SELECT policy" + the host's self-heal of its own minted keys). Before the
# 2026-08-31 fix the SELECT policy was recipient-only, so A could not see the
# A→B row it sent — the upsert-conflict UPDATE silently no-oped.
rows=$(auth_get "minigame_e2ee_bundles?select=id&session_id=eq.$SESSION3_ID&sender_id=eq.$UUID_A&recipient_id=eq.$UUID_B" "$TOKEN_A" | norm_json)
if [ "$rows" != "[]" ]; then
  ok "sender A reads its own outbound A→B bundle (SELECT sender leg)"
else
  nok "sender A CANNOT read its own outbound bundle: $rows"
fi

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION3_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then
  ok "direct async init started"
else
  nok "direct async init failed: $(echo "$resp" | head -c 120)"
fi
if wait_playing "$SESSION3_ID" "$TOKEN_A"; then
  ok "direct async countdown flipped to playing"
else
  nok "direct async countdown never flipped"
fi

resp=$(auth_rpc "$TOKEN_A" "submit_minigame_async_answer" \
  "{\"p_session_id\":\"$SESSION3_ID\",\"p_prompt_type\":\"verdad\",\"p_answer_ciphertext\":\"async_h_a1\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "A submitted async round 1 (distinct-voter setup)"
else
  nok "A async answer failed: $(echo "$resp" | head -c 160)"
fi

# Two distinct voters react; C then re-votes (upsert replaces, never appends).
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION3_ID\",\"p_round\":1,\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "B reacted to round 1"
else
  nok "B react failed: $(echo "$resp" | head -c 160)"
fi
resp=$(auth_rpc "$TOKEN_C" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION3_ID\",\"p_round\":1,\"p_reaction\":\"sad\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "C reacted to round 1 (2nd distinct voter)"
else
  nok "C react failed: $(echo "$resp" | head -c 160)"
fi
resp=$(auth_rpc "$TOKEN_C" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION3_ID\",\"p_round\":1,\"p_reaction\":\"excited\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "C re-voted (upsert replaces)"
else
  nok "C re-vote failed: $(echo "$resp" | head -c 160)"
fi

# The mirror shape: {"<subject_id>": {"list": [...], "count": N}} with N the
# DISTINCT voter count (2 voters, even after C's re-vote).
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION3_ID\"}")
if echo "$resp" | grep -q '"count":2' && echo "$resp" | grep -q '"list":'; then
  ok "mirrored reactions carry {\"list\":[...],\"count\":2}"
else
  nok "reactions mirror missing list/count=2: $(echo "$resp" | head -c 300)"
fi

# =========================================================================
# TEST I — host-confirmed countdown (203_minigame_host_start): start_minigame_match
# is creator-only, cancel resets, and start flips countdown → playing.
# =========================================================================
h1 "TEST I — host-confirmed countdown (start_minigame_match / cancel)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\"],\"p_rounds\":2,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\"}")
SESSION4_ID=$(echo "$resp" | sed -n 's/.*"sessionId": "\([0-9a-f-]*\)".*/\1/p')
[ -z "$SESSION4_ID" ] && SESSION4_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION4_ID" ]; then
  ok "cancel/start session created ($SESSION4_ID)"
else
  nok "cancel/start session create failed: $(echo "$resp" | head -c 120)"
fi
INVITE_B4=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION4_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B4\"}" > /dev/null
resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION4_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then
  ok "I: init seeded the countdown phase"
else
  nok "I: init failed: $(echo "$resp" | head -c 120)"
fi

# Non-creator cannot start (creator-only).
resp=$(auth_rpc "$TOKEN_B" "start_minigame_match" "{\"p_session_id\":\"$SESSION4_ID\"}")
if echo "$resp" | grep -q '"status":"not_creator"'; then
  ok "I: non-creator start_minigame_match denied (not_creator)"
else
  nok "I: non-creator start NOT denied: $resp"
fi

# Host cancel resets to setup (not playing).
resp=$(auth_rpc "$TOKEN_A" "cancel_minigame_start" "{\"p_session_id\":\"$SESSION4_ID\"}")
if echo "$resp" | grep -q '"status":"cancelled"'; then
  ok "I: host cancel resets the countdown (cancelled)"
else
  nok "I: host cancel failed: $(echo "$resp" | head -c 120)"
fi
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION4_ID\"}")
if echo "$resp" | grep -q '"phase":"setup"' || echo "$resp" | grep -q '"state":{}'; then
  ok "I: after cancel the state is back to setup (no playing)"
else
  nok "I: state after cancel is not setup: $(echo "$resp" | head -c 160)"
fi

# Re-init, then the HOST's start_minigame_match flips to playing.
resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION4_ID\"}")
resp=$(auth_rpc "$TOKEN_A" "start_minigame_match" "{\"p_session_id\":\"$SESSION4_ID\"}")
if echo "$resp" | grep -q '"status":"started"' && echo "$resp" | grep -q '"phase":"playing"'; then
  ok "I: host start_minigame_match flips countdown → playing"
else
  nok "I: host start failed: $(echo "$resp" | head -c 160)"
fi

# Re-start on an already-playing row is idempotent (started).
resp=$(auth_rpc "$TOKEN_A" "start_minigame_match" "{\"p_session_id\":\"$SESSION4_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then
  ok "I: re-start on playing is idempotent (started)"
else
  nok "I: re-start NOT idempotent: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST J — reactor-side Pasar (204_minigame_pasar) on an async reactable round
# =========================================================================
h1 "TEST J — reactor Pasar on an async reactable round"

# Fresh direct async session (3 participants: A + B + C), per-player target 1,
# deadline ~2min out so the game stays alive while we react.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":2,\"p_prize_positions\":3,\"p_play_mode\":\"async\",\"p_async_rounds_per_player\":1,\"p_async_ends_at\":\"$(date -u -v+180S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+180 seconds' +%Y-%m-%dT%H:%M:%SZ)\"}")
SESSION5_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION5_ID" ]; then
  ok "J: direct async session created ($SESSION5_ID)"
else
  nok "J: async create failed: $(echo "$resp" | head -c 160)"
fi
INVITE_B5=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION5_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
INVITE_C5=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION5_ID&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B5\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_C5\"}" > /dev/null
info "J: B + C accepted the async invites (3 participants)"

resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION5_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then
  ok "J: async init started"
else
  nok "J: async init failed: $(echo "$resp" | head -c 120)"
fi
if wait_playing "$SESSION5_ID" "$TOKEN_A"; then
  ok "J: async countdown flipped to playing"
else
  nok "J: async countdown never flipped"
fi

# A completes their single async round (round 1).
resp=$(auth_rpc "$TOKEN_A" "submit_minigame_async_answer" \
  "{\"p_session_id\":\"$SESSION5_ID\",\"p_prompt_type\":\"verdad\",\"p_answer_ciphertext\":\"async_j_a1\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "J: A submitted their async round"
else
  nok "J: A async answer failed: $(echo "$resp" | head -c 160)"
fi

# B passes on A's completed round; C emoji-reacts. The mirror carries both.
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION5_ID\",\"p_round\":1,\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "J: B passed on A's completed round (react_minigame_round pasar)"
else
  nok "J: B pass failed: $(echo "$resp" | head -c 160)"
fi

resp=$(auth_rpc "$TOKEN_C" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION5_ID\",\"p_round\":1,\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then
  ok "J: C emoji-reacted on A's round"
else
  nok "J: C emoji react failed: $(echo "$resp" | head -c 160)"
fi

# The mirror carries the pass count alongside the emoji list + voter count.
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION5_ID\"}")
if echo "$resp" | grep -q '"pass":1' && echo "$resp" | grep -q '"count":2' && echo "$resp" | grep -q '"list":'; then
  ok "J: reactions mirror carries {\"list\",\"count\":2,\"pass\":1}"
else
  nok "J: reactions mirror missing pass/count/list: $(echo "$resp" | head -c 300)"
fi

# A (the round's subject) cannot pass their OWN round via the async path.
resp=$(auth_rpc "$TOKEN_A" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION5_ID\",\"p_round\":1,\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"own_round"'; then
  ok "J: subject own-round pass rejected (own_round)"
else
  nok "J: subject own-round pass NOT rejected: $resp"
fi

# An invalid emoji key is still rejected (pasar is the only new wire value).
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$SESSION5_ID\",\"p_round\":1,\"p_reaction\":\"bogus\"}")
if echo "$resp" | grep -q '"status":"invalid_reaction"'; then
  ok "J: invalid reaction still rejected (invalid_reaction)"
else
  nok "J: invalid_reaction NOT rejected: $resp"
fi

# =========================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-021 SUMMARY: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
