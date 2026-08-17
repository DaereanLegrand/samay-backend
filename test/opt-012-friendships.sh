#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-012] Friendships — Integration Test
# Verifies friendship RLS policies and RPC behavior:
#   A) anon cannot read friendships
#   B) auth user can send friend request (INSERT)
#   C) auth user can read own friendships
#   D) auth user cannot read other user's friendships
#   E) auth user can accept friend request (accept_friend_request RPC)
#   F) auth user can decline friend request (DELETE)
#   G) auth user can block user (UPDATE status = 'blocked')
#   H) auth user can unblock user (DELETE)
#
# Usage: bash test/opt-012-friendships.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="${ANON_KEY:-eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9.eyJyb2xlIjogImFub24iLCAiaXNzIjogInN1cGFiYXNlIiwgImlhdCI6IDE3ODY0ODU4OTMsICJleHAiOiAxODE4MDIxODkzfQ.YR0NRqrTGXY6JibsjhLEkC7EE1T83b887bCqaZd834Y}"
SERVICE_KEY="${SERVICE_KEY:-eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9.eyJyb2xlIjogInNlcnZpY2Vfcm9sZSIsICJpc3MiOiAic3VwYWJhc2UiLCAiaWF0IjogMTc4NjQ4NTg5MywgImV4cCI6IDE4MTgwMjE4OTN9.MmYGQ6z0OW7MvKkoYaWLpDBN1AkNdElvpF_DqX7baWM}"

PASS=0
FAIL=0

cleanup() {
  for uid in $UUID_A $UUID_B $UUID_C; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

# --- Helpers ---

anon_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY"
}

auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t"
}

auth_post() {
  local t=$1; shift
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$2"
}

auth_patch() {
  local t=$1; shift
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
}

auth_delete() {
  local t=$1; shift
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Prefer: return=minimal"
}

auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}

anon_rpc() {
  local f=$1 d=$2
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -d "$d"
}

svc_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
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

h1 "SETUP: Create test users"

UUID_A="44444444-4444-4444-4444-444444444444"
UUID_B="55555555-5555-5555-5555-555555555555"
UUID_C="66666666-6666-6666-6666-666666666666"
EMAIL_A="user_a_opt012@samay.test"
EMAIL_B="user_b_opt012@samay.test"
EMAIL_C="user_c_opt012@samay.test"
PW="Pass1234!"

trap cleanup EXIT
cleanup

for pair in "UUID_A:EMAIL_A" "UUID_B:EMAIL_B" "UUID_C:EMAIL_C"; do
  uid_var="${pair%%:*}"
  email_var="${pair##*:}"
  uid="${!uid_var}"
  email="${!email_var}"
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if echo "$resp" | grep -q '"id"'; then
    ok "Created auth user ($uid)"
  else
    nok "Create user: $(echo "$resp" | head -c 80)"
  fi
done

# Insert user rows into public.users
for pair in "UUID_A:user_a" "UUID_B:user_b" "UUID_C:user_c"; do
  uid_var="${pair%%:*}"
  uname="${pair##*:}"
  uid="${!uid_var}"
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"personal_shards\":1000,\"preshards\":10}" > /dev/null
done
ok "Inserted user rows in public.users"

# Sign in to get auth tokens
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
  ok "Obtained auth tokens for all three users"
else
  nok "Failed to get auth tokens"
fi

# Cleanup any pre-existing friendships
svc_delete "friendships?requester_id=eq.$UUID_A" > /dev/null 2>&1 || true
svc_delete "friendships?requester_id=eq.$UUID_B" > /dev/null 2>&1 || true
svc_delete "friendships?requester_id=eq.$UUID_C" > /dev/null 2>&1 || true
info "Cleaned up pre-existing friendships"

# =========================================================================
# TEST A — anon cannot read friendships
# =========================================================================
h1 "TEST A — anon cannot read friendships"

resp=$(anon_get "friendships?limit=1")
if echo "$resp" | grep -qE '(42501|permission denied|violates rls|unauthorized)'; then
  ok "anon SELECT friendships — denied"
elif [ "$resp" = "[]" ] || [ -z "$resp" ]; then
  ok "anon SELECT friendships — denied (no rows returned)"
else
  nok "anon SELECT friendships — possible leak: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST B — auth user can send friend request
# =========================================================================
h1 "TEST B — auth user can send friend request"

resp=$(auth_post "$TOKEN_A" "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_B\",\"status\":\"pending\"}")
if echo "$resp" | grep -qE '"id"'; then
  FRIENDSHIP_ID=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  ok "User A sent friend request to User B (friendship $FRIENDSHIP_ID)"
else
  nok "User A cannot send friend request: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
# TEST C — auth user can read own friendships
# =========================================================================
h1 "TEST C — auth user can read own friendships"

resp=$(auth_get "$TOKEN_A" "friendships?select=id,status,requester_id,addressee_id")
if echo "$resp" | grep -q '"requester_id"'; then
  ok "User A can read own friendships"
else
  nok "User A cannot read own friendships: $(echo "$resp" | head -c 60)"
fi

# User B (addressee) should also see the friendship
resp=$(auth_get "$TOKEN_B" "friendships?select=id,status,requester_id,addressee_id")
if echo "$resp" | grep -q '"requester_id"'; then
  ok "User B (addressee) can read own friendships"
else
  nok "User B cannot read own friendships: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST D — auth user cannot read other user's friendships
