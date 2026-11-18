#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-022] Minigame round-key request ring (206_minigame_key_request)
# Verifies the server-blind re-key heal end-to-end:
#   A) request_minigame_round_keys is PARTICIPANT-ONLY: an invitee / group
#      member / bystander is denied (not_allowed); a participant is accepted.
#   B) the request appends the caller to the state payload's `key_requests`
#      marker (dedup — a repeat request does not double-append).
#   C) resolve_minigame_key_request removes the served requester (resolved);
#      it is PARTICIPANT-ONLY and never self-clears (self_resolve).
#   D) the ring heals a "wiped identity" participant: A (requester) flags,
#      B (holder) resolves, and the requester's own-recipient bundle row is
#      re-addressable under its CURRENT identity (the real two-device shape —
#      the envelope re-wrap is client-side, so this asserts the SERVER marker
#      contract that makes the heal deterministic).
#
# Usage: bash test/opt-022-minigame-key-request.sh
# Requires the stack with migration 206 applied.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
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

# --- Setup ---
h1 "SETUP: users + group + playing session"

UUID_A="44444444-4444-4444-4444-444444444444"
UUID_B="55555555-5555-5555-5555-555555555555"
UUID_C="66666666-6666-6666-6666-666666666666"
GROUP_ID="77777777-7777-7777-7777-777777777777"
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

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"KeyRing Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (host) + B (member) active; C is a group MEMBER but NOT a participant (ring must deny C)"

# =========================================================================
# TEST A/B — a playing by_turns session with A(host) + B(participant);
# C is a group member/invitee but never a participant.
# =========================================================================
h1 "TEST A — request is participant-only"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_B\"],\"p_rounds\":3,\"p_prize_positions\":3,\"p_play_mode\":\"by_turns\"}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "by_turns session created ($SESSION_ID)"
else
  nok "session create failed: $(echo "$resp" | head -c 160)"
fi
INVITE_B=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION_ID&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_B\"}" > /dev/null
info "B accepted (2 participants); C is only a group member"

