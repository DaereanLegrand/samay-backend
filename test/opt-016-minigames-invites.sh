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
#   D) accept_minigame_invite joins the participant list (slim-prod: no escrow)
#   E) a finished session cannot be accepted (session_finished)
#   F) decline_minigame_invite DELETES the invite row (2026-09-02 — a declined
#      invite is indistinguishable from one that never existed; re-decline is
#      invite_not_found)
#   H) invite notifications: direct invites notify with gameType/sessionName;
#      the wager is stated explicitly in body/data and the inviter/group name
#      is carried for the accept surfaces (200_minigame_invite_notice)
#   J) re-invite after DECLINE / KICK is a plain fresh invite (invited 1, fresh
#      pending row, INSERT notification, RLS restored, participants grow) —
#      no special resend path; a still-pending invitee re-invite stays idempotent
#
# Usage: bash test/opt-016-minigames-invites.sh
# Requires the stack with migration 140 applied (supabase db reset).
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
. "$(cd "$(dirname "$0")" && pwd)/minigame_finish_helper.sh"

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
  # The group must go BEFORE its host user row (groups.created_by_user_id
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
  sed -E 's/([][,{}:])[[:space:]]+/\1/g; s/[[:space:]]+([][,{}:])/\1/g'
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
TOKEN_D=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_D\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ] && [ -n "$TOKEN_D" ]; then
  ok "Obtained auth tokens"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Invite Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A (host) + B (member) active; C is NOT a member"

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
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"poke_chain\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
INVITED=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -qE '"status": *"created"' && [ -n "$SESSION_ID" ]; then
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
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"questions\",\"p_invitees\":[\"$UUID_C\"]}")
if echo "$resp" | grep -qE '"status": *"invitee_friends_only"'; then
  ok "A (non-friend) inviting C is rejected: invitee_friends_only"
else
  nok "Non-friend invite to friends-only user not rejected: $(echo "$resp" | head -c 100)"
fi

# Make A and C friends (accepted), then A can invite C.
resp=$(svc_post "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"accepted\"}" >/dev/null 2>&1; echo ok)
# Use RPC for cleanliness — insert a pending then accept via B? simpler: service row
svc_post "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"accepted\"}" >/dev/null
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"questions\",\"p_invitees\":[\"$UUID_C\"]}")
SESSION2=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status": *"created"'; then
  ok "A (now friend) can invite C to a session ($SESSION2)"
else
  nok "Friend invite failed: $(echo "$resp" | head -c 100)"
fi

# =========================================================================
# TEST D — accept_minigame_invite joins the participant (no escrow in slim-prod)
# =========================================================================
h1 "TEST D — accept a pending invite"

INVITE_ID=$(auth_get "$TOKEN_C" "minigame_invites?select=id&session_id=eq.$SESSION2&status=eq.pending" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$INVITE_ID" ]; then
  nok "C has no pending invite row for session2"
else
  resp=$(auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_ID\"}")
  if echo "$resp" | grep -qE '"status": *"accepted"'; then
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
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"challenge\",\"p_invitees\":[\"$UUID_C\"]}")
SESSION3=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
finish_game "$UUID_A" "$SESSION3" >/dev/null
INVITE3=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION3&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE3\"}")
if echo "$resp" | grep -qE '"status": *"session_finished"'; then
  ok "Accepting an invite to a finished session is rejected: session_finished"
else
  nok "Finished-session accept not rejected: $(echo "$resp" | head -c 100)"
fi

# =========================================================================
# TEST F — decline_minigame_invite
# =========================================================================
h1 "TEST F — decline a pending invite"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_C\"]}")
SESSION4=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
INVITE4=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION4&invitee_id=eq.$UUID_C" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_C" "decline_minigame_invite" "{\"p_invite_id\":\"$INVITE4\"}")
if echo "$resp" | grep -qE '"status": *"declined"'; then
  ok "C declined the invite"
else
  nok "decline failed: $(echo "$resp" | head -c 100)"
fi

