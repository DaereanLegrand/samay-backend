#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-006] E2EE — fetch_prekey_bundle RPC contract (migration 20260809000003)
# Verifies the server-side prekey distribution contract
# (E2EE-ARCHITECTURE.md §5.4/§9.3, I-38):
#   A) identity bundle row insert into e2ee_identity_keys (svc setup —
#      service_role BYPASSRLS, own-row policies otherwise apply)
#   B) fetch_prekey_bundle via auth_rpc as an authenticated peer: bundle
#      returned with identity_key / identity_sig_key / signed_prekey_* and
#      one one-time prekey
#   C) one-time prekey CONSUMED atomically: a second fetch returns the next
#      OPK, the row's one_time_prekeys shrinks (2 -> 1 -> 0) and
#      consumed_one_time_prekeys grows
#   D) exhausted bundle: further fetches still return the identity keys with
#      one_time_prekey = null (never an error, never a reused OPK)
#   E) anon CANNOT call the RPC (EXECUTE revoked from PUBLIC, granted to
#      authenticated only) -> PGRST203 / permission denied
#   F) RLS own-row: user reads own e2ee_identity_keys row; another user
#      CANNOT (e2ee_identity_keys_select_own)
#
# NOTE: the caller must be an authenticated user (JWT), so the test creates
# real auth.users rows via the admin API exactly like opt-001. The bundle
# owner and the fetcher are distinct users — the realistic X3DH flow.
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup), exactly
# like opt-001. Does NOT depend on seed-dev.sql (SEED_DEV=1).
#
# STATIC-VERIFIED ONLY (this agent run): the stack is not started until the
# checkpoint (AGENT-RULES / port map). Live run: make supabase-docker-start &&
# make supabase-docker-reset && bash test/opt-006-e2ee-rpc.sh
#
# Usage: bash test/opt-006-e2ee-rpc.sh
#
# Keys (M-03 alignment): ANON_KEY / SERVICE_KEY default to the DEV values
# from supabase/.env — dev-only; CI/checkpoint overrides them via env vars.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="${ANON_KEY:-sb_publishable_q7NDNoV4TCGqCgheg4tcvC_odjEiEdN}"
SERVICE_KEY="${SERVICE_KEY:-sb_service_role_key_change_in_production}"

PASS=0
FAIL=0

# Fixed IDs (unique to this file).
UUID_A="77777777-7777-7777-7777-777777777777"   # bundle owner
UUID_B="77777777-7777-7777-7777-777777777778"   # authenticated fetcher
EMAIL_A="user_a_opt006@samay.test"
EMAIL_B="user_b_opt006@samay.test"
PW="Pass1234!"

# base64url public keys (opaque to the server — only shape matters)
IK="AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiM"
IK_SIG="BAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYn"
SPK="AwMDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMk"
SPK_SIG="BwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkq"
OTPK_1="CQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKis"
OTPK_2="DA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v"

