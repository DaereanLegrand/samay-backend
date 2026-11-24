#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-032] minigame_invites RLS — Integration Test (140_minigame_invites)
#
# Regression guard for the confirmed P0 leak: the table carried FORCE ROW
# LEVEL SECURITY but no ENABLE, so RLS was inert and any authenticated user
# could read every invite. Asserts:
#   A) the creator only sees invites they created
#   B) the invitee only sees invites addressed to them
#   C) an unrelated authenticated user sees ZERO invite rows (the leak)
#   D) an unauthenticated (anon) client cannot read invite rows at all
#
# Transport hardening (2026-09-21): every authenticated read asserts HTTP 200
# AND a JSON-array body, so a failed login / unreachable REST endpoint can no
# longer masquerade as "zero rows". TEST 0 is a POSITIVE control proving the
# unrelated user's token is live and authorized (it reads its own users row);
# without it a 0-row result would be ambiguous.
#
# Usage: bash test/opt-032-minigame-invites-rls.sh
# Requires the stack with migration 140 applied.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

UUID_A="32323232-3232-3232-3232-323232323232"
UUID_X="34343434-3434-3434-3434-343434343434"
UUID_O="36363636-3636-3636-3636-363636363636"
EMAIL_A="user_a_opt032@samay.test"
EMAIL_X="user_x_opt032@samay.test"
EMAIL_O="user_o_opt032@samay.test"
PW="Pass1234!"

# HTTP status of the most recent auth_get/anon_get call is written here so a
# command-substitution call site can still read it in the parent shell.
HTTP_FILE="$(mktemp "${TMPDIR:-/tmp}/opt032.http.XXXXXX")"

SESSION_ID=""
cleanup() {
  [ -f "$HTTP_FILE" ] && rm -f "$HTTP_FILE"
  # Notifications produced by the minigame-invite trigger (keyed by session id)
  # plus any stray rows for the three throwaway users.
  if [ -n "${SESSION_ID:-}" ]; then
    curl -s -X DELETE "$SUPABASE_URL/rest/v1/notifications?data->>sessionId=eq.$SESSION_ID" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
  fi
  for uid in $UUID_A $UUID_X $UUID_O; do
    curl -s -X DELETE "$SUPABASE_URL/rest/v1/notifications?user_id=eq.$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
  done
  # Invite rows first (FK invitee/creator → users), then the session row the
  # creator opened (its game-state/actions cascade on delete).
  for uid in $UUID_A $UUID_X $UUID_O; do
    curl -s -X DELETE "$SUPABASE_URL/rest/v1/minigame_invites?or=(invitee_id.eq.$uid,created_by.eq.$uid)" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
  done
  if [ -n "${SESSION_ID:-}" ]; then
    curl -s -X DELETE "$SUPABASE_URL/rest/v1/minigame_sessions?id=eq.$SESSION_ID" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
  fi
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/minigame_sessions?participants=cs.%7B$UUID_A%7D" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
  for uid in $UUID_A $UUID_X $UUID_O; do
    curl -s -X DELETE "$SUPABASE_URL/rest/v1/users?id=eq.$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
  done
  for uid in $UUID_A $UUID_X $UUID_O; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT
cleanup

ok()   { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); return 0; }
nok()  { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); return 0; }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

norm_json() {
  sed -E 's/([][,{}:])[[:space:]]+/\1/g; s/[[:space:]]+([][,{}:])/\1/g'
}

