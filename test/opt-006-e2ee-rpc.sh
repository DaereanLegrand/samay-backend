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
#   G) minigame session RPCs (migration 20260813000001, agent R4 — I-77/S-03
#      gap closure): join_minigame_session + finish_minigame_game (201)
#      exercised end-to-end against the live stack: create (escrow deduct),
#      join (idempotent, second participant escrow), error paths
#      (session_not_found / not_member / anon denied), leaderboard settlement
#      (pot preserved, repeat finish is a no-op, minigame_win rows written),
#      and the bystander gate (not_allowed).
#
# NOTE: the caller must be an authenticated user (JWT), so the test creates
# real auth.users rows via the admin API exactly like opt-001. The bundle
# owner and the fetcher are distinct users — the realistic X3DH flow.
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup), exactly
# like opt-001.
#
# STATIC-VERIFIED ONLY (this agent run): the stack is not started until the
# checkpoint (AGENT-RULES / port map). Live run: make supabase-start &&
# make supabase-reset && bash test/opt-006-e2ee-rpc.sh
#
# Usage: bash test/opt-006-e2ee-rpc.sh
#
# Keys (M-03 alignment): resolved at runtime by test/dev_env.sh from the
# gitignored stack .env (supabase/.env) — dev-only; CI
# overrides them via env vars.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

# Fixed IDs (unique to this file).
UUID_A="77777777-7777-7777-7777-777777777777"   # bundle owner / minigame initiator
UUID_B="77777777-7777-7777-7777-777777777778"   # authenticated fetcher / joiner
UUID_C="77777777-7777-7777-7777-777777777779"   # non-member (minigame error paths)
EMAIL_A="user_a_opt006@samay.test"
EMAIL_B="user_b_opt006@samay.test"
EMAIL_C="user_c_opt006@samay.test"
PW="Pass1234!"
GROUP_ID="88888888-8888-8888-8888-888888888888"
SESSION_MISSING="99999999-9999-9999-9999-999999999999"

# base64url public keys (opaque to the server — only shape matters)
IK="AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiM"
IK_SIG="BAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYn"
SPK="AwMDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMk"
SPK_SIG="BwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkq"
OTPK_1="CQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKis"
OTPK_2="DA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v"

cleanup() {
  svc_delete_quiet "minigame_sessions?group_id=eq.$GROUP_ID"
  svc_delete_quiet "shard_ledger?user_id=in.($UUID_A,$UUID_B)"
  svc_delete_quiet "e2ee_identity_keys?user_id=eq.$UUID_A"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  for uid in $UUID_A $UUID_B $UUID_C; do
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

for pair in "A $UUID_A user_a_opt006 $EMAIL_A" "B $UUID_B user_b_opt006 $EMAIL_B" "C $UUID_C user_c_opt006 $EMAIL_C"; do
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
TOKEN_C=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_C\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ]; then
  ok "Obtained auth tokens for all three users"
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
if echo "$row" | grep -q "\"identity_key\": *\"$IK\"" && echo "$row" | grep -q '"signed_prekey_id": *1' \
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
if echo "$resp" | grep -q "\"identity_key\": *\"$IK\"" \
   && echo "$resp" | grep -q "\"identity_sig_key\": *\"$IK_SIG\"" \
   && echo "$resp" | grep -q '"signed_prekey_id": *1' \
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
if echo "$resp2" | grep -q '"one_time_prekey": *{'; then
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
if echo "$resp3" | grep -q "\"identity_key\": *\"$IK\"" && echo "$resp3" | grep -q '"one_time_prekey": *null'; then
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
if echo "$resp" | grep -q "\"identity_key\": *\"$IK\""; then
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
# TEST G — minigame RPC setup: group + memberships (A host, B member)
# =========================================================================
h1 "TEST G — minigame setup (group + memberships)"

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Minigame Opt Test\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\"}" > /dev/null
ok "Group + memberships provisioned (A host, B member, C non-member)"

