#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-006] Minigame session RPC contract — create / join / settle
# -----------------------------------------------------------------------------
# Slim-prod removed E2EE chat, so the fetch_prekey_bundle half of this script
# was retired with the feature (300_slim/05_revoke_removed revokes
# e2ee_identity_keys from every client role). What remains is the direct-join
# minigame session contract (migration 20260813000001):
#   G) group + memberships provisioned (A host, B member, C non-member)
#   H) create_minigame_session creates a session with no wager (slim-prod
#      removed the shard escrow; the retired column stays 0)
#   I) join_minigame_session is idempotent (no duplicate participant, no
#      ledger write)
#   J) join error paths: session_not_found / not_member / anon denied
#   K) finish_minigame_game settles the leaderboard; a repeat finish is a
#      no-op and settlement moves no shards
#   M) a bystander cannot settle (not_allowed) and the session stays active
#
# NOTE: the caller must be an authenticated user (JWT), so the test creates
# real auth.users rows via the admin API exactly like opt-001.
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup).
#
# Usage: bash test/opt-006-e2ee-rpc.sh
#
# Keys (M-03 alignment): resolved at runtime by test/dev_env.sh from the
# gitignored stack .env (supabase/.env) — dev-only; CI
# overrides them via env vars.
# =============================================================================
SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
. "$(cd "$(dirname "$0")" && pwd)/minigame_finish_helper.sh"

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

cleanup() {
  # NO-ACTION FK rows first so the user delete is never blocked (and nothing
  # leaks into the next test run).
  svc_delete_quiet "minigame_sessions?participants=ov.{$UUID_A,$UUID_B,$UUID_C}"
  svc_delete_quiet "minigame_sessions?group_id=eq.$GROUP_ID"
  svc_delete_quiet "minigame_invites?invitee_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "minigame_invites?created_by=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "reports?reporter_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "shard_ledger?user_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "preshard_ledger?user_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "group_members?user_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "group_shard_contributions?user_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "friendships?requester_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "friendships?addressee_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "groups?created_by_user_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C)"
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
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":1000,\"age_confirmed_at\":\"2026-01-01T00:00:00Z\",\"terms_accepted_at\":\"2026-01-01T00:00:00Z\"}" > /dev/null
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
# TEST G — minigame RPC setup: group + memberships (A host, B member)
# =========================================================================
h1 "TEST G — minigame setup (group + memberships)"

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Minigame Opt Test\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\"}" > /dev/null
ok "Group + memberships provisioned (A host, B member, C non-member)"

# =========================================================================
# TEST H — create_minigame_session (no wager in slim-prod)
# =========================================================================
h1 "TEST H — create_minigame_session (wager retired)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"poke_chain\"}")
SESSION_ID=$(echo "$resp" | grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"created"' && [ -n "$SESSION_ID" ]; then
  ok "Session created (A, no wager)"
else
  nok "create_minigame_session wrong: $(echo "$resp" | head -c 120)"
fi

shards=$(svc_get "users?id=eq.$UUID_A&select=personal_shards")
if echo "$shards" | grep -q '"personal_shards"[[:space:]]*:[[:space:]]*1000'; then
  ok "Initiator A keeps their balance at creation (wager economy removed)"
else
  nok "A shards after create: $(echo "$shards" | head -c 80)"
fi

ledger=$(svc_get "shard_ledger?user_id=eq.$UUID_A&select=reason,delta,reference_id")
if [ "$ledger" = "[]" ]; then
  ok "No shard_ledger row written at creation"
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
if echo "$shards" | grep -q '"personal_shards"[[:space:]]*:[[:space:]]*1000'; then
  ok "Joiner B keeps their balance (wager economy removed)"
else
  nok "B shards after join: $(echo "$shards" | head -c 80)"
fi

resp=$(auth_rpc "$TOKEN_B" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID\"}")
parts=$(svc_get "minigame_sessions?id=eq.$SESSION_ID&select=participants")
count=$(echo "$parts" | grep -o "$UUID_B" | wc -l | tr -d ' ')
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"joined"' && [ "$count" = "1" ]; then
  ok "Re-join is idempotent (B appears exactly once in participants)"
else
  nok "Re-join NOT idempotent (B occurrences=$count)"
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

resp=$(finish_game "$UUID_A" "$SESSION_ID")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"finished"'; then
  ok "Session finished (leaderboard settlement)"
else
  nok "finish wrong: $(echo "$resp" | head -c 120)"
fi

# Slim-prod settled with no wager: no shards move on settlement.
ledger=$(svc_get "shard_ledger?reference_id=eq.$SESSION_ID&select=reason,delta")
if [ "$ledger" = "[]" ]; then
  ok "Settlement writes no shard_ledger rows (wager economy removed)"
else
  nok "Unexpected ledger rows after settlement: $(echo "$ledger" | head -c 120)"
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
resp=$(finish_game "$UUID_A" "$SESSION_ID")
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
h1 "TEST L — finish_minigame_game settlement (no payout)"

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"questions\"}")
SESSION_ID_2=$(echo "$resp" | grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
resp=$(auth_rpc "$TOKEN_B" "join_minigame_session" "{\"p_session_id\":\"$SESSION_ID_2\"}")
if [ -n "$SESSION_ID_2" ] && echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"joined"'; then
  ok "Second session created (A) and joined (B)"
else
  nok "Second session setup failed: $(echo "$resp" | head -c 80)"
fi

resp=$(finish_game "$UUID_A" "$SESSION_ID_2")
if echo "$resp" | grep -qE '"status"[[:space:]]*:[[:space:]]*"finished"'; then
  ok "Session finished via finish_minigame_game"
else
  nok "finish failed: $(echo "$resp" | head -c 120)"
fi

# No wager pot exists in slim-prod, so no prize ledger rows are written.
ledger=$(svc_get "shard_ledger?reference_id=eq.$SESSION_ID_2&select=reason,delta")
if [ "$ledger" = "[]" ]; then
  ok "No minigame_win ledger rows written (no wager pot)"
else
  nok "unexpected prize ledger rows: $(echo "$ledger" | head -c 120)"
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

resp=$(auth_rpc "$TOKEN_A" "create_minigame_session" "{\"p_group_id\":\"$GROUP_ID\",\"p_game_type\":\"truth_dare\"}")
SESSION_ID_3=$(echo "$resp" | grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
resp=$(finish_game "$UUID_C" "$SESSION_ID_3")
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

resp=$(finish_game "$UUID_A" "$SESSION_ID_3")
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