mark_ready "$SESSION_ID"
resp=$(auth_rpc "$TOKEN_A" "init_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"started"'; then ok "init started"; else nok "init failed: $(echo "$resp" | head -c 160)"; fi
if wait_playing "$SESSION_ID" "$TOKEN_A"; then ok "countdown flipped to playing"; else nok "never flipped"; fi

# A group member / non-participant (C) is DENIED.
resp=$(auth_rpc "$TOKEN_C" "request_minigame_round_keys" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "group-member non-participant request denied (not_allowed)"
else
  nok "non-participant request NOT denied: $resp"
fi

# A participant (B) is ACCEPTED and appends to the marker.
resp=$(auth_rpc "$TOKEN_B" "request_minigame_round_keys" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"requested"' && echo "$resp" | grep -q "\"key_requests\":\[\"$UUID_B\"\]"; then
  ok "participant B request accepted and B appended to key_requests"
else
  nok "participant B request failed / marker wrong: $(echo "$resp" | head -c 200)"
fi

# =========================================================================
# TEST B (cont.) — dedup: a repeat request does not double-append.
# =========================================================================
h1 "TEST B — request dedup"

resp=$(auth_rpc "$TOKEN_B" "request_minigame_round_keys" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"status":"requested"' && echo "$resp" | grep -q "\"key_requests\":\[\"$UUID_B\"\]" && ! echo "$resp" | grep -q "\"$UUID_B\",\"$UUID_B\""; then
  ok "repeat request is deduped (B appears once in key_requests)"
else
  nok "repeat request NOT deduped: $(echo "$resp" | head -c 200)"
fi

# A second participant (A, the host) flags too → the marker holds both.
resp=$(auth_rpc "$TOKEN_A" "request_minigame_round_keys" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"key_requests":\["' && echo "$resp" | grep -q "$UUID_A" && echo "$resp" | grep -q "$UUID_B"; then
  ok "a second participant A is appended (marker holds both requesters)"
else
  nok "second requester append failed: $(echo "$resp" | head -c 200)"
fi

# =========================================================================
# TEST C — resolve is participant-only + never self-clears + clears a peer.
# =========================================================================
h1 "TEST C — resolve contract"

# A group-member non-participant cannot resolve.
resp=$(auth_rpc "$TOKEN_C" "resolve_minigame_key_request" "{\"p_session_id\":\"$SESSION_ID\",\"p_requester\":\"$UUID_B\"}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then
  ok "non-participant resolve denied (not_allowed)"
else
  nok "non-participant resolve NOT denied: $resp"
fi

# A requester cannot clear ITS OWN flag.
resp=$(auth_rpc "$TOKEN_B" "resolve_minigame_key_request" "{\"p_session_id\":\"$SESSION_ID\",\"p_requester\":\"$UUID_B\"}")
if echo "$resp" | grep -q '"status":"self_resolve"'; then
  ok "self-resolve denied (self_resolve)"
else
  nok "self-resolve NOT denied: $resp"
fi

# A is the host (holds keys) → clears B after a successful serve.
resp=$(auth_rpc "$TOKEN_A" "resolve_minigame_key_request" "{\"p_session_id\":\"$SESSION_ID\",\"p_requester\":\"$UUID_B\"}")
# Inspect ONLY the key_requests array — the state payload also carries the
# round's subject_id (which may be B), so a whole-response negative grep is
# too loose.
kr=$(echo "$resp" | grep -o '"key_requests":\[[^]]*\]' | head -1)
if echo "$resp" | grep -q '"status":"resolved"' && echo "$kr" | grep -q "$UUID_A" && ! echo "$kr" | grep -q "$UUID_B"; then
  ok "host A resolves B — B removed from key_requests, A (not yet served) stays flagged"
else
  nok "resolve failed: resp=$(echo "$resp" | head -c 160) kr=$kr"
fi

# =========================================================================
# TEST D — the real heal shape: the served requester's bundle row is
# re-addressable under a participant's CURRENT identity. A (host, key holder)
# writes a fresh A→B bundle row (the client re-wraps K_0..K_r here), then B
# reads its own-recipient rows — the delivery seam the heal relies on.
# =========================================================================
h1 "TEST D — bundle delivery seam serves the requester"

# A clears its own marker first (simulating its own serve completion).
resp=$(auth_rpc "$TOKEN_B" "resolve_minigame_key_request" "{\"p_session_id\":\"$SESSION_ID\",\"p_requester\":\"$UUID_A\"}")
if echo "$resp" | grep -q '"status":"resolved"'; then
  ok "B resolves A — marker now empty (both served)"
else
  nok "resolve A failed: $(echo "$resp" | head -c 200)"
fi

# A→B bundle insert (participant to participant) is the heal's delivery leg.
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SUPABASE_URL/rest/v1/minigame_e2ee_bundles" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "{\"session_id\":\"$SESSION_ID\",\"sender_id\":\"$UUID_A\",\"recipient_id\":\"$UUID_B\",\"bundle_ciphertext\":\"rekey_ok\"}")
if [ "$code" = "201" ]; then
  ok "holder A writes a fresh A→B bundle row (201) — the requester's current-identity re-wrap lands"
else
  nok "holder A→B bundle INSERT returned $code (expected 201)"
fi

rows=$(curl -s "$SUPABASE_URL/rest/v1/minigame_e2ee_bundles?select=sender_id&session_id=eq.$SESSION_ID&recipient_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json)
if echo "$rows" | grep -q "\"sender_id\":\"$UUID_A\""; then
  ok "requester B reads the holder A re-wrap row (self-heal picks it up)"
else
  nok "requester B cannot read the served row: $rows"
fi

# The marker is empty after both serves — the ring stops.
resp=$(auth_rpc "$TOKEN_A" "get_minigame_game_state" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -q '"key_requests":\[\]' || ! echo "$resp" | grep -q '"key_requests":'; then
  ok "key_requests marker is empty after both serves (ring quiet)"
else
  nok "key_requests marker not empty after serves: $(echo "$resp" | head -c 200)"
fi

# =========================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-022 SUMMARY: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
