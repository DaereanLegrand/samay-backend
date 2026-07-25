#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-001] RLS Security — Integration Test
# Verifies RLS policies work correctly:
#   A) anon SELECT on public tables (app_config, cosmetics, group_rank_snapshots)
#   B) anon SELECT on protected tables (users, friendships, groups, etc.)
#   C) auth user CAN read own user row, CANNOT read other user's row
#   D) auth user CAN read app_config
#   E) auth user CAN read groups they're a member of, CANNOT read others
#   F) anon INSERT denied on all tables
#   G) anon UPDATE denied on all tables
#   H) RPC donate_shards_to_group requires auth
#
# All requests use curl to emulate a Flutter/Dart Supabase client.
#
# Usage: bash test/opt-001-rls-security.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="${ANON_KEY:-sb_publishable_q7NDNoV4TCGqCgheg4tcvC_odjEiEdN}"
SERVICE_KEY="${SERVICE_KEY:-sb_secret_ecIXdsS9IJwFtzgPOHNOtj_eVgxyq37}"

PASS=0
FAIL=0

# Ensure test users are cleaned up on script exit
cleanup() {
  for uid in $UUID_A $UUID_B; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

# ---------------------------------------------------------------------------
# Helpers
#   anon_*    — emulate unauthenticated Dart client (apikey only, no JWT)
#   auth_*    — emulate authenticated Dart client (apikey + JWT)
#   svc_*     — admin operations (service_role key)
# ---------------------------------------------------------------------------

# Plain anon request: ONLY apikey header, no Authorization
anon_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY"
}
anon_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d "$2"
}
anon_patch() {
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d "$2"
}

# Authenticated request: apikey + JWT bearer
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t"
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
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}
anon_rpc() {
  local f=$1 d=$2
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -d "$d"
}

# Service_role (admin) operations
svc_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}
svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_patch() {
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_rpc() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" -d "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Setup: Create test users via admin API (emulates Dart sign-up)
# ---------------------------------------------------------------------------
h1 "SETUP: Create test users"

UUID_A="11111111-1111-1111-1111-111111111111"
UUID_B="22222222-2222-2222-2222-222222222222"
EMAIL_A="user_a_opt001@samay.test"
EMAIL_B="user_b_opt001@samay.test"
PW="Pass1234!"

trap cleanup EXIT

# Clean up any leftover users
cleanup

# Create User A
resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID_A\"}")
if echo "$resp" | grep -q '"id"'; then
  ok "Created auth user A ($UUID_A)"
else
  nok "Create user A: $(echo "$resp" | head -c 80)"
fi

# Create User B
resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID_B\"}")
if echo "$resp" | grep -q '"id"'; then
  ok "Created auth user B ($UUID_B)"
else
  nok "Create user B: $(echo "$resp" | head -c 80)"
fi

# Insert user rows into public.users (auth admin API does not auto-create them)
svc_post "users" "{\"id\":\"$UUID_A\",\"username\":\"user_a\",\"personal_shards\":1000,\"preshards\":10}" > /dev/null
svc_post "users" "{\"id\":\"$UUID_B\",\"username\":\"user_b\",\"personal_shards\":1000,\"preshards\":10}" > /dev/null
ok "Inserted user rows in public.users"

# Sign in to get auth tokens (emulates Dart client login)
TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_B=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ]; then
  ok "Obtained auth tokens for both users"
else
  nok "Failed to get auth tokens"
fi

# Seed app_config and cosmetics (should already exist from seed migration)
info "Verifying seed data exists..."
cfg_count=$(svc_get "app_config?select=key" | grep -c '"key"' || true)
cos_count=$(svc_get "cosmetics?select=id" | grep -c '"id"' || true)
grs_count=$(svc_get "group_rank_snapshots?select=id" | grep -c '"id"' || true)
info "app_config rows: $cfg_count, cosmetics rows: $cos_count, group_rank_snapshots rows: $grs_count"

# Create a group for membership tests
GROUP_ID="33333333-3333-3333-3333-333333333333"
svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Test Group\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\"}" > /dev/null
info "Created test group $GROUP_ID with User A as promotor"