# =========================================================================
h1 "TEST D — auth user cannot read other user's friendships"

resp=$(auth_get "$TOKEN_C" "friendships?select=id")
if echo "$resp" | grep -qE '(42501|permission denied|violates rls|PGRST204)'; then
  ok "User C cannot read A-B friendships — denied"
elif [ "$resp" = "[]" ] || [ -z "$resp" ]; then
  ok "User C cannot read A-B friendships — no rows returned"
else
  nok "User C CAN read A-B friendships — possible leak: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST E — auth user can accept friend request
# =========================================================================
h1 "TEST E — auth user can accept friend request"

if [ -z "$FRIENDSHIP_ID" ]; then
  nok "SKIP: no friendship ID from test B"
else
  resp=$(auth_rpc "$TOKEN_B" "accept_friend_request" "{\"p_friendship_id\":\"$FRIENDSHIP_ID\"}")
  # Empty response = void function success
  if [ -z "$resp" ]; then
    ok "User B accepted friend request via RPC"
  else
    nok "accept_friend_request RPC failed: $(echo "$resp" | head -c 80)"
  fi

  # Verify status changed to 'accepted'
  resp=$(auth_get "$TOKEN_A" "friendships?id=eq.$FRIENDSHIP_ID&select=status")
  if echo "$resp" | grep -q '"accepted"'; then
    ok "Friendship status updated to 'accepted'"
  else
    nok "Friendship status not updated: $(echo "$resp" | head -c 60)"
  fi
fi

# =========================================================================
# TEST F — auth user can decline friend request
# =========================================================================
h1 "TEST F — auth user can decline friend request"

# User A sends a new request to User C
resp=$(auth_post "$TOKEN_A" "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"pending\"}")
if echo "$resp" | grep -qE '"id"'; then
  DECLINE_ID=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  ok "User A sent friend request to User C ($DECLINE_ID)"
else
  nok "User A cannot send friend request to User C: $(echo "$resp" | head -c 80)"
  DECLINE_ID=""
fi

if [ -n "$DECLINE_ID" ]; then
  # User C declines (deletes) the request
  resp=$(auth_delete "$TOKEN_C" "friendships?id=eq.$DECLINE_ID")
  # Empty response = success with Prefer: return=minimal
  if [ -z "$resp" ]; then
    ok "User C declined (deleted) friend request"
  else
    nok "User C cannot decline friend request: $(echo "$resp" | head -c 80)"
  fi

  # Verify the friendship is gone
  resp=$(auth_get "$TOKEN_A" "friendships?id=eq.$DECLINE_ID&select=id")
  if [ "$resp" = "[]" ] || [ -z "$resp" ]; then
    ok "Declined friendship removed"
  else
    nok "Declined friendship still exists: $(echo "$resp" | head -c 60)"
  fi
fi

# =========================================================================
# TEST G — auth user can block user
# =========================================================================
h1 "TEST G — auth user can block user"

# Create a new pending request from A to C for blocking
resp=$(auth_post "$TOKEN_A" "friendships" "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_C\",\"status\":\"pending\"}")
if echo "$resp" | grep -qE '"id"'; then
  BLOCK_ID=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  ok "User A sent friend request to User C for blocking ($BLOCK_ID)"
else
  nok "User A cannot send friend request to User C: $(echo "$resp" | head -c 80)"
  BLOCK_ID=""
fi

if [ -n "$BLOCK_ID" ]; then
  # User A blocks User C by updating status to 'blocked'
  resp=$(auth_patch "$TOKEN_A" "friendships?id=eq.$BLOCK_ID" '{"status":"blocked"}')
  if [ -z "$resp" ]; then
    ok "User A blocked User C (status = 'blocked')"
  else
    nok "User A cannot block User C: $(echo "$resp" | head -c 80)"
  fi

  # Verify status is 'blocked'
  resp=$(auth_get "$TOKEN_A" "friendships?id=eq.$BLOCK_ID&select=status")
  if echo "$resp" | grep -q '"blocked"'; then
    ok "Friendship status updated to 'blocked'"
  else
    nok "Friendship status not blocked: $(echo "$resp" | head -c 60)"
  fi
fi

# =========================================================================
# TEST H — auth user can unblock user
# =========================================================================
h1 "TEST H — auth user can unblock user"

if [ -z "$BLOCK_ID" ]; then
  nok "SKIP: no blocked friendship ID from test G"
else
  # User A unblocks User C by deleting the blocked friendship
  resp=$(auth_delete "$TOKEN_A" "friendships?id=eq.$BLOCK_ID")
  if [ -z "$resp" ]; then
    ok "User A unblocked User C (deleted blocked friendship)"
  else
    nok "User A cannot unblock User C: $(echo "$resp" | head -c 80)"
  fi

  # Verify the friendship is gone
  resp=$(auth_get "$TOKEN_A" "friendships?id=eq.$BLOCK_ID&select=id")
  if [ "$resp" = "[]" ] || [ -z "$resp" ]; then
    ok "Blocked friendship removed"
  else
    nok "Blocked friendship still exists: $(echo "$resp" | head -c 60)"
  fi
fi

# =========================================================================
# Summary
# =========================================================================
h1 "RESULTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "  🎉 All tests passed!"
  exit 0
else
  echo ""
  echo "  💥 Some tests failed."
  exit 1
fi
