#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-002] Events — Lifecycle Integration Test
# Verifies the events surface contract (I-76, phase 05 ECRT):
#   A) service_role creates a 'juerga' event with ALL fields
#      (pool / cap / remainder / join_mode / location / status)
#   B) 'casual' + preshards_pool>0 is REJECTED by the DB CHECK constraint
#      check_casual_no_preshards (svc insert -> 23514 error)
#   C) dynamic_qr_enabled is auto-set by the set_dynamic_qr_enabled trigger
#      (BEFORE INSERT OR UPDATE OF preshards_pool; pool>0 -> true)
#   D) RLS read access: non-member CANNOT see a group-scoped event;
#      member CAN; public event (group_id IS NULL) readable by anyone
#   E) promotor insert into event_promotores works (creator branch of
#      ep_insert_promotor, migration 20260809000002 §8); non-creator denied
#   F) update event as promotor works (events_update_promotor); non-promotor
#      update is RLS-filtered away
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup), exactly
# like opt-001. Does NOT depend on seed-dev.sql (SEED_DEV=1). Optionally, a
# SEED_DEV=1 stack could reuse the demo UUIDs (10000000-...) — not needed here.
#
# STATIC-VERIFIED ONLY (this agent run): the stack is not started until the
# checkpoint (AGENT-RULES / port map). Live run: make supabase-docker-start &&
# make supabase-docker-reset && bash test/opt-002-events.sh
#
# Usage: bash test/opt-002-events.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="${ANON_KEY:-sb_publishable_q7NDNoV4TCGqCgheg4tcvC_odjEiEdN}"
SERVICE_KEY="${SERVICE_KEY:-sb_secret_ecIXdsS9IJwFtzgPOHNOtj_eVgxyq37}"

PASS=0
FAIL=0

# Fixed IDs (unique to this file — opt-001 uses 1111.../2222.../3333...).
UUID_A="44444444-4444-4444-4444-444444444444"
UUID_B="44444444-4444-4444-4444-444444444445"
EMAIL_A="user_a_opt002@samay.test"
EMAIL_B="user_b_opt002@samay.test"
PW="Pass1234!"
GROUP_ID="44444444-4444-4444-4444-444444444101"
EV_JUERGA="44444444-4444-4444-4444-444444444201"
EV_GROUP="44444444-4444-4444-4444-444444444202"
EV_BAD="44444444-4444-4444-4444-444444444203"

# Teardown: remove rows this test created (FK-safe order), then auth users.
cleanup() {
  svc_delete_quiet "events?id=in.($EV_JUERGA,$EV_GROUP,$EV_BAD)"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B)"
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
# Helpers — opt-001 pattern (anon_*/auth_*/svc_*).
#   svc_delete_quiet / *_repr are I-76 extensions: delete for teardown and
#   Prefer: return=representation so UPDATE results are inspectable.
# ---------------------------------------------------------------------------
anon_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY"
}
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
auth_patch_repr() {
  local t=$1; shift
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Prefer: return=representation" -d "$2"
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
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Setup: test users + group (A = creator/promotor, B = unrelated outsider)
# ---------------------------------------------------------------------------
h1 "SETUP: users + group"

trap cleanup EXIT
cleanup

resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID_A\"}")
if echo "$resp" | grep -q '"id"'; then ok "Created auth user A ($UUID_A)"; else nok "Create user A: $(echo "$resp" | head -c 80)"; fi

resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID_B\"}")
if echo "$resp" | grep -q '"id"'; then ok "Created auth user B ($UUID_B)"; else nok "Create user B: $(echo "$resp" | head -c 80)"; fi

svc_post "users" "{\"id\":\"$UUID_A\",\"username\":\"user_a_opt002\",\"personal_shards\":1000}" > /dev/null
svc_post "users" "{\"id\":\"$UUID_B\",\"username\":\"user_b_opt002\",\"personal_shards\":1000}" > /dev/null
ok "Inserted user rows in public.users"

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

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Opt002 Group\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\",\"status\":\"active\"}" > /dev/null
ok "Created group $GROUP_ID with User A as promotor member"

# =========================================================================
# TEST A — service_role creates a juerga event with ALL fields
# =========================================================================
h1 "TEST A — svc creates juerga event (all fields)"

