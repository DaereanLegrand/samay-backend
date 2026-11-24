#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-023] Minigame per-tap reaction event (207_minigame_reaction_event)
# Verifies the reaction-sequence + reaction-event contract end-to-end:
#   A) submit_minigame_reaction (current by_turns round): each tap bumps
#      state.reactions_seq monotonically AND records state.reactions_event
#      {seq, round, reaction, voter_id} — INCLUDING a SAME-EMOJI RE-TAP whose
#      tally mirror stays byte-identical (the diff-invisible case this
#      migration exists to signal).
#   B) react_minigame_round (async reactable round): the same seq + event
#      writes, carrying the TARGET round (which may differ from the current
#      one).
#   C) a reactor Pasar ('pasar') records an event with reaction NULL (the
#      client renders no rise for a pass).
#   D) the sequence is session-global monotonic — it is NOT reset on round
#      advance (a round change is carried by the event's own `round` field).
#
# Usage: bash test/opt-023-minigame-reaction-event.sh
# Requires the stack with migration 207 applied.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  for sid in ${SESSION_ID:-} ${ASESSION_ID:-} ${ESESSION_ID:-} ${FSESSION_ID:-}; do
    [ -n "$sid" ] && svc_delete "minigame_reactions?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_answers?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_results?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_game_state?session_id=eq.$sid" > /dev/null 2>&1 || true
    [ -n "$sid" ] && svc_delete "minigame_sessions?id=eq.$sid" > /dev/null 2>&1 || true
  done
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  for uid in $UUID_A $UUID_B $UUID_C; do
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
  sed -E 's/[[:space:]]+//g'
}

# The 207 server reaction spam gate rejects a same-voter write inside 250 ms of
# the previous ACCEPTED write (status `too_fast`). These API-level cases model
# DELIBERATE spaced taps (the real client's tap timer is 350 ms), so sleep just
# past the server window between consecutive taps by the same voter.
tap_wait() { sleep 0.3; }

auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d" | norm_json
}
# Ready gate (219): the host cannot start until participants[2..] are ready.
# Marks every non-host token ready for [sid]; a non-participant's call is a
# typed rejection we ignore. init_minigame_game_state RESETS the ready map, so
# this must run before EVERY init.
mark_ready() {
  local sid=$1
  [ -n "${TOKEN_B:-}" ] && auth_rpc "$TOKEN_B" "set_minigame_ready" "{\"p_session_id\":\"$sid\",\"p_ready\":true}" > /dev/null
  [ -n "${TOKEN_C:-}" ] && auth_rpc "$TOKEN_C" "set_minigame_ready" "{\"p_session_id\":\"$sid\",\"p_ready\":true}" > /dev/null
  return 0
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

# Wait for the host-confirmed countdown to flip to playing.
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

# Pull the reaction event object (normalized, no spaces) out of a state payload.
event_of() {
  echo "$1" | grep -o '"reactions_event":{[^}]*}' | head -1
}
seq_of() {
  echo "$1" | grep -o '"reactions_seq":[0-9]*' | head -1 | cut -d: -f2
}

# --- Setup ---
h1 "SETUP: users + group + playing by_turns session"

UUID_A="44444444-4444-4444-4444-444444444444"
UUID_B="55555555-5555-5555-5555-555555555555"
UUID_C="66666666-6666-6666-6666-666666666666"
GROUP_ID="77777777-7777-7777-7777-777777777777"
EMAIL_A="user_a_opt023@samay.test"
EMAIL_B="user_b_opt023@samay.test"
EMAIL_C="user_c_opt023@samay.test"
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

for pair in "UUID_A:user_opt023_a" "UUID_B:user_opt023_b" "UUID_C:user_opt023_c"; do
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
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ]; then
  ok "Obtained auth tokens"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"ReactionEvent Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (host) + B + C (members) active"

# =========================================================================
# TEST A/B — by_turns: same-emoji re-tap bumps seq + event carries voter/emoji
# =========================================================================
h1 "TEST A — by_turns same-emoji re-tap produces a per-tap event"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\"}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "by_turns session created ($SESSION_ID)"
else
  nok "session create failed: $(echo "$resp" | head -c 160)"
fi
INVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
INVITE_C=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION_ID&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_C\"}" > /dev/null
info "B + C accepted (3 participants)"

