#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-016] Minigame invites — Integration Test (140_minigame_invites)
# Verifies the invite-aware create_minigame_session + invite RPC family:
#   A) create a minigame session with non-member invitees (pending invite rows)
#   B) an invitee (non-member) can READ the session row (ms_read_invitee)
#   C) friends-only privacy: a user with minigame_invite_friends_only=true
#      cannot be invited by a non-friend (invitee_friends_only), but CAN by
#      an accepted friend
#   D) accept_minigame_invite joins the participant list (escrow on wager)
#   E) a finished session cannot be accepted (session_finished)
#   F) decline_minigame_invite flips pending -> declined
#
# Usage: bash test/opt-016-minigames-invites.sh
# Requires the stack with migration 140 applied (supabase db reset).
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  # Friendships (both directions) between the test users — a leftover
  # accepted friendship from a prior run would silently satisfy the
  # friends-only invite gate and poison TEST C isolation.
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    svc_delete "friendships?or=(requester_id.eq.$uid,addressee_id.eq.$uid)" > /dev/null 2>&1 || true
  done
  # Minigame invites (pending leftovers would also block fresh creates).
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  # The group must go BEFORE its promotor user row (groups.created_by_user_id
  # is a NO-ACTION FK).
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  # Cap-filler user rows seeded for TEST G6 (no auth row, so service delete).
  for i in 1 2 3 4 5 6 7 8 9; do
    svc_delete "users?id=eq.aaaaaaaa-aaaa-aaaa-aaaa-00000000000$i" > /dev/null 2>&1 || true
  done
  # Public.users rows + auth users for the four testers (a leftover
  # users.minigame_invite_friends_only=true from a prior run would poison
  # TEST A's invites to C).
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

# PostgREST may render JSON with spaces after colons/commas; the greps that
# parse statuses/session ids expect compact JSON, so normalize before use.
norm_json() {
  sed -E 's/[[:space:]]+//g'
}

auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" | norm_json
}
auth_post() {
  local t=$1; shift
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Prefer: return=representation" -d "$2"
}
auth_patch() {
  local t=$1; shift
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
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
UUID_D="88888888-8888-8888-8888-888888888888"
GROUP_ID="77777777-7777-7777-7777-777777777777"
EMAIL_A="user_a_opt016@samay.test"
EMAIL_B="user_b_opt016@samay.test"
EMAIL_C="user_c_opt016@samay.test"
EMAIL_D="user_d_opt016@samay.test"
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

for pair in "UUID_A:user_opt016_a" "UUID_B:user_opt016_b" "UUID_C:user_opt016_c" "UUID_D:user_opt016_d"; do
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

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Invite Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (promotor) + B (member) active; C is NOT a member"

# Make A and B friends (accepted) so the friends-only gate can be tested.
resp=$(auth_post "$TOKEN_A" "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_B\",\"status\":\"pending\"}")
FID=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_B" "accept_friend_request" "{\"p_friendship_id\":\"$FID\"}" > /dev/null
info "A and B are now accepted friends"

# =========================================================================
# TEST A — create a session with non-member invitees (C)
# =========================================================================
h1 "TEST A — create session with invitees (non-member C)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"poke_chain\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
INVITED=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "create_minigame_session returned created ($SESSION_ID)"
else
  nok "create_minigame_session failed: $(echo "$resp" | head -c 120)"
fi
if [ "$INVITED" = "2" ]; then ok "invited count = 2"; else nok "invited count != 2: $resp"; fi

# =========================================================================
# TEST B — invitee C (non-member) can read the session row (ms_read_invitee)
# =========================================================================
h1 "TEST B — non-member invitee can read the session (ms_read_invitee)"

resp=$(auth_get "$TOKEN_C" "minigame_sessions?id=eq.$SESSION_ID&select=id,status")
if echo "$resp" | grep -q "\"id\":\"$SESSION_ID\""; then
  ok "Invitee C (non-member) can read the session"
else
  nok "Invitee C cannot read the session: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
# TEST C — friends-only privacy gate
# =========================================================================
h1 "TEST C — friends-only privacy (minigame_invite_friends_only)"

# C opts into friends-only.
auth_rpc "$TOKEN_C" "set_minigame_invite_friends_only" "{\"p_value\":true}" >/dev/null
ok "C enabled friends-only invites"

# A is NOT a friend of C -> invite must be rejected atomically.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"questions\",\"p_wager\":0,\"p_invitees\":[\"$UUID_C\"]}")
if echo "$resp" | grep -q '"status":"invitee_friends_only"'; then
  ok "A (non-friend) inviting C is rejected: invitee_friends_only"
else
  nok "Non-friend invite to friends-only user not rejected: $(echo "$resp" | head -c 100)"
fi

# Make A and C friends (accepted), then A can invite C.
resp=$(svc_post "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"accepted\"}" >/dev/null 2>&1; echo ok)
# Use RPC for cleanliness — insert a pending then accept via B? simpler: service row
svc_post "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"accepted\"}" >/dev/null
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"questions\",\"p_wager\":10,\"p_invitees\":[\"$UUID_C\"]}")
SESSION2=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"'; then
  ok "A (now friend) can invite C to a wagered session ($SESSION2)"
else
  nok "Friend invite failed: $(echo "$resp" | head -c 100)"
fi

# =========================================================================
# TEST D — accept_minigame_invite joins the participant (wager escrow)
# =========================================================================
h1 "TEST D — accept a pending invite (wagered session)"

INVITE_ID=$(auth_get "$TOKEN_C" "minigame_invites?select=id&session_id=eq.$SESSION2&status=eq.pending" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$INVITE_ID" ]; then
  nok "C has no pending invite row for session2"
else
  resp=$(auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_ID\"}")
  if echo "$resp" | grep -q '"status":"accepted"'; then
    ok "C accepted the invite"
  else
    nok "accept failed: $(echo "$resp" | head -c 100)"
  fi
  resp=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION2&select=participants" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
  if echo "$resp" | grep -q "$UUID_C"; then
    ok "C is now in the participants array"
  else
    nok "C not in participants: $(echo "$resp" | head -c 80)"
  fi
fi

# =========================================================================
# TEST E — a finished session cannot be accepted (session_finished)
# =========================================================================
h1 "TEST E — finished session closes the invite"

# Create a fresh session inviting C, decline-capable path: finish it first.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"challenge\",\"p_wager\":0,\"p_invitees\":[\"$UUID_C\"]}")
SESSION3=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
auth_rpc "$TOKEN_A" "finish_minigame_session" "{\"p_session_id\":\"$SESSION3\",\"p_winner_id\":null,\"p_place\":null}" >/dev/null
INVITE3=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION3&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE3\"}")
if echo "$resp" | grep -q '"status":"session_finished"'; then
  ok "Accepting an invite to a finished session is rejected: session_finished"
else
  nok "Finished-session accept not rejected: $(echo "$resp" | head -c 100)"
fi

# =========================================================================
# TEST F — decline_minigame_invite
# =========================================================================
h1 "TEST F — decline a pending invite"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0,\"p_invitees\":[\"$UUID_C\"]}")
SESSION4=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
INVITE4=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION4&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_C" "decline_minigame_invite" "{\"p_invite_id\":\"$INVITE4\"}")
if echo "$resp" | grep -q '"status":"declined"'; then
  ok "C declined the invite"
else
  nok "decline failed: $(echo "$resp" | head -c 100)"
fi

# =========================================================================
# TEST G — DIRECT sessions (p_group_id null, direct-minigames 2026-08-27)
#   G1) a user with NO group can create a direct session (null group_id)
#   G2) the free-tier player_limit is frozen at 8 on the session row
#   G3) a non-member invitee can read/accept a direct session
#   G4) a bystander (non-participant, non-invitee) CANNOT read it (RLS)
#   G5) the creator settles it (finish); a bystander is rejected (not_allowed)
#   G6) the frozen player cap rejects an over-cap roster (player_limit_reached)
# =========================================================================
h1 "TEST G — direct sessions (no group)"