JUERGA_PAYLOAD="{\"id\":\"$EV_JUERGA\",\"name\":\"Juerga Opt-002\",\"description\":\"svc-created\",\
\"type\":\"juerga\",\"created_by_user_id\":\"$UUID_A\",\"group_id\":null,\
\"location_name\":\"Av. Test 123\",\"location_lat\":-12.1183,\"location_lng\":-77.0282,\
\"starts_at\":\"2026-12-31T23:00:00Z\",\"ends_at\":\"2027-01-01T05:00:00Z\",\
\"join_mode\":\"open\",\"preshards_pool\":5000,\"preshards_cap_per_user\":250,\
\"preshards_remainder_action\":\"redistribute\",\"dynamic_qr_enabled\":false,\
\"status\":\"upcoming\"}"

resp=$(svc_post "events" "$JUERGA_PAYLOAD")
if [ -z "$resp" ]; then
  ok "svc INSERT events (juerga) accepted"
else
  nok "svc INSERT events (juerga): $(echo "$resp" | head -c 80)"
fi

row=$(svc_get "events?id=eq.$EV_JUERGA&select=id,name,type,join_mode,preshards_pool,preshards_cap_per_user,preshards_remainder_action,invite_token,status")
if echo "$row" | grep -q '"id"' && echo "$row" | grep -q '"preshards_cap_per_user":250' \
   && echo "$row" | grep -q '"preshards_remainder_action":"redistribute"' \
   && echo "$row" | grep -q '"invite_token"'; then
  ok "Juerga row persisted with pool/cap/remainder/invite_token/status"
else
  nok "Juerga row incomplete: $(echo "$row" | head -c 120)"
fi

# =========================================================================
# TEST B — casual + pool>0 rejected by DB CHECK (svc insert -> error)
# =========================================================================
h1 "TEST B — casual + preshards_pool>0 rejected (check_casual_no_preshards)"

resp=$(svc_post "events" "{\"id\":\"$EV_BAD\",\"name\":\"Bad Casual\",\"type\":\"casual\",\
\"created_by_user_id\":\"$UUID_A\",\"starts_at\":\"2026-12-31T23:00:00Z\",\
\"ends_at\":\"2027-01-01T05:00:00Z\",\"preshards_pool\":100}")
if echo "$resp" | grep -qE '(23514|check_casual_no_preshards|violates check)'; then
  ok "casual + pool>0 rejected by CHECK constraint"
else
  nok "casual + pool>0 NOT rejected: $(echo "$resp" | head -c 80)"
fi
leftover=$(svc_get "events?id=eq.$EV_BAD&select=id")
if [ "$leftover" = "[]" ] || [ -z "$leftover" ]; then
  ok "Rejected event not persisted"
else
  nok "Rejected event leaked into DB: $leftover"
fi

# =========================================================================
# TEST C — dynamic_qr_enabled auto-set by trigger (pool>0 -> true)
# =========================================================================
h1 "TEST C — dynamic_qr_enabled trigger (BEFORE INSERT OR UPDATE OF preshards_pool)"

qr=$(svc_get "events?id=eq.$EV_JUERGA&select=dynamic_qr_enabled")
if echo "$qr" | grep -q '"dynamic_qr_enabled":true'; then
  ok "Juerga (pool=5000, explicit false) stored with dynamic_qr_enabled=true (trigger)"
else
  nok "dynamic_qr_enabled not auto-set to true: $qr"
fi

svc_post "events" "{\"id\":\"$EV_GROUP\",\"name\":\"Casual Opt-002\",\"type\":\"casual\",\
\"created_by_user_id\":\"$UUID_A\",\"group_id\":\"$GROUP_ID\",\"join_mode\":\"approval\",\
\"starts_at\":\"2026-12-31T23:00:00Z\",\"ends_at\":\"2027-01-01T02:00:00Z\",\
\"preshards_pool\":0,\"status\":\"upcoming\"}" > /dev/null
qr=$(svc_get "events?id=eq.$EV_GROUP&select=dynamic_qr_enabled")
if echo "$qr" | grep -q '"dynamic_qr_enabled":false'; then
  ok "Casual (pool=0) stored with dynamic_qr_enabled=false (trigger)"
else
  nok "dynamic_qr_enabled should be false for pool=0: $qr"
fi

# =========================================================================
# TEST D — RLS read access on events (group-scoped vs public)
# =========================================================================
h1 "TEST D — event visibility (events_read_access)"

resp=$(auth_get "$TOKEN_B" "events?id=eq.$EV_GROUP&select=id,name")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Non-member B CANNOT read group-scoped event"
else
  nok "Non-member B CAN read group-scoped event: $(echo "$resp" | head -c 60)"
fi

resp=$(auth_get "$TOKEN_A" "events?id=eq.$EV_GROUP&select=id,name")
if echo "$resp" | grep -q '"id"'; then
  ok "Member A CAN read group-scoped event"
else
  nok "Member A CANNOT read group-scoped event: $(echo "$resp" | head -c 60)"
fi

resp=$(auth_get "$TOKEN_B" "events?id=eq.$EV_JUERGA&select=id,name")
if echo "$resp" | grep -q '"id"'; then
  ok "B CAN read public event (group_id IS NULL branch)"
else
  nok "B CANNOT read public event: $(echo "$resp" | head -c 60)"
fi

resp=$(anon_get "events?id=eq.$EV_JUERGA&select=id")
if echo "$resp" | grep -q '"id"'; then
  ok "anon CAN read public event (group_id IS NULL branch)"
else
  nok "anon CANNOT read public event: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST E — event_promotores insert (creator branch, ep_insert_promotor)
# =========================================================================
h1 "TEST E — promotor insert into event_promotores"

resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/event_promotores" -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $TOKEN_A" -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "{\"event_id\":\"$EV_JUERGA\",\"user_id\":\"$UUID_A\",\"role\":\"promotor\"}")
if [ -z "$resp" ]; then
  ok "Creator A inserted own event_promotores row (ep_insert_promotor creator branch)"
else
  nok "Creator A promotor insert failed: $(echo "$resp" | head -c 80)"
fi
cnt=$(svc_get "event_promotores?event_id=eq.$EV_JUERGA&user_id=eq.$UUID_A&select=id" | grep -c '"id"' || true)
if [ "$cnt" -ge 1 ]; then
  ok "event_promotores row persisted"
else
  nok "event_promotores row missing"
fi

resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/event_promotores" -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $TOKEN_B" -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "{\"event_id\":\"$EV_JUERGA\",\"user_id\":\"$UUID_B\",\"role\":\"co_promotor\"}")
if echo "$resp" | grep -qE '(42501|violates row-level security|PGRST)'; then
  ok "Non-creator B CANNOT insert promotor row (RLS)"
else
  nok "Non-creator B promotor insert NOT denied: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
# TEST F — update event as promotor works; non-promotor filtered
# =========================================================================
h1 "TEST F — event update (events_update_promotor)"

resp=$(auth_patch_repr "$TOKEN_A" "events?id=eq.$EV_JUERGA" '{"name":"Juerga Opt-002 Renamed"}')
if echo "$resp" | grep -q '"name":"Juerga Opt-002 Renamed"'; then
  ok "Promotor A CAN update event name"
else
  nok "Promotor A update failed: $(echo "$resp" | head -c 80)"
fi

# Trigger fires on UPDATE OF preshards_pool: 5000 -> 0 -> dynamic_qr false.
resp=$(auth_patch_repr "$TOKEN_A" "events?id=eq.$EV_JUERGA" '{"preshards_pool":0}')
qr=$(svc_get "events?id=eq.$EV_JUERGA&select=dynamic_qr_enabled")
if echo "$qr" | grep -q '"dynamic_qr_enabled":false'; then
  ok "Promotor A pool update 5000->0 flipped dynamic_qr_enabled to false (trigger)"
else
  nok "dynamic_qr_enabled not false after pool->0: $qr"
fi
resp=$(auth_patch_repr "$TOKEN_A" "events?id=eq.$EV_JUERGA" '{"preshards_pool":5000}')
qr=$(svc_get "events?id=eq.$EV_JUERGA&select=dynamic_qr_enabled")
if echo "$qr" | grep -q '"dynamic_qr_enabled":true'; then
  ok "Promotor A pool update 0->5000 flipped dynamic_qr_enabled to true (trigger)"
else
  nok "dynamic_qr_enabled not true after pool->5000: $qr"
fi

resp=$(auth_patch_repr "$TOKEN_B" "events?id=eq.$EV_JUERGA" '{"name":"Hacked"}')
if [ "$resp" = "[]" ] || [ -z "$resp" ] || echo "$resp" | grep -qE '(42501|permission denied)'; then
  ok "Non-promotor B UPDATE is RLS-filtered (no rows affected)"
else
  nok "Non-promotor B UPDATE not blocked: $(echo "$resp" | head -c 80)"
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