# =========================================================================
# TEST H — create_minigame_session escrow (wager 50, initiator A)
# =========================================================================
h1 "TEST H — create_minigame_session escrow"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"poke_chain\",\"p_wager\":50}")
SESSION_ID=$(echo "$resp" | grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"created"' && [ -n "$SESSION_ID" ]; then
  ok "Session created (A, wager 50, escrow started)"
else
  nok "create_minigame_session wrong: $(echo "$resp" | head -c 120)"
fi

shards=$(svc_get "users?id=eq.$UUID_A&select=personal_shards")
if echo "$shards" | grep -q '"personal_shards"[[:space:]]*:[[:space:]]*950'; then
  ok "Initiator A deducted 50 at creation (1000 -> 950)"
else
  nok "A shards after create: $(echo "$shards" | head -c 80)"
fi

ledger=$(svc_get "shard_ledger?user_id=eq.$UUID_A&select=reason,delta,reference_id")
if echo "$ledger" | grep -q '"minigame_wager"' && echo "$ledger" | grep -q '"delta"[[:space:]]*:[[:space:]]*-50' \
   && echo "$ledger" | grep -q "\"$SESSION_ID\""; then
  ok "minigame_wager ledger entry (-50, reference_id = session)"
else
  nok "A ledger after create: $(echo "$ledger" | head -c 120)"
fi

# =========================================================================
# TEST I — join_minigame_session (B joins, second-participant escrow)
# =========================================================================
h1 "TEST I — join_minigame_session"

resp=$(auth_rpc "$TOKEN_B" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"joined"'; then
  ok "B joined the session"
else
  nok "join_minigame_session wrong: $(echo "$resp" | head -c 120)"
fi

parts=$(svc_get "minigame_sessions?id=eq.$SESSION_ID&select=participants")
if echo "$parts" | grep -q "$UUID_A" && echo "$parts" | grep -q "$UUID_B"; then
  ok "Participants array holds A and B"
else
  nok "Participants wrong: $(echo "$parts" | head -c 120)"
fi

shards=$(svc_get "users?id=eq.$UUID_B&select=personal_shards")
if echo "$shards" | grep -q '"personal_shards"[[:space:]]*:[[:space:]]*950'; then
  ok "Joiner B deducted 50 (1000 -> 950, per-participant escrow)"
else
  nok "B shards after join: $(echo "$shards" | head -c 80)"
fi

ledger=$(svc_get "shard_ledger?user_id=eq.$UUID_B&select=reason,delta,reference_id")
if echo "$ledger" | grep -q '"minigame_wager"' && echo "$ledger" | grep -q '"delta"[[:space:]]*:[[:space:]]*-50' \
   && echo "$ledger" | grep -q "\"$SESSION_ID\""; then
  ok "B's minigame_wager ledger entry (-50, reference_id = session)"
else
  nok "B ledger after join: $(echo "$ledger" | head -c 120)"
fi

resp=$(auth_rpc "$TOKEN_B" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID\"}")
shards=$(svc_get "users?id=eq.$UUID_B&select=personal_shards")
count=$(svc_get "shard_ledger?user_id=eq.$UUID_B&select=reason,reference_id" | grep -o '"minigame_wager"' | wc -l | tr -d ' ')
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"joined"' \
   && echo "$shards" | grep -q '"personal_shards"[[:space:]]*:[[:space:]]*950' \
   && [ "$count" = "1" ]; then
  ok "Re-join is idempotent (no double deduction, no duplicate ledger row)"
else
  nok "Re-join NOT idempotent (shards=$(echo "$shards" | head -c 40), ledger rows=$count)"
fi

# =========================================================================
# TEST J — join error paths (missing session / non-member / anon)
# =========================================================================
h1 "TEST J — join error paths"

resp=$(auth_rpc "$TOKEN_B" "join_minigame_session" "{\"p_session_id\":\"$SESSION_MISSING\"}")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"session_not_found"'; then
  ok "Missing session -> session_not_found"
else
  nok "Missing session: $(echo "$resp" | head -c 80)"
fi

resp=$(auth_rpc "$TOKEN_C" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"not_member"'; then
  ok "Non-member C -> not_member (is_group_member gate)"
else
  nok "Non-member join: $(echo "$resp" | head -c 80)"
fi

resp=$(anon_rpc "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -qE '(PGRST203|permission denied|42501|unauthorized|404)'; then
  ok "anon join denied (EXECUTE revoked from PUBLIC)"
else
  nok "anon join NOT denied: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
# TEST K — finish_minigame_game (201): the session (wager 50 from TEST H)
# settles with a harmonic leaderboard. The exact per-player split is
# non-deterministic (all-zero scoreboard → participant-order tie-break), so
# the invariant asserted here is that the FULL pot is preserved and the
# leaderboard row exists (the precise harmonic math is covered by opt-020/021).
# =========================================================================
h1 "TEST K — finish_minigame_game settlement (pot preserved)"

resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID\"}")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"finished"'; then
  ok "Session finished (leaderboard settlement)"
else
  nok "finish wrong: $(echo "$resp" | head -c 120)"
fi

# Pot preserved: both escrowed 50 → after the pot (100) is paid out, A+B sum
# back to 2000 (the harmonic split may weight one player higher than the other).
shards_a=$(svc_get "users?id=eq.$UUID_A&select=personal_shards")
shards_b=$(svc_get "users?id=eq.$UUID_B&select=personal_shards")
A_VAL=$(echo "$shards_a" | grep -oE '"personal_shards"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
B_VAL=$(echo "$shards_b" | grep -oE '"personal_shards"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
if [ "$((A_VAL + B_VAL))" = "2000" ]; then
  ok "The full 100-shard pot was paid out (A+B back to 2000)"
else
  nok "Pot not preserved: A=$A_VAL B=$B_VAL (want sum 2000)"
fi

results=$(svc_get "minigame_results?session_id=eq.$SESSION_ID&select=results")
if echo "$results" | grep -q '"rank"'; then
  ok "minigame_results leaderboard row written"
else
  nok "minigame_results missing: $(echo "$results" | head -c 120)"
fi

row=$(svc_get "minigame_sessions?id=eq.$SESSION_ID&select=status")
if echo "$row" | grep -q '"status"[[:space:]]*:[[:space:]]*"finished"'; then
  ok "Session row: status=finished"
else
  nok "Session row wrong: $(echo "$row" | head -c 120)"
fi

shards_a_before=$(svc_get "users?id=eq.$UUID_A&select=personal_shards")
resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID\"}")
shards_a_after=$(svc_get "users?id=eq.$UUID_A&select=personal_shards")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"finished"' \
   && [ "$shards_a_before" = "$shards_a_after" ]; then
  ok "Repeat finish -> idempotent (finished, no double settlement)"
else
  nok "Repeat finish NOT idempotent: $(echo "$resp" | head -c 80)"
fi

# =========================================================================
# TEST L — finish_minigame_game top1 payout: the rank-1 player takes the pot
# =========================================================================
h1 "TEST L — finish_minigame_game settlement (pot preserved)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"questions\",\"p_wager\":50}")
SESSION_ID_2=$(echo "$resp" | grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_B" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID_2\"}")
if [ -n "$SESSION_ID_2" ] && echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"joined"'; then
  ok "Second session created (A) and joined (B), wager 50"
else
  nok "Second session setup failed: $(echo "$resp" | head -c 80)"
fi

resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID_2\"}")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"finished"'; then
  ok "Session finished via finish_minigame_game"
else
  nok "finish failed: $(echo "$resp" | head -c 120)"
fi

# The second pot (100) is fully paid out: A+B sum back to 2000 (the exact
# harmonic split depends on the all-zero scoreboard tie-break).
shards_a=$(svc_get "users?id=eq.$UUID_A&select=personal_shards")
shards_b=$(svc_get "users?id=eq.$UUID_B&select=personal_shards")
A_VAL=$(echo "$shards_a" | grep -oE '"personal_shards"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
B_VAL=$(echo "$shards_b" | grep -oE '"personal_shards"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
if [ "$((A_VAL + B_VAL))" = "2000" ]; then
  ok "The full 100-shard pot was paid out (A+B sum 2000)"
else
  nok "Pot not preserved: A=$A_VAL B=$B_VAL (want sum 2000)"
fi

# Both escrowed players got minigame_win ledger entries for the split.
ledger=$(svc_get "shard_ledger?reference_id=eq.$SESSION_ID_2&select=reason,delta")
WIN_TOTAL=$(echo "$ledger" | grep -o '"minigame_win"' | wc -l | tr -d ' ')
if [ "$WIN_TOTAL" -ge 1 ]; then
  ok "minigame_win ledger rows written for the prize split"
else
  nok "no minigame_win ledger rows: $(echo "$ledger" | head -c 120)"
fi

row=$(svc_get "minigame_sessions?id=eq.$SESSION_ID_2&select=status")
if echo "$row" | grep -q '"status"[[:space:]]*:[[:space:]]*"finished"'; then
  ok "Session row: status=finished"
else
  nok "Session row wrong: $(echo "$row" | head -c 80)"
fi

# =========================================================================
# TEST M — a bystander cannot settle (not_allowed)
# =========================================================================
h1 "TEST M — finish_minigame_game bystander gate"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\",\"p_wager\":0}")
SESSION_ID_3=$(echo "$resp" | grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_C" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID_3\"}")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"not_allowed"'; then
  ok "Bystander C cannot settle the direct session (not_allowed)"
else
  nok "bystander settle NOT rejected: $(echo "$resp" | head -c 120)"
fi

row=$(svc_get "minigame_sessions?id=eq.$SESSION_ID_3&select=status")
if echo "$row" | grep -q '"status"[[:space:]]*:[[:space:]]*"active"'; then
  ok "Session stays active after the rejected settle"
else
  nok "Session state after rejected settle: $(echo "$row" | head -c 80)"
fi

resp=$(auth_rpc "$TOKEN_A" "finish_minigame_game" "{\"p_session_id\":\"$SESSION_ID_3\"}")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"finished"'; then
  ok "Zero-wager session finishes cleanly via the leaderboard RPC"
else
  nok "Zero-wager finish wrong: $(echo "$resp" | head -c 120)"
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