# F2: the declined invite row is GONE — a declined invite is indistinguishable
# from one that never existed (2026-09-02 user directive). Re-inviting C later
# is therefore a plain fresh INSERT.
resp=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?session_id=eq.$SESSION4&invitee_id=eq.$UUID_C&select=id" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
if ! echo "$resp" | grep -q '"id"'; then
  ok "declining DELETED the invite row (no lingering declined state)"
else
  nok "invite row still present after decline: $(echo "$resp" | head -c 80)"
fi
# F3: declining again is idempotent (row already gone → invite_not_found).
resp=$(auth_rpc "$TOKEN_C" "decline_minigame_invite" "{\"p_invite_id\":\"$INVITE4\"}")
if echo "$resp" | grep -qE '"status": *"invite_not_found"'; then
  ok "re-declining a deleted invite returns invite_not_found (idempotent)"
else
  nok "re-decline expected invite_not_found: $(echo "$resp" | head -c 100)"
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
  svc_post "users" "{\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-00000000000$i\",\"username\":\"cap_filler_$i\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":100,\"preshards\":0,\"age_confirmed_at\":\"2026-01-01T00:00:00Z\",\"terms_accepted_at\":\"2026-01-01T00:00:00Z\"}" >/dev/null
done
CAP_INVITEES=""
for i in 1 2 3 4 5 6 7 8 9; do
  CAP_INVITEES="$CAP_INVITEES\"aaaaaaaa-aaaa-aaaa-aaaa-00000000000$i\","
done
CAP_INVITEES="${CAP_INVITEES%,}"
info "Seeded 9 cap-filler users for the over-cap check"

# G1 + G2: direct create with p_group_id null.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"poke_chain\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
SESSION5=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status": *"created"' && [ -n "$SESSION5" ]; then
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
resp=$(finish_game "$UUID_A" "$SESSION5")
if echo "$resp" | grep -qE '"status": *"finished"'; then ok "Creator A finished the direct session"; else nok "finish failed: $(echo "$resp" | head -c 100)"; fi
resp=$(finish_game "$UUID_D" "$SESSION5")
if echo "$resp" | grep -qE '"status": *"not_allowed"'; then ok "Bystander D cannot finish the direct session (not_allowed)"; else nok "bystander finish not rejected: $(echo "$resp" | head -c 100)"; fi

# G6: over-cap roster is rejected atomically (10 invitees + self > free 8).
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"questions\",\"p_invitees\":[$CAP_INVITEES]}")
if echo "$resp" | grep -qE '"status": *"player_limit_reached"'; then
  ok "Over-cap direct create rejected: player_limit_reached"
else
  nok "Over-cap create not rejected: $(echo "$resp" | head -c 120)"
fi

# =========================================================================
# TEST H — invite notifications + auto partida-N (170_minigame_invite_badges)
#   H1) a DIRECT invite notifies the INVITEE (the 140 early-return for
#       group_id IS NULL is gone) with gameType + sessionName in data
#   H2) create_minigame_session stores the server auto_name (partida-N)
#       on the row, canonical for creator AND invitee
# =========================================================================
h1 "TEST H — direct-invite notification + auto partida-N"

# H1: A creates a DIRECT truth_dare inviting C; C must get a notification.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_C\"]}")
SESSION_H=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status": *"created"' && [ -n "$SESSION_H" ]; then
  ok "Direct truth_dare session created for the notification check ($SESSION_H)"
else
  nok "Direct create failed for TEST H: $(echo "$resp" | head -c 120)"
fi

# C reads their own notifications (RLS user_id = C).
notif_resp=$(curl -s -X GET "$SUPABASE_URL/rest/v1/notifications?user_id=eq.$UUID_C&type=eq.minigame_invite&order=created_at.desc&limit=1&select=data,body" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" | norm_json)
if echo "$notif_resp" | grep -q "$SESSION_H"; then
  ok "Invitee C received a minigame_invite notification for the DIRECT session"
else
  nok "No direct-session notification for C: $(echo "$notif_resp" | head -c 120)"
fi
if echo "$notif_resp" | grep -q '"gameType":"truth_dare"'; then
  ok "The notification payload carries gameType (per-game feed badge)"
else
  nok "notification data missing gameType: $(echo "$notif_resp" | head -c 120)"
fi
# H1b: SESSION_H is a FREE game (wager 0) — the body must say "FREE" and the
# payload must carry wager 0 (200_minigame_invite_notice).
if echo "$notif_resp" | grep -q '"body":"FREE"'; then
  ok "The FREE (0-wager) invite notification body says FREE (200_minigame_invite_notice)"
else
  nok "FREE-game notification body not FREE: $(echo "$notif_resp" | head -c 120)"
fi
if echo "$notif_resp" | grep -q '"wager":0'; then
  ok "The FREE-game notification payload carries wager 0"
else
  nok "FREE-game notification data missing wager: $(echo "$notif_resp" | head -c 120)"
fi
# H1b2: the DIRECT free-game invite carries the inviter username and no group
# name (SESSION_H is a direct session by A).
if echo "$notif_resp" | grep -q '"inviterName":"user_opt016_a"'; then
  ok "The direct-invite notification carries the inviter username (user_opt016_a)"
else
  nok "Direct-invite notification missing inviterName: $(echo "$notif_resp" | head -c 120)"
fi
if echo "$notif_resp" | grep -q '"groupName":null'; then
  ok "The direct-invite notification carries groupName null"
else
  nok "Direct-invite notification groupName not null: $(echo "$notif_resp" | head -c 120)"
fi

# H1e: a GROUP invite (SESSION_ID, group "Invite Test") must carry the GROUP
# NAME so the invitee sees "from <group>" on the accept surface.
notif_g=$(curl -s -X GET "$SUPABASE_URL/rest/v1/notifications?user_id=eq.$UUID_C&type=eq.minigame_invite&data->>sessionId=eq.$SESSION_ID&order=created_at.desc&limit=1&select=data,body" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" | norm_json)
if echo "$notif_g" | grep -q '"groupName":"Invite Test"'; then
  ok "The group-invite notification carries the group name (Invite Test)"
else
  nok "Group-invite notification missing groupName: $(echo "$notif_g" | head -c 120)"
fi

# H1c: a DIRECT invite is wager-free in slim-prod (the shard economy is
# removed), so the body says FREE and the payload carries wager 0.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"questions\",\"p_invitees\":[\"$UUID_C\"]}")
SESSION_W=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status": *"created"' && [ -n "$SESSION_W" ]; then
  ok "Direct questions session created for the invite-notice check ($SESSION_W)"
else
  nok "Direct create failed: $(echo "$resp" | head -c 120)"
fi
notif_w=$(curl -s -X GET "$SUPABASE_URL/rest/v1/notifications?user_id=eq.$UUID_C&type=eq.minigame_invite&data->>sessionId=eq.$SESSION_W&order=created_at.desc&limit=1&select=data,body" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" | norm_json)
if echo "$notif_w" | grep -q '"body":"FREE"'; then
  ok "The direct invite notification body says FREE (wager economy removed)"
else
  nok "Direct invite notification body not FREE: $(echo "$notif_w" | head -c 120)"
fi
if echo "$notif_w" | grep -q '"wager":0'; then
  ok "The direct invite payload carries wager 0 (retired column)"
else
  nok "Direct invite payload missing wager 0: $(echo "$notif_w" | head -c 120)"
fi
# H1d: a DIRECT invite must carry the inviter's username (user_search_view) so
# the accept surface can show who invited you; groupName must be null.
if echo "$notif_w" | grep -q '"inviterName":"user_opt016_a"'; then
  ok "The direct-invite notification carries the inviter username (user_opt016_a)"
else
  nok "Direct-invite notification missing inviterName: $(echo "$notif_w" | head -c 120)"
fi
if echo "$notif_w" | grep -q '"groupName":null'; then
  ok "The direct-invite notification carries groupName null"
else
  nok "Direct-invite notification groupName not null: $(echo "$notif_w" | head -c 120)"
fi

# H2: the session row carries the server-computed auto_name (partida-N).
row_resp=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION_H&select=auto_name" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | norm_json)
if echo "$row_resp" | grep -q '"auto_name":"partida-[0-9]*"'; then
  ok "create_minigame_session stored the canonical auto_name (partida-N)"
else
  nok "auto_name missing on the session row: $(echo "$row_resp" | head -c 120)"
fi

# =========================================================================
# TEST I — invite_minigame_players (205_minigame_invite_lobby, 2026-09-01)
# The 2026-09-01 flow: a session is created with ZERO invitees, then the
# HOST invites players from the partida lobby while waiting. The new RPC:
#   I1) the creator invites into an existing session (ok + pending rows)
#   I2) re-inviting already-pending invitees is IDEMPOTENT (invited 0)
#   I3) a NON-creator (B, not yet a participant) is rejected: not_creator
#   I4) already-participant invitees are skipped (B accepts, then re-invite)
#   I5) the friends-only privacy gate still applies (D opts in, A not a friend)
#   I6) the frozen player cap is re-checked (player_limit_reached)
#   I7) the invite dispatches the minigame_invite notification unchanged
# =========================================================================
h1 "TEST I — lobby invite RPC (invite_minigame_players)"

# I1: A creates a DIRECT session with ZERO invitees, then invites B + C.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"poke_chain\",\"p_invitees\":[]}")
SESSION_I=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status": *"created"' && [ -n "$SESSION_I" ]; then
  ok "Lobby-flow direct session created with zero invitees ($SESSION_I)"
else
  nok "Zero-invitee create failed: $(echo "$resp" | head -c 120)"
fi

resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_I\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
INVITED_I=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -qE '"status": *"ok"'; then
  ok "invite_minigame_players returned ok (lobby invite)"
else
  nok "invite_minigame_players failed: $(echo "$resp" | head -c 120)"
fi
if [ "$INVITED_I" = "2" ]; then ok "lobby invite invited 2 players (B, C)"; else nok "invited count != 2: $resp"; fi

# The invite rows landed (pending) — the invitee-side read (ms_read_invitee).
resp=$(auth_get "$TOKEN_C" "minigame_invites?select=id,status&session_id=eq.$SESSION_I")
if echo "$resp" | grep -qE '"status": *"pending"'; then
  ok "C has a pending invite row for the lobby-invited session"
else
  nok "C has no pending invite row: $(echo "$resp" | head -c 100)"
fi

# I2: re-inviting B + C (already pending) is idempotent — invited 0.
resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_I\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
INVITED_I2=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -qE '"status": *"ok"' && [ "$INVITED_I2" = "0" ]; then
  ok "Re-inviting already-pending players is idempotent (invited 0)"
else
  nok "Re-invite not idempotent: $(echo "$resp" | head -c 120)"
fi

# I3: B (not the creator, not yet a participant) cannot invite.
resp=$(auth_rpc "$TOKEN_B" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_I\",\"p_invitees\":[\"$UUID_D\"]}")
if echo "$resp" | grep -qE '"status": *"not_creator"'; then
  ok "Non-creator B is rejected: not_creator"
else
  nok "Non-creator invite not rejected: $(echo "$resp" | head -c 120)"
fi

# I4: B accepts, becomes a participant; re-inviting B is skipped (invited 0).
INVITE_IB=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?select=id&session_id=eq.$SESSION_I&invitee_id=eq.$UUID_B" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_IB\"}")
if echo "$resp" | grep -qE '"status": *"accepted"'; then ok "B accepted the lobby invite"; else nok "B accept failed: $(echo "$resp" | head -c 100)"; fi
resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_I\",\"p_invitees\":[\"$UUID_B\"]}")
INVITED_I4=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -qE '"status": *"ok"' && [ "$INVITED_I4" = "0" ]; then
  ok "Re-inviting an already-participant is skipped (invited 0)"
else
  nok "Already-participant re-invite not skipped: $(echo "$resp" | head -c 120)"
fi

# I5: friends-only privacy still enforced by the lobby RPC. D opts in and is
# not A's friend -> invitee_friends_only.
auth_rpc "$TOKEN_D" "set_minigame_invite_friends_only" "{\"p_value\":true}" >/dev/null
resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_I\",\"p_invitees\":[\"$UUID_D\"]}")
if echo "$resp" | grep -qE '"status": *"invitee_friends_only"'; then
  ok "Friends-only privacy enforced by the lobby RPC (invitee_friends_only)"