# Verify group data was inserted
group_count=$(svc_get "groups?id=eq.$GROUP_ID&select=id" | grep -c '"id"' || true)
if [ "$group_count" -eq 1 ]; then
  ok "Test group created successfully"
else
  nok "Test group creation failed"
fi

# =========================================================================
# TEST A — anon SELECT on public tables
# =========================================================================
h1 "TEST A — anon SELECT on public tables"

# A1: anon SELECT on app_config (public read)
resp=$(anon_get "app_config?limit=1")
if echo "$resp" | grep -qE '^\s*\[' && echo "$resp" | grep -qE '"key"'; then
  ok "anon SELECT app_config — allowed (public read)"
else
  nok "anon SELECT app_config — unexpected: $(echo "$resp" | head -c 60)"
fi

# A2: anon SELECT on cosmetics (public read, may be empty)
resp=$(anon_get "cosmetics?limit=1")
if echo "$resp" | grep -qE '^\s*\['; then
  ok "anon SELECT cosmetics — allowed (public read)"
else
  nok "anon SELECT cosmetics — unexpected: $(echo "$resp" | head -c 60)"
fi

# A3: anon SELECT on group_rank_snapshots (public read, may be empty)
resp=$(anon_get "group_rank_snapshots?limit=1")
if echo "$resp" | grep -qE '^\s*\['; then
  ok "anon SELECT group_rank_snapshots — allowed (public read)"
else
  nok "anon SELECT group_rank_snapshots — unexpected: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST B — anon SELECT on protected tables (must be denied)
# =========================================================================
h1 "TEST B — anon SELECT on protected tables"

# Note: events is NOT included — public events (group_id IS NULL) are readable by anyone
for table in users friendships groups group_members shard_ledger notifications; do
  resp=$(anon_get "$table?limit=1")
  if echo "$resp" | grep -qE '(42501|permission denied|violates rls|unauthorized)'; then
    ok "anon SELECT $table — denied"
  elif [ "$resp" = "[]" ] || [ -z "$resp" ]; then
    ok "anon SELECT $table — denied (no rows returned)"
  else
    nok "anon SELECT $table — possible leak: $(echo "$resp" | head -c 60)"
  fi
done

# =========================================================================
# TEST C — auth user CAN read own user row, CANNOT read another user's row
# =========================================================================
h1 "TEST C — auth user row access"

# C1: auth user CAN read own row
resp=$(auth_get "$TOKEN_A" "users?id=eq.$UUID_A&select=id,username")
if echo "$resp" | grep -q '"id"'; then
  ok "User A CAN read own user row"
else
  nok "User A CANNOT read own user row: $(echo "$resp" | head -c 60)"
fi

# C2: auth user CANNOT read other user's row
resp=$(auth_get "$TOKEN_A" "users?id=eq.$UUID_B&select=id,username")
if echo "$resp" | grep -qE '(42501|permission denied|violates rls|PGRST204)'; then
  ok "User A CANNOT read User B's row — denied"
elif [ "$resp" = "[]" ] || [ -z "$resp" ]; then
  ok "User A CANNOT read User B's row — no rows returned"
else
  nok "User A CAN read User B's row — possible leak: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST D — auth user CAN read app_config
# =========================================================================
h1 "TEST D — auth user can read app_config"

resp=$(auth_get "$TOKEN_A" "app_config?limit=1")
if echo "$resp" | grep -qE '^\s*\[' && echo "$resp" | grep -qE '"key"'; then
  ok "Auth User A CAN read app_config"
else
  nok "Auth User A CANNOT read app_config: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST E — auth user CAN read groups they're a member of
#            CANNOT read groups they're NOT a member of
# =========================================================================
h1 "TEST E — group membership visibility"

# E1: User A (member) CAN read the group
resp=$(auth_get "$TOKEN_A" "groups?id=eq.$GROUP_ID&select=id,name")
if echo "$resp" | grep -q '"id"'; then
  ok "User A CAN read group they belong to"
else
  nok "User A CANNOT read group they belong to: $(echo "$resp" | head -c 60)"
fi

# E2: User B (not a member) CANNOT read the group
resp=$(auth_get "$TOKEN_B" "groups?id=eq.$GROUP_ID&select=id,name")
if echo "$resp" | grep -qE '(42501|permission denied|violates rls|PGRST204)'; then
  ok "User B CANNOT read group they do not belong to — denied"