# G6 setup: 9 throwaway live user rows (no auth session needed — the
# invitee gate only checks the users table) to overflow the free cap.
for i in 1 2 3 4 5 6 7 8 9; do
  svc_post "users" "{\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-00000000000$i\",\"username\":\"cap_filler_$i\",\"personal_shards\":100,\"preshards\":0}" >/dev/null
done
CAP_INVITEES=""
for i in 1 2 3 4 5 6 7 8 9; do
  CAP_INVITEES="$CAP_INVITEES\"aaaaaaaa-aaaa-aaaa-aaaa-00000000000$i\","
done
CAP_INVITEES="${CAP_INVITEES%,}"
info "Seeded 9 cap-filler users for the over-cap check"

# G1 + G2: direct create with p_group_id null.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"poke_chain\",\"p_wager\":0,\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
SESSION5=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION5" ]; then
  ok "Direct session created with p_group_id null ($SESSION5)"
else
  nok "Direct create failed: $(echo "$resp" | head -c 120)"
fi

resp=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION5&select=group_id,player_limit" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
if echo "$resp" | grep -q '"group_id":null'; then ok "Direct session row carries group_id null"; else nok "group_id not null: $(echo "$resp" | head -c 80)"; fi
if echo "$resp" | grep -q '"player_limit":8'; then ok "Free-tier player_limit frozen at 8"; else nok "player_limit != 8: $(echo "$resp" | head -c 80)"; fi

# G3: C (non-member, pending invitee) can read the direct session.
resp=$(auth_get "$TOKEN_C" "minigame_sessions?id=eq.$SESSION5&select=id,status")
if echo "$resp" | grep -q "\"id\":\"$SESSION5\""; then
  ok "Invitee C (non-member) can read the direct session"
else
  nok "Invitee C cannot read direct session: $(echo "$resp" | head -c 80)"
fi

# G4: bystander D (not a participant, not invited) must NOT read it.
resp=$(auth_get "$TOKEN_D" "minigame_sessions?id=eq.$SESSION5&select=id")
if echo "$resp" | grep -q "\"id\""; then
  nok "Bystander D read a direct session they are not in (RLS leak!)"
else
  ok "Bystander D cannot read the direct session (ms_read_direct_participant)"
fi

# G5: the creator settles (draw); a bystander is rejected.
resp=$(auth_rpc "$TOKEN_A" "finish_minigame_session" "{\"p_session_id\":\"$SESSION5\",\"p_winner_id\":null,\"p_place\":null}")
if echo "$resp" | grep -q '"status":"finished"'; then ok "Creator A finished the direct session"; else nok "finish failed: $(echo "$resp" | head -c 100)"; fi
resp=$(auth_rpc "$TOKEN_D" "finish_minigame_session" "{\"p_session_id\":\"$SESSION5\",\"p_winner_id\":null,\"p_place\":null}")
if echo "$resp" | grep -q '"status":"not_allowed"'; then ok "Bystander D cannot finish the direct session (not_allowed)"; else nok "bystander finish not rejected: $(echo "$resp" | head -c 100)"; fi

# G6: over-cap roster is rejected atomically (10 invitees + self > free 8).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"questions\",\"p_wager\":0,\"p_invitees\":[$CAP_INVITEES]}")
if echo "$resp" | grep -q '"status":"player_limit_reached"'; then
  ok "Over-cap direct create rejected: player_limit_reached"
else
  nok "Over-cap create not rejected: $(echo "$resp" | head -c 120)"
fi

# =========================================================================
h1 "RESULTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo ""; echo "  🎉 All tests passed!"; exit 0; fi
echo ""; echo "  💥 Some tests failed."; exit 1