#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-028] get_minigame_invite_context — Integration Test
# (215_minigame_invite_context, 2026-09-11)
#
# The pending-invite LOBBY view must show ONLY the inviter ("INVITADO POR" +
# avatar), never the participant roster. This RPC returns the narrowest
# context; a pending invitee is NOT given the player list.
#
#   A) a pending invitee gets status=ok with the inviter profile (id/username/
#      avatar_url) and groupName null for a DIRECT session
#   B) the response NEVER carries a `participants` array (no roster leak)
#   C) a bystander (never invited) gets invite_not_found and learns nothing
#   D) a GROUP session's context carries the group name
#   E) a lobby-invited player (invite_minigame_players) also gets context
#   F) anon cannot EXECUTE (authenticated-only)
#
# Usage: bash test/opt-030-minigame-invite-context.sh
# Requires the stack with migration 209 applied (supabase db reset).
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

cleanup() {
  for uid in $UUID_A $UUID_B $UUID_C; do
    svc_delete "minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" > /dev/null 2>&1 || true
  done
  [ -n "${GROUP_ID:-}" ] && curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
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

# --- Setup ---
h1 "SETUP: users + group"

UUID_A="a1a1a1a1-1111-1111-1111-111111111111"
UUID_B="b2b2b2b2-2222-2222-2222-222222222222"
UUID_C="c3c3c3c3-3333-3333-3333-333333333333"
GROUP_ID="d4d4d4d4-4444-4444-4444-444444444444"
EMAIL_A="user_a_opt028@samay.test"
EMAIL_B="user_b_opt028@samay.test"
EMAIL_C="user_c_opt028@samay.test"
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

for pair in "UUID_A:user_opt028_a" "UUID_B:user_opt028_b" "UUID_C:user_opt028_c"; do
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

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Context Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"active\"}" >/dev/null
info "Group created; A host + B member; C bystander"

# =========================================================================
# TEST A + B — DIRECT session: invitee gets inviter only, no roster
# =========================================================================
h1 "TEST A/B — direct invite context (inviter only, no participants)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"poke_chain\",\"p_invitees\":[\"$UUID_B\"]}")
SESSION_D=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_D" ]; then
  ok "Direct session created ($SESSION_D)"
else
  nok "Direct create failed: $(echo "$resp" | head -c 120)"
fi

CTX_B=$(auth_rpc "$TOKEN_B" "get_minigame_invite_context" "{\"p_session_id\":\"$SESSION_D\"}")
if echo "$CTX_B" | grep -q '"status":"ok"'; then
  ok "Invitee B gets status=ok"
else
  nok "Invitee B context not ok: $(echo "$CTX_B" | head -c 140)"
fi
if echo "$CTX_B" | grep -q '"username":"user_opt028_a"'; then
  ok "Context carries the inviter username (user_opt028_a)"
else
  nok "Context missing inviter username: $(echo "$CTX_B" | head -c 140)"
fi
if echo "$CTX_B" | grep -q "\"id\":\"$UUID_A\""; then
  ok "Context carries the inviter id"
else
  nok "Context missing inviter id: $(echo "$CTX_B" | head -c 140)"
fi
if echo "$CTX_B" | grep -q '"groupName":null'; then
  ok "Direct context carries groupName null"
else
  nok "Direct context groupName not null: $(echo "$CTX_B" | head -c 140)"
fi
if echo "$CTX_B" | grep -q '"participants"'; then
  nok "Context LEAKED a participants array: $(echo "$CTX_B" | head -c 140)"
else
  ok "Context carries NO participants array (no roster leak)"
fi

# =========================================================================
# TEST C — bystander gets invite_not_found
# =========================================================================
h1 "TEST C — bystander denied"

CTX_C=$(auth_rpc "$TOKEN_C" "get_minigame_invite_context" "{\"p_session_id\":\"$SESSION_D\"}")
if echo "$CTX_C" | grep -q '"status":"invite_not_found"'; then
  ok "Bystander C gets invite_not_found (learns nothing)"
else
  nok "Bystander not denied: $(echo "$CTX_C" | head -c 140)"
fi
if echo "$CTX_C" | grep -q '"participants"'; then
  nok "Bystander response leaked a participants array"
else
  ok "Bystander response carries no roster"
fi

# =========================================================================
# TEST D — GROUP session context carries the group name
# =========================================================================
h1 "TEST D — group invite context carries the group name"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"questions\",\"p_invitees\":[\"$UUID_B\"]}")
SESSION_G=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_G" ]; then
  ok "Group session created ($SESSION_G)"
else
  nok "Group create failed: $(echo "$resp" | head -c 120)"
fi
CTX_G=$(auth_rpc "$TOKEN_B" "get_minigame_invite_context" "{\"p_session_id\":\"$SESSION_G\"}")
if echo "$CTX_G" | grep -q '"groupName":"Context Test"'; then
  ok "Group context carries the group name (Context Test)"
else
  nok "Group context missing group name: $(echo "$CTX_G" | head -c 140)"
fi
if echo "$CTX_G" | grep -q '"participants"'; then
  nok "Group context leaked a participants array"
else
  ok "Group context carries no roster"
fi

# =========================================================================
# TEST E — lobby-invited player (invite_minigame_players) also gets context
# =========================================================================
h1 "TEST E — lobby invite context"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"truth_dare\",\"p_invitees\":[]}")
SESSION_L=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
auth_rpc "$TOKEN_A" "invite_minigame_players" "{\"p_session_id\":\"$SESSION_L\",\"p_invitees\":[\"$UUID_B\"]}" > /dev/null
CTX_L=$(auth_rpc "$TOKEN_B" "get_minigame_invite_context" "{\"p_session_id\":\"$SESSION_L\"}")
if echo "$CTX_L" | grep -q '"status":"ok"' && echo "$CTX_L" | grep -q '"username":"user_opt028_a"'; then
  ok "Lobby-invited B gets the inviter context"
else
  nok "Lobby invite context failed: $(echo "$CTX_L" | head -c 140)"
fi

# =========================================================================
# TEST F — anon cannot EXECUTE (authenticated-only)
# =========================================================================
h1 "TEST F — anon denied"

ANON_CTX=$(curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/get_minigame_invite_context" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
  -H "Content-Type: application/json" -d "{\"p_session_id\":\"$SESSION_D\"}" | norm_json)
if echo "$ANON_CTX" | grep -q '"status":"ok"'; then
  nok "Anon could EXECUTE get_minigame_invite_context"
else
  ok "Anon is denied EXECUTE (authenticated-only)"
fi

# =========================================================================
h1 "RESULTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo ""; echo "  🎉 All tests passed!"; exit 0; fi
echo ""; echo "  💥 Some tests failed."; exit 1