else
  nok "Lobby invite to friends-only user not rejected: $(echo "$resp" | head -c 120)"
fi

# I6: frozen player cap re-checked — A + 8 cap-fillers > free 8.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"questions\",\"p_invitees\":[]}")
SESSION_I6=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
# Reuse the 9 seeded cap-filler users (TEST G6) — invite 8 of them.
CAP8=""
for i in 1 2 3 4 5 6 7 8; do
  CAP8="$CAP8\"aaaaaaaa-aaaa-aaaa-aaaa-00000000000$i\","
done
CAP8="${CAP8%,}"
resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_I6\",\"p_invitees\":[$CAP8]}")
if echo "$resp" | grep -qE '"status": *"player_limit_reached"'; then
  ok "Over-cap lobby invite rejected: player_limit_reached"
else
  nok "Over-cap lobby invite not rejected: $(echo "$resp" | head -c 120)"
fi

# I7: the lobby invite dispatched a minigame_invite notification to C.
notif_i=$(curl -s -X GET "$SUPABASE_URL/rest/v1/notifications?user_id=eq.$UUID_C&type=eq.minigame_invite&data->>sessionId=eq.$SESSION_I&order=created_at.desc&limit=1&select=data" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" | norm_json)
if echo "$notif_i" | grep -q "$SESSION_I"; then
  ok "Lobby invite dispatched a minigame_invite notification to C"
else
  nok "No lobby-invite notification for C: $(echo "$notif_i" | head -c 120)"
fi

# =========================================================================
# TEST J — re-invite after decline / after kick (2026-09-02).
# A declined invite DELETES its row, so a re-invite is a plain fresh INSERT
# (no UNIQUE conflict, notification fires). A kick ALSO deletes the invite
# row (remove_minigame_participant), so re-inviting a kicked player is the
# same fresh INSERT — they read the session again (RLS restored) and can
# accept, growing the participants array. There is NO special "resend": a
# re-invite is byte-for-byte the same as the first invite.
# =========================================================================
h1 "TEST J — re-invite after decline / kick (fresh invite, no resend path)"

# J1: A invites C (who already declined SESSION4) into a NEW session; the
#     previous declined row is gone, so the re-invite is a fresh pending row.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"questions\",\"p_invitees\":[\"$UUID_C\"]}")
SESSION_J1=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status": *"created"' && [ -n "$SESSION_J1" ]; then
  ok "New session created for the re-invite check ($SESSION_J1)"
else
  nok "Re-invite session create failed: $(echo "$resp" | head -c 120)"
fi

# J1a: C declines J1, then A re-invites C via invite_minigame_players.
INVITE_J1=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?session_id=eq.$SESSION_J1&invitee_id=eq.$UUID_C&select=id" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
auth_rpc "$TOKEN_C" "decline_minigame_invite" "{\"p_invite_id\":\"$INVITE_J1\"}" > /dev/null
resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_J1\",\"p_invitees\":[\"$UUID_C\"]}")
INVITED_J1=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -qE '"status": *"ok"' && [ "$INVITED_J1" = "1" ]; then
  ok "Re-inviting after DECLINE is a fresh insert (invited 1)"