mark_ready "$SESSION_ID"
resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then ok "init started"; else nok "init failed: $(echo "$resp" | head -c 160)"; fi
if wait_playing "$SESSION_ID" "$TOKEN_A"; then ok "countdown flipped to playing"; else nok "never flipped"; fi

# Determine subject + the two voters.
SUBJECT=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}" \
  | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
S_TOKEN=$([ "$SUBJECT" = "$UUID_A" ] && echo "$TOKEN_A" || ([ "$SUBJECT" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C"))
VOTER1=$([ "$SUBJECT" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
V1TOKEN=$([ "$VOTER1" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
VOTER2=$([ "$SUBJECT" = "$UUID_A" ] && echo "$UUID_C" || ([ "$SUBJECT" = "$UUID_B" ] && echo "$UUID_C" || echo "$UUID_B"))
V2TOKEN=$([ "$VOTER2" = "$UUID_A" ] && echo "$TOKEN_A" || ([ "$VOTER2" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C"))
info "Round subject=$SUBJECT, voters=$VOTER1/$VOTER2"

resp=$(auth_rpc "$S_TOKEN" "reveal_minigame_prompt" "{\"p_session_id\":\"$SESSION_ID\",\"p_prompt_type\":\"verdad\"}")
if echo "$resp" | grep -q '"status":"revealed"'; then ok "prompt revealed"; else nok "reveal failed: $(echo "$resp" | head -c 160)"; fi

resp=$(auth_rpc "$S_TOKEN" "submit_minigame_answer" "{\"p_session_id\":\"$SESSION_ID\",\"p_answer_ciphertext\":\"cipher_023\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then ok "subject answer submitted"; else nok "answer failed: $(echo "$resp" | head -c 160)"; fi

# VOTER1 taps heart → seq becomes 1, event carries seq/round/voter/heart.
resp=$(auth_rpc "$V1TOKEN" "submit_minigame_reaction" "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
S1=$(seq_of "$resp")
EV1=$(event_of "$resp")
if [ "$S1" = "1" ] && echo "$EV1" | grep -q "\"reaction\":\"heart\"" && echo "$EV1" | grep -q "\"voter_id\":\"$VOTER1\"" && echo "$EV1" | grep -q '"seq":1'; then
  ok "first heart tap → seq=1, event {seq:1, round:0, heart, $VOTER1}"
else
  nok "first tap event wrong: seq=$S1 event=$EV1"
fi

# VOTER1 re-taps the SAME emoji (heart again) → the tally mirror is unchanged
# but seq advances to 2 and a fresh event records the tap (this is the
# diff-invisible case the migration exists to signal).
tap_wait
resp=$(auth_rpc "$V1TOKEN" "submit_minigame_reaction" "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"heart\"}")
S2=$(seq_of "$resp")
EV2=$(event_of "$resp")
if [ "$S2" = "2" ] && echo "$EV2" | grep -q '"seq":2' && echo "$EV2" | grep -q "\"reaction\":\"heart\"" && echo "$EV2" | grep -q "\"voter_id\":\"$VOTER1\""; then
  ok "same-emoji re-tap → seq advanced 1→2 and a fresh event was recorded"
else
  nok "same-emoji re-tap NOT signalled: seq=$S2 event=$EV2"
fi

# VOTER1 changes emoji (heart → excited) → seq 3.
tap_wait
resp=$(auth_rpc "$V1TOKEN" "submit_minigame_reaction" "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"excited\"}")
S3=$(seq_of "$resp")
EV3=$(event_of "$resp")
if [ "$S3" = "3" ] && echo "$EV3" | grep -q '"seq":3' && echo "$EV3" | grep -q "\"reaction\":\"excited\""; then
  ok "emoji change tap → seq advanced 2→3 with the new emoji recorded"
else
  nok "emoji-change tap NOT signalled: seq=$S3 event=$EV3"
fi

# =========================================================================
# TEST D — seq is NOT reset on round advance (event round field disambiguates)
# =========================================================================
h1 "TEST D — seq survives round advance (session-global monotonic)"

# VOTER2's reaction is the last required → the round auto-advances. The seq is
# 4 and is NOT reset by the advance.
resp=$(auth_rpc "$V2TOKEN" "submit_minigame_reaction" "{\"p_session_id\":\"$SESSION_ID\",\"p_reaction\":\"sad\"}")
S4=$(seq_of "$resp")
if echo "$resp" | grep -q '"status":"advanced"' && [ "$S4" = "4" ]; then
  ok "round advanced with seq preserved at 4 (never reset)"
else
  nok "advance seq wrong: status=$(echo "$resp" | grep -o '"status":"[^"]*"' | head -1) seq=$S4"
fi

# =========================================================================
# TEST B — async reactable round: react_minigame_round records seq + event
# =========================================================================
h1 "TEST B — async react_minigame_round records seq + event (target round)"

# Dedicated async session so the counter starts fresh (session-scoped).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_B\"],\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"async\",\"p_async_rounds_per_player\":1,\"p_async_ends_at\":\"$(date -u -v+120S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+120 seconds' +%Y-%m-%dT%H:%M:%SZ)\"}")
ASESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$ASESSION_ID" ]; then
  ok "async session created ($ASESSION_ID)"
else
  nok "async create failed: $(echo "$resp" | head -c 160)"
fi
AINVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$ASESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$AINVITE_B\"}" > /dev/null
info "B accepted the async invite"

mark_ready "$ASESSION_ID"
resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$ASESSION_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then ok "async init started"; else nok "async init failed: $(echo "$resp" | head -c 160)"; fi
if wait_playing "$ASESSION_ID" "$TOKEN_A"; then ok "async countdown flipped"; else nok "async never flipped"; fi

# A completes async round 1 → B can react to it.
resp=$(auth_rpc "$TOKEN_A" "submit_minigame_async_answer" \
  "{\"p_session_id\":\"$ASESSION_ID\",\"p_prompt_type\":\"verdad\",\"p_answer_ciphertext\":\"async_a1\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then ok "A completed async round 1"; else nok "async answer failed: $(echo "$resp" | head -c 160)"; fi

# B reacts to A's completed round via react_minigame_round → seq 1 + event with
# the TARGET round.
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$ASESSION_ID\",\"p_round\":1,\"p_reaction\":\"heart\"}")
ASEQ=$(seq_of "$resp")
AEV=$(event_of "$resp")
if [ "$ASEQ" = "1" ] && echo "$AEV" | grep -q '"seq":1' && echo "$AEV" | grep -q '"round":1' && echo "$AEV" | grep -q "\"reaction\":\"heart\"" && echo "$AEV" | grep -q "\"voter_id\":\"$UUID_B\""; then
  ok "async react → seq=1, event {seq:1, round:1(target), heart, B}"
else
  nok "async react event wrong: seq=$ASEQ event=$AEV"
fi

# B re-taps the same heart on the async round → seq advances to 2 (same-emoji
# re-tap signalled on the async path too).
tap_wait
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$ASESSION_ID\",\"p_round\":1,\"p_reaction\":\"heart\"}")
ASEQ2=$(seq_of "$resp")
AEV2=$(event_of "$resp")
if [ "$ASEQ2" = "2" ] && echo "$AEV2" | grep -q '"seq":2'; then
  ok "async same-emoji re-tap → seq advanced 1→2"
else
  nok "async same-emoji re-tap NOT signalled: seq=$ASEQ2 event=$AEV2"
fi

# =========================================================================
# TEST C — emoji ↔ Pasar exclusivity (2026-09-04): once a voter has acted they
# cannot switch to the OTHER mode. B has emoji-reacted on this async round, so
# a Pasar is rejected (already_reacted); an emoji → emoji re-vote stays allowed.
# =========================================================================
h1 "TEST C — emoji ↔ Pasar exclusivity (cross-mode switch rejected)"

# B already emoji-reacted → Pasar is rejected.
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$ASESSION_ID\",\"p_round\":1,\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"already_reacted"'; then
  ok "emoji-reacted voter switching to Pasar rejected (already_reacted)"
else
  nok "cross-mode Pasar NOT rejected: $(echo "$resp" | head -c 160)"
fi

# Emoji → emoji re-vote remains allowed (upsert replaces) and bumps the seq.
tap_wait
resp=$(auth_rpc "$TOKEN_B" "react_minigame_round" \
  "{\"p_session_id\":\"$ASESSION_ID\",\"p_round\":1,\"p_reaction\":\"excited\"}")
XSEQ=$(seq_of "$resp")
XEV=$(event_of "$resp")
if echo "$resp" | grep -q '"status":"submitted"' && [ "$XSEQ" = "3" ] && echo "$XEV" | grep -q '"seq":3' && echo "$XEV" | grep -q '"reaction":"excited"'; then
  ok "emoji → emoji re-vote allowed (seq 3, excited recorded)"
else
  nok "emoji → emoji re-vote failed: seq=$XSEQ event=$XEV"
fi

# A is the round's subject — it can NEVER react (own_round still enforced).
resp=$(auth_rpc "$TOKEN_A" "react_minigame_round" \
  "{\"p_session_id\":\"$ASESSION_ID\",\"p_round\":1,\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"own_round"'; then
  ok "subject own-round action rejected (own_round)"
else
  nok "subject own-round NOT rejected: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST E — the per-voter voters map mirrors each voter's committed action, and
# a PASSED voter cannot switch to an emoji. Dedicated 3-participant by_turns
# session (A host + B + C): with 3 players a single pass does NOT auto-advance,
# so the mirror stays readable. The passer then tries an emoji → rejected
# (already_passed); the voters map carries emoji voters as wire values and the
# passer as null.
# =========================================================================
h1 "TEST E — voters mirror + passed voter cannot emoji-react"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":2,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\"}")
ESESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$ESESSION_ID" ]; then
  ok "E: dedicated by_turns session created ($ESESSION_ID)"
else
  nok "E: create failed: $(echo "$resp" | head -c 160)"
fi
EINVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$ESESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
EINVITE_C=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$ESESSION_ID&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$EINVITE_B\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$EINVITE_C\"}" > /dev/null
mark_ready "$ESESSION_ID"
resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$ESESSION_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then ok "E: init started"; else nok "E: init failed: $(echo "$resp" | head -c 160)"; fi
if wait_playing "$ESESSION_ID" "$TOKEN_A"; then ok "E: countdown flipped"; else nok "E: never flipped"; fi

# Resolve subject (A/B/C) → the OTHER two are the voters.
ESUBJ=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$ESESSION_ID\"}" \
  | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
EST=$([ "$ESUBJ" = "$UUID_A" ] && echo "$TOKEN_A" || ([ "$ESUBJ" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C"))
EVPASS=$([ "$ESUBJ" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
EVPASST=$([ "$EVPASS" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
EV2=$([ "$ESUBJ" = "$UUID_B" ] && echo "$UUID_C" || ([ "$ESUBJ" = "$UUID_A" ] && echo "$UUID_C" || echo "$UUID_B"))
info "E: subject=$ESUBJ, passer=$EVPASS (second voter $EV2 idle)"

resp=$(auth_rpc "$EST" "reveal_minigame_prompt" "{\"p_session_id\":\"$ESESSION_ID\",\"p_prompt_type\":\"verdad\"}")
resp=$(auth_rpc "$EST" "submit_minigame_answer" "{\"p_session_id\":\"$ESESSION_ID\",\"p_answer_ciphertext\":\"cipher_e_$ESUBJ\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then ok "E: subject answered"; else nok "E: answer failed: $(echo "$resp" | head -c 160)"; fi

# EVPASS (the passer) passes → with 3 players the round stays open.
resp=$(auth_rpc "$EVPASST" "submit_minigame_reaction" "{\"p_session_id\":\"$ESESSION_ID\",\"p_reaction\":\"pasar\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then ok "E: voter passed (round still open, 1 of 2 acted)"; else nok "E: pass failed: $(echo "$resp" | head -c 160)"; fi

# The passed voter then tries an emoji → rejected (already_passed).
resp=$(auth_rpc "$EVPASST" "submit_minigame_reaction" "{\"p_session_id\":\"$ESESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"already_passed"'; then
  ok "E: passed voter switching to an emoji rejected (already_passed)"
else
  nok "E: cross-mode emoji NOT rejected: $(echo "$resp" | head -c 160)"
fi

# The mirror's voters map: passer → null (pass marker).
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$ESESSION_ID\"}")
VOTERS=$(echo "$resp" | grep -o '"voters":{[^}]*}' | head -1)
if echo "$VOTERS" | grep -q "\"$EVPASS\":null"; then
  ok "E: voters mirror carries the passer as null ($EVPASS)"
else
  nok "E: voters mirror wrong: $VOTERS"
fi

# =========================================================================
# TEST F — controlled spam: the server drops a same-voter write inside the
# 250 ms window (`too_fast`, no write / no seq bump) while a FRESH voter's
# emoji and a spaced re-tap both succeed. Dedicated 3-participant by_turns
# session (A host + B + C) so a single voter's taps stay below the 2-voter
# advance threshold.
# =========================================================================
h1 "TEST F — controlled spam gate (too_fast inside the window)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"],\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\"}")
FSESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$FSESSION_ID" ]; then
  ok "F: dedicated by_turns session created ($FSESSION_ID)"
else
  nok "F: create failed: $(echo "$resp" | head -c 160)"
fi
FINVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$FSESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
FINVITE_C=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$FSESSION_ID&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$FINVITE_B\"}" > /dev/null
auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$FINVITE_C\"}" > /dev/null
mark_ready "$FSESSION_ID"
resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$FSESSION_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then ok "F: init started"; else nok "F: init failed: $(echo "$resp" | head -c 160)"; fi
if wait_playing "$FSESSION_ID" "$TOKEN_A"; then ok "F: countdown flipped"; else nok "F: never flipped"; fi

# Resolve subject (A/B/C) → the OTHER two are the voters.
FSUBJ=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$FSESSION_ID\"}" \
  | grep -o '"subject_id":"[^"]*"' | head -1 | cut -d'"' -f4)
FST=$([ "$FSUBJ" = "$UUID_A" ] && echo "$TOKEN_A" || ([ "$FSUBJ" = "$UUID_B" ] && echo "$TOKEN_B" || echo "$TOKEN_C"))
FV=$([ "$FSUBJ" = "$UUID_A" ] && echo "$UUID_B" || echo "$UUID_A")
FVT=$([ "$FV" = "$UUID_A" ] && echo "$TOKEN_A" || echo "$TOKEN_B")
info "F: subject=$FSUBJ, spamming voter=$FV"

resp=$(auth_rpc "$FST" "reveal_minigame_prompt" "{\"p_session_id\":\"$FSESSION_ID\",\"p_prompt_type\":\"verdad\"}")
resp=$(auth_rpc "$FST" "submit_minigame_answer" "{\"p_session_id\":\"$FSESSION_ID\",\"p_answer_ciphertext\":\"cipher_f_$FSUBJ\"}")
if echo "$resp" | grep -q '"status":"submitted"'; then ok "F: subject answered"; else nok "F: answer failed: $(echo "$resp" | head -c 160)"; fi

# Fresh voter: the first emoji tap is ACCEPTED (the corrected exclusivity — a
# no-row voter is not "already passed").
resp=$(auth_rpc "$FVT" "submit_minigame_reaction" "{\"p_session_id\":\"$FSESSION_ID\",\"p_reaction\":\"heart\"}")
FSEQ=$(seq_of "$resp")
if echo "$resp" | grep -q '"status":"submitted"' && [ "$FSEQ" = "1" ]; then
  ok "F: fresh voter emoji accepted (seq=1)"
else
  nok "F: fresh voter emoji rejected: $(echo "$resp" | head -c 160)"
fi

# Immediately re-tap the SAME emoji: inside the 250 ms window → too_fast, with
# NO write (mirror + seq untouched).
resp=$(auth_rpc "$FVT" "submit_minigame_reaction" "{\"p_session_id\":\"$FSESSION_ID\",\"p_reaction\":\"heart\"}")
if echo "$resp" | grep -q '"status":"too_fast"'; then
  ok "F: same-voter re-tap inside the window dropped (too_fast)"
else
  nok "F: spam gate did not fire: $(echo "$resp" | head -c 160)"
fi

# After the window a same-emoji re-tap is accepted again (controlled spam).
tap_wait
resp=$(auth_rpc "$FVT" "submit_minigame_reaction" "{\"p_session_id\":\"$FSESSION_ID\",\"p_reaction\":\"heart\"}")
FSEQ2=$(seq_of "$resp")
if echo "$resp" | grep -q '"status":"submitted"' && [ "$FSEQ2" = "2" ]; then
  ok "F: spaced same-emoji re-tap accepted (seq=2)"
else
  nok "F: spaced re-tap failed: seq=$FSEQ2 $(echo "$resp" | head -c 160)"
fi

# The mirror still holds exactly ONE reaction for the round (the upsert keeps
# one row per voter — spam never inflates the tally or the advance count).
TLIST=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$FSESSION_ID\"}" \
  | grep -o '"list":\[[^]]*\]' | head -1)
FHEARTS=$(echo "$TLIST" | grep -o '"heart"' | wc -l | tr -d ' ')
if [ "$FHEARTS" = "1" ]; then
  ok "F: tally holds exactly one heart after spam (one row per voter)"
else
  nok "F: tally inflated by spam: $TLIST"
fi

# =========================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-023 SUMMARY: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