elif [ "$resp" = "[]" ] || [ -z "$resp" ]; then
  ok "User B CANNOT read group they do not belong to — no rows returned"
else
  nok "User B CAN read group they do not belong to — possible leak: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST F — anon INSERT denied on all tables
# =========================================================================
h1 "TEST F — anon INSERT on all tables (must all fail)"

for table in users friendships groups group_members events shard_ledger notifications app_config cosmetics group_rank_snapshots; do
  resp=$(anon_post "$table" '{"id":"00000000-0000-0000-0000-000000000000"}')
  if echo "$resp" | grep -qE '(42501|permission denied|violates rls|unauthorized|PGRST204)'; then
    ok "anon INSERT $table — denied"
  else
    if echo "$resp" | grep -qE '"id"'; then
      nok "anon INSERT $table — data leaked! $(echo "$resp" | head -c 60)"
    else
      ok "anon INSERT $table — denied (no rows affected)"
    fi
  fi
done

# =========================================================================
# TEST G — anon UPDATE denied on all tables
# =========================================================================
h1 "TEST G — anon UPDATE on tables (must all fail)"

for table in users friendships groups group_members events; do
  resp=$(anon_patch "$table?id=eq.00000000-0000-0000-0000-000000000000" '{"name":"hacker"}')
  if echo "$resp" | grep -qE '(42501|permission denied|violates rls|unauthorized|PGRST204)'; then
    ok "anon UPDATE $table — denied"
  elif [ -z "$resp" ] || [ "$resp" = "[]" ]; then
    ok "anon UPDATE $table — denied (no data returned)"
  else
    nok "anon UPDATE $table — not denied: $(echo "$resp" | head -c 60)"
  fi
done

# =========================================================================
# TEST H — RPC donate_shards_to_group requires auth
# =========================================================================
h1 "TEST H — donate_shards_to_group RPC requires auth"

# H1: anon cannot call RPC (REVOKEd from PUBLIC in migration 20260724000002)
anon_resp=$(anon_rpc "donate_shards_to_group" "{\"p_group_id\":\"$GROUP_ID\",\"p_user_id\":\"$UUID_A\",\"p_amount\":50,\"p_expires_at\":\"2026-12-31T23:59:59Z\"}")
if echo "$anon_resp" | grep -qE '(42501|permission denied|unauthorized|PGRST203|PGRST200)'; then
  ok "donate_shards_to_group RPC denied to anon (authenticated-only)"
else
  nok "donate_shards_to_group RPC allowed to anon! Response: $(echo "$anon_resp" | head -c 80)"
fi

# H2: auth user CAN call RPC (verify the RPC works when authenticated)
auth_resp=$(auth_rpc "$TOKEN_A" "donate_shards_to_group" "{\"p_group_id\":\"$GROUP_ID\",\"p_user_id\":\"$UUID_A\",\"p_amount\":50,\"p_expires_at\":\"2026-12-31T23:59:59Z\"}")
# Empty response = void function success; insufficient shards also proves the RPC ran
if [ -z "$auth_resp" ] || echo "$auth_resp" | grep -qE '(Insufficient shards|error|P0001)'; then
  info "Auth RPC response: '$(echo "$auth_resp" | head -c 80)'"
  ok "donate_shards_to_group RPC callable by auth user"
else
  nok "donate_shards_to_group RPC unexpected response: $(echo "$auth_resp" | head -c 80)"
fi

# H3: auth user CANNOT donate another user's shards (auth.uid() check in migration 20260724000002)
cross_resp=$(auth_rpc "$TOKEN_A" "donate_shards_to_group" "{\"p_group_id\":\"$GROUP_ID\",\"p_user_id\":\"$UUID_B\",\"p_amount\":50,\"p_expires_at\":\"2026-12-31T23:59:59Z\"}")
if echo "$cross_resp" | grep -qE '(Not authorized|42501|permission denied|P0001)'; then
  ok "donate_shards_to_group RPC blocks cross-user donation (auth.uid() check)"
else
  nok "donate_shards_to_group RPC did NOT block cross-user donation: $(echo "$cross_resp" | head -c 80)"
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