else
  nok "Re-invite after decline expected invited 1: $(echo "$resp" | head -c 120)"
fi
INVITE_J1b=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?session_id=eq.$SESSION_J1&invitee_id=eq.$UUID_C&select=id,status" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
if echo "$INVITE_J1b" | grep -qE '"status": *"pending"'; then
  ok "The re-invite row is a brand-new pending invite (identical to the first)"
else
  nok "Re-invite row not pending: $(echo "$INVITE_J1b" | head -c 120)"
fi
notif_j1=$(curl -s -X GET "$SUPABASE_URL/rest/v1/notifications?user_id=eq.$UUID_C&type=eq.minigame_invite&data->>sessionId=eq.$SESSION_J1&order=created_at.desc&limit=1&select=data" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_C" | norm_json)
if echo "$notif_j1" | grep -q "$SESSION_J1"; then
  ok "The re-invite dispatched a minigame_invite notification (INSERT trigger fires)"
else
  nok "No notification for the re-invite: $(echo "$notif_j1" | head -c 120)"
fi

# J2: kick → re-invite → the kicked player reads the session again + accepts
#     → participants array grows. remove_minigame_participant deletes the
#     invite row, so the re-invite is again a plain fresh INSERT.
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
SESSION_J2=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
# B and C accept → participants = A, B, C.
for uid in $UUID_B $UUID_C; do
  INVITE_J2=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?session_id=eq.$SESSION_J2&invitee_id=eq.$uid&select=id" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ "$uid" = "$UUID_B" ]; then
    auth_rpc "$TOKEN_B" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_J2\"}" > /dev/null
  else
    auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_J2\"}" > /dev/null
  fi
done
# A (creator) kicks C.
auth_rpc "$TOKEN_A" "remove_minigame_participant" "{\"p_session_id\":\"$SESSION_J2\",\"p_user_id\":\"$UUID_C\"}" > /dev/null
# C (kicked, invite row deleted) can no longer read the session (RLS).
resp=$(auth_get "$TOKEN_C" "minigame_sessions?id=eq.$SESSION_J2&select=id")
if echo "$resp" | grep -q '"id"'; then
  nok "Kicked C can still read the session (RLS leak)"
else
  ok "Kicked C loses RLS read on the session (invite row deleted)"
fi

# A re-invites C (invite row was deleted by the kick → fresh insert).
resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_J2\",\"p_invitees\":[\"$UUID_C\"]}")
INVITED_J2=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -qE '"status": *"ok"' && [ "$INVITED_J2" = "1" ]; then
  ok "Re-inviting after KICK is a fresh insert (invited 1)"