# GET the REST path $1 as the bearer token in $2. Prints the normalized body
# to stdout and records the HTTP status in $HTTP_FILE.
auth_get() {
  local t=$1 url=$2 out code body
  out=$(curl -s -w $'\n__HTTP__%{http_code}' -X GET "$SUPABASE_URL/rest/v1/$url" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t")
  code="${out##*__HTTP__}"
  body="${out%$'\n'__HTTP__*}"
  printf '%s' "$code" > "$HTTP_FILE"
  printf '%s' "$body" | norm_json
}

# GET the REST path $1 with the anon apikey only (no user bearer token).
anon_get() {
  local url=$1 out code body
  out=$(curl -s -w $'\n__HTTP__%{http_code}' -X GET "$SUPABASE_URL/rest/v1/$url" \
    -H "apikey: $ANON_KEY")
  code="${out##*__HTTP__}"
  body="${out%$'\n'__HTTP__*}"
  printf '%s' "$code" > "$HTTP_FILE"
  printf '%s' "$body" | norm_json
}

http_code() { cat "$HTTP_FILE"; }
is_array()  { [ "${1:0:1}" = "[" ]; }

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

h1 "SETUP: 3 users (creator A, invitee X, unrelated O)"

for pair in "UUID_A:EMAIL_A" "UUID_X:EMAIL_X" "UUID_O:EMAIL_O"; do
  uid_var="${pair%%:*}"; email_var="${pair##*:}"
  uid="${!uid_var}"; email="${!email_var}"
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  echo "$resp" | grep -q '"id"' && ok "Created auth user ($uid)" || nok "Create user: $(echo "$resp" | head -c 80)"
done

for pair in "UUID_A:user_opt032_a" "UUID_X:user_opt032_x" "UUID_O:user_opt032_o"; do
  uid_var="${pair%%:*}"; uname="${pair##*:}"; uid="${!uid_var}"
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":1000,\"preshards\":10,\"age_confirmed_at\":\"2026-01-01T00:00:00Z\",\"terms_accepted_at\":\"2026-01-01T00:00:00Z\"}" > /dev/null
done
ok "Inserted user rows in public.users"

TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_X=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_X\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_O=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_O\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_X" ] && [ -n "$TOKEN_O" ]; then
  ok "Obtained auth tokens"
else
  nok "Failed to get auth tokens"
fi

# =========================================================================
h1 "TEST 0 — positive control: TOKEN_O is a live, authorized token"
PROFILE_O=$(auth_get "$TOKEN_O" "users?id=eq.$UUID_O&select=id")
CODE_O=$(http_code)
if [ "$CODE_O" = "200" ] && is_array "$PROFILE_O" && printf '%s' "$PROFILE_O" | grep -q "$UUID_O"; then
  ok "Unrelated user O reads its own users row (HTTP 200, non-empty array)"
else
  nok "Positive control failed (HTTP $CODE_O) — O cannot read even its own row; later zero-row results would be meaningless"
fi

h1 "SETUP: A creates a direct session inviting X"
resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" \
  "{\"p_group_id\":null,\"p_game_type\":\"poke_chain\",\"p_invitees\":[\"$UUID_X\"]}")
SESSION_ID=$(echo "$resp" | grep -o '"sessionId":"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -q '"status":"created"' && [ -n "$SESSION_ID" ]; then
  ok "create_minigame_session created a direct session ($SESSION_ID)"
else
  nok "create_minigame_session failed: $(echo "$resp" | head -c 120)"
fi

# Read the invite id as the creator (creator may read their own rows).
INVITE_BODY=$(auth_get "$TOKEN_A" "minigame_invites?session_id=eq.$SESSION_ID&select=id")
INVITE_CODE=$(http_code)
INVITE_ID=$(printf '%s' "$INVITE_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ "$INVITE_CODE" = "200" ] && is_array "$INVITE_BODY" && [ -n "$INVITE_ID" ]; then
  ok "Invite row exists ($INVITE_ID)"
else
  nok "No invite row found (HTTP $INVITE_CODE, body: $(printf '%s' "$INVITE_BODY" | head -c 80))"
fi

# =========================================================================
h1 "TEST A — creator sees the invite they created"
BODY_A=$(auth_get "$TOKEN_A" "minigame_invites?session_id=eq.$SESSION_ID&select=id")
CODE_A=$(http_code)
COUNT_A=$(printf '%s' "$BODY_A" | grep -o '"id":"[^"]*"' | wc -l | tr -d ' ')
HAS_ID_A=0; printf '%s' "$BODY_A" | grep -q "\"id\":\"$INVITE_ID\"" && HAS_ID_A=1
if [ "$CODE_A" != "200" ] || ! is_array "$BODY_A"; then
  nok "Creator read was not a 200 JSON array (HTTP $CODE_A): $(printf '%s' "$BODY_A" | head -c 120)"
elif [ "$COUNT_A" = "1" ] && [ "$HAS_ID_A" = "1" ]; then
  ok "Creator sees exactly its 1 invite ($INVITE_ID)"
elif [ "$COUNT_A" = "1" ]; then
  nok "Creator sees 1 invite but not the expected row (id != $INVITE_ID)"
else
  nok "Creator sees $COUNT_A invites"
fi

# =========================================================================
h1 "TEST B — invitee sees the invite addressed to them"
BODY_X=$(auth_get "$TOKEN_X" "minigame_invites?session_id=eq.$SESSION_ID&select=id")
CODE_X=$(http_code)
COUNT_X=$(printf '%s' "$BODY_X" | grep -o '"id":"[^"]*"' | wc -l | tr -d ' ')
HAS_ID_X=0; printf '%s' "$BODY_X" | grep -q "\"id\":\"$INVITE_ID\"" && HAS_ID_X=1
if [ "$CODE_X" != "200" ] || ! is_array "$BODY_X"; then
  nok "Invitee read was not a 200 JSON array (HTTP $CODE_X): $(printf '%s' "$BODY_X" | head -c 120)"
elif [ "$COUNT_X" = "1" ] && [ "$HAS_ID_X" = "1" ]; then
  ok "Invitee sees exactly its 1 invite ($INVITE_ID)"
elif [ "$COUNT_X" = "1" ]; then
  nok "Invitee sees 1 invite but not the expected row (id != $INVITE_ID)"
else
  nok "Invitee sees $COUNT_X invites"
fi

# =========================================================================
h1 "TEST C — unrelated user sees NO invites (the RLS leak)"
BODY_O=$(auth_get "$TOKEN_O" "minigame_invites?select=id")
CODE_C=$(http_code)
COUNT_O=$(printf '%s' "$BODY_O" | grep -o '"id":"[^"]*"' | wc -l | tr -d ' ')
if [ "$CODE_C" != "200" ] || ! is_array "$BODY_O"; then
  nok "Unrelated read was not a 200 JSON array (HTTP $CODE_C): $(printf '%s' "$BODY_O" | head -c 120)"
elif [ "$COUNT_O" = "0" ]; then
  ok "Unrelated user sees zero invite rows (RLS enforced)"
else
  nok "Unrelated user can read $COUNT_O invite row(s) — RLS LEAK"
fi

BODY_DIRECT=$(auth_get "$TOKEN_O" "minigame_invites?id=eq.$INVITE_ID&select=id")
CODE_DIRECT=$(http_code)
DIRECT_O=$(printf '%s' "$BODY_DIRECT" | grep -o '"id":"[^"]*"' | wc -l | tr -d ' ')
if [ "$CODE_DIRECT" != "200" ] || ! is_array "$BODY_DIRECT"; then
  nok "Unrelated by-id read was not a 200 JSON array (HTTP $CODE_DIRECT)"
elif [ "$DIRECT_O" = "0" ]; then
  ok "Unrelated user cannot fetch the invite by id"
else
  nok "Unrelated user fetched the invite by id — RLS LEAK"
fi

# =========================================================================
h1 "TEST D — unauthenticated (anon) client cannot read invites"
ANON_BODY=$(anon_get "minigame_invites?select=id")
ANON_CODE=$(http_code)
if [ "$ANON_CODE" = "401" ] || [ "$ANON_CODE" = "403" ]; then
  ok "Anon GET /minigame_invites rejected (HTTP $ANON_CODE)"
elif [ "$ANON_CODE" = "200" ] && [ "$ANON_BODY" = "[]" ]; then
  ok "Anon GET returns an empty array (no grant / RLS blocks every row)"
else
  nok "Anon GET /minigame_invites unexpected (HTTP $ANON_CODE): $(printf '%s' "$ANON_BODY" | head -c 120)"
fi

# =========================================================================
h1 "RESULTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo ""; echo "  🎉 All tests passed!"; exit 0; fi
echo ""; echo "  💥 Some tests failed."; exit 1