cleanup() {
  svc_delete_quiet "e2ee_identity_keys?user_id=eq.$UUID_A"
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

anon_rpc() {
  local f=$1 d=$2
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -d "$d"
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t"
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

# Count one-time prekeys in the row's jsonb array (each OPK is {"id":N,...}).
opk_count() {
  svc_get "e2ee_identity_keys?user_id=eq.$UUID_A&select=one_time_prekeys" | grep -o '"id"' | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Setup: two real auth users (owner + fetcher)
# ---------------------------------------------------------------------------
h1 "SETUP: auth users (bundle owner A, fetcher B)"

trap cleanup EXIT
cleanup

for pair in "A $UUID_A user_a_opt006 $EMAIL_A" "B $UUID_B user_b_opt006 $EMAIL_B"; do
  set -- $pair
  name=$1; uid=$2; uname=$3; email=$4
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if echo "$resp" | grep -q '"id"'; then ok "Created auth user $name ($uid)"; else nok "Create user $name: $(echo "$resp" | head -c 80)"; fi
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"personal_shards\":1000}" > /dev/null
done
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

# =========================================================================
# TEST A — publish identity bundle (svc insert into e2ee_identity_keys)
# =========================================================================
h1 "TEST A — bundle publish (e2ee_identity_keys row)"

resp=$(svc_post "e2ee_identity_keys" "{\"user_id\":\"$UUID_A\",\"identity_key\":\"$IK\",\
\"identity_sig_key\":\"$IK_SIG\",\"signed_prekey_id\":1,\"signed_prekey\":\"$SPK\",\
\"signed_prekey_sig\":\"$SPK_SIG\",\"signed_prekey_expires_at\":\"2026-09-01T00:00:00Z\",\
\"one_time_prekeys\":[{\"id\":1,\"key\":\"$OTPK_1\"},{\"id\":2,\"key\":\"$OTPK_2\"}]}")
if [ -z "$resp" ]; then
  ok "e2ee_identity_keys insert accepted (service role)"
else
  nok "e2ee_identity_keys insert: $(echo "$resp" | head -c 80)"
fi
row=$(svc_get "e2ee_identity_keys?user_id=eq.$UUID_A&select=identity_key,identity_sig_key,signed_prekey_id,signed_prekey,signed_prekey_sig")
if echo "$row" | grep -q "\"identity_key\":\"$IK\"" && echo "$row" | grep -q '"signed_prekey_id":1' \
   && echo "$row" | grep -q "\"signed_prekey\":\"$SPK\""; then
  ok "Bundle row persisted (identity + signed prekey)"
else
  nok "Bundle row wrong: $(echo "$row" | head -c 120)"
fi
before=$(opk_count)
if [ "$before" = "2" ]; then
  ok "Row carries 2 one-time prekeys"
else
  nok "Expected 2 OTPKs, found $before"
fi

# =========================================================================
# TEST B — fetch_prekey_bundle via auth_rpc (authenticated peer)
# =========================================================================
h1 "TEST B — auth peer fetches bundle"

resp=$(auth_rpc "$TOKEN_B" "fetch_prekey_bundle" "{\"p_user_id\":\"$UUID_A\"}")
if echo "$resp" | grep -q "\"identity_key\":\"$IK\"" \
   && echo "$resp" | grep -q "\"identity_sig_key\":\"$IK_SIG\"" \
   && echo "$resp" | grep -q '"signed_prekey_id":1' \
   && echo "$resp" | grep -q '"one_time_prekey"'; then
  ok "Bundle returned: identity keys + signed prekey + one_time_prekey"
else
  nok "Bundle response wrong: $(echo "$resp" | head -c 160)"
fi

# =========================================================================
# TEST C — one-time prekey consumed atomically (2 -> 1 -> 0)
# =========================================================================
h1 "TEST C — atomic OPK consumption"

after1=$(opk_count)
if [ "$after1" = "1" ]; then
  ok "1 OPK consumed by the fetch (2 -> 1)"
else
  nok "Expected 1 OTPK remaining after fetch, found $after1"
fi

resp2=$(auth_rpc "$TOKEN_B" "fetch_prekey_bundle" "{\"p_user_id\":\"$UUID_A\"}")
if echo "$resp2" | grep -q '"one_time_prekey":{'; then
  ok "Second fetch returned the next (2nd) one-time prekey"
else
  nok "Second fetch wrong: $(echo "$resp2" | head -c 120)"
fi
after2=$(opk_count)
if [ "$after2" = "0" ]; then
  ok "2nd OPK consumed (1 -> 0)"
else
  nok "Expected 0 OTPKs remaining, found $after2"
fi
consumed=$(svc_get "e2ee_identity_keys?user_id=eq.$UUID_A&select=consumed_one_time_prekeys" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$consumed" = "2" ]; then
  ok "consumed_one_time_prekeys audit list holds both OPKs"
else
  nok "Expected 2 consumed OPKs, found $consumed"
fi

# =========================================================================
# TEST D — exhausted bundle: identity keys still served, OPK = null
# =========================================================================
h1 "TEST D — exhausted OPK pool"

resp3=$(auth_rpc "$TOKEN_B" "fetch_prekey_bundle" "{\"p_user_id\":\"$UUID_A\"}")
if echo "$resp3" | grep -q "\"identity_key\":\"$IK\"" && echo "$resp3" | grep -q '"one_time_prekey":null'; then
  ok "Exhausted fetch: identity keys returned, one_time_prekey null (no OPK reuse)"
else
  nok "Exhausted fetch wrong: $(echo "$resp3" | head -c 120)"
fi

# =========================================================================
# TEST E — anon CANNOT call the RPC (REVOKE PUBLIC / authenticated-only)
# =========================================================================
h1 "TEST E — anon denied"

resp=$(anon_rpc "fetch_prekey_bundle" "{\"p_user_id\":\"$UUID_A\"}")
if echo "$resp" | grep -qE '(PGRST203|permission denied|42501|unauthorized|404)'; then
  ok "anon call denied (EXECUTE revoked from PUBLIC)"
else
  nok "anon call NOT denied: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
# TEST F — RLS own-row on e2ee_identity_keys
# =========================================================================
h1 "TEST F — e2ee_identity_keys own-row RLS"

resp=$(auth_get "$TOKEN_A" "e2ee_identity_keys?user_id=eq.$UUID_A&select=identity_key")
if echo "$resp" | grep -q "\"identity_key\":\"$IK\""; then
  ok "Owner A CAN read own bundle row (select_own)"
else
  nok "Owner A CANNOT read own row: $(echo "$resp" | head -c 80)"
fi

resp=$(auth_get "$TOKEN_B" "e2ee_identity_keys?user_id=eq.$UUID_A&select=identity_key")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Fetcher B CANNOT read A's bundle row directly (RLS — RPC is the only path)"
else
  nok "B CAN read A's bundle row directly: $(echo "$resp" | head -c 80)"
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