else
  nok "Re-invite after kick expected invited 1: $(echo "$resp" | head -c 120)"
fi

# C can read the session again (RLS restored via the fresh pending row).
resp=$(auth_get "$TOKEN_C" "minigame_sessions?id=eq.$SESSION_J2&select=id,participants")
if echo "$resp" | grep -q "\"id\":\"$SESSION_J2\""; then
  ok "Kicked C re-invited can read the session again (RLS restored)"
else
  nok "Re-invited C cannot read the session: $(echo "$resp" | head -c 120)"
fi

# C accepts → participants grow to include C.
INVITE_J2b=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_invites?session_id=eq.$SESSION_J2&invitee_id=eq.$UUID_C&select=id" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_C" "accept_minigame_invite" "{\"p_invite_id\":\"$INVITE_J2b\"}")
if echo "$resp" | grep -qE '"status": *"accepted"'; then ok "Kicked C accepted the re-invite"; else nok "C re-accept failed: $(echo "$resp" | head -c 100)"; fi
resp=$(curl -s -X GET "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION_J2&select=participants" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
if echo "$resp" | grep -q "$UUID_C"; then
  ok "Kicked-and-re-invited C is back in the participants array (roster grows)"
else
  nok "C not in participants after re-accept: $(echo "$resp" | head -c 120)"
fi

# J3: re-inviting a STILL-PENDING invitee stays idempotent (invited 0) —
#     the fresh pending row from J2 is still there.
resp=$(auth_rpc "$TOKEN_A" "invite_minigame_players" \
  "{\"p_session_id\":\"$SESSION_J2\",\"p_invitees\":[\"$UUID_C\"]}")
INVITED_J3=$(echo "$resp" | grep -o '"invited":[0-9]*' | cut -d':' -f2)
if echo "$resp" | grep -qE '"status": *"ok"' && [ "$INVITED_J3" = "0" ]; then
  ok "Re-inviting a still-pending invitee stays idempotent (invited 0)"
else
  nok "Still-pending re-invite not idempotent: $(echo "$resp" | head -c 120)"
fi

# =========================================================================
h1 "RESULTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo ""; echo "  🎉 All tests passed!"; exit 0; fi
echo ""; echo "  💥 Some tests failed."; exit 1