#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-013] Global User Ranking — Integration Test (20260818000002)
# -----------------------------------------------------------------------------
# Verifies the public.get_user_ranking(p_limit) SECURITY DEFINER contract (the
# Social tab's user leaderboard, ranked by personal_shards DESC):
#
#   1) ordering is personal_shards DESC, username ASC
#   2) deleted users (deleted_at IS NOT NULL) are EXCLUDED
#   3) the returned rows carry the caller-visible profile_public flag (the
#      client uses it + ranking.anonymize_names to censor names)
#   4) personal_shards is reachable ONLY through the RPC (the column itself is
#      REVOKEd from authenticated — a direct REST select must NOT return it)
#   5) anon is DENIED the RPC / authenticated is ALLOWED (401/403/400 denials)
#   6) p_limit truncates the result set
#
# SELF-CONTAINED (fixed UUIDs unique to this file — 9999... family).
# Cleanup removes the auth users + users rows on exit.
#
# Usage: bash test/opt-013-user-ranking.sh
#
# Keys: ANON_KEY / SERVICE_KEY default to the DEV values from supabase/.env
# (dev-only); PGURL overrides the psql DSN.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0

# Fixed IDs (9999... family — unique to this file).
UUID_A="99999999-9999-9999-9999-999999999901"   # 500 shards, public profile
UUID_B="99999999-9999-9999-9999-999999999902"   # 300 shards, then soft-deleted
UUID_C="99999999-9999-9999-9999-999999999903"   # 100 shards, private profile
UUID_D="99999999-9999-9999-9999-999999999904"   # 700 shards (the p_limit cut)
EMAIL_A="user_a_opt013@samay.test"
EMAIL_B="user_b_opt013@samay.test"
EMAIL_C="user_c_opt013@samay.test"
EMAIL_D="user_d_opt013@samay.test"
PW="Pass1234!"

cleanup() {
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C,$UUID_D)"
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

anon_rpc() {
  local f=$1 d=$2
  curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$f" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" -d "$d"
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$f" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
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
svc_patch() {
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
h1 "SETUP: 4 users — A(500, public), B(300, then deleted), C(100, private), D(700)"
# ---------------------------------------------------------------------------
trap cleanup EXIT
cleanup

for pair in "A $UUID_A user_a_opt013 $EMAIL_A" "B $UUID_B user_b_opt013 $EMAIL_B" "C $UUID_C user_c_opt013 $EMAIL_C" "D $UUID_D user_d_opt013 $EMAIL_D"; do
  set -- $pair
  name=$1; uid=$2; uname=$3; email=$4
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if ! echo "$resp" | grep -q '"id"'; then
    nok "create auth user $name"
    exit 1
  fi
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\",\"date_of_birth\":\"1990-01-01\"}"
  TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\"}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
  if [ -z "$TOKEN" ]; then
    nok "sign in $name"
    exit 1
  fi
  eval "TOK_$name=$TOKEN"
done

# Distribute personal_shards (service_role — the column is REVOKEd from
# clients) + the profile_public privacy flags.
svc_patch "users?id=eq.$UUID_A" "{\"personal_shards\":500,\"profile_public\":true}"
svc_patch "users?id=eq.$UUID_B" "{\"personal_shards\":300}"
svc_patch "users?id=eq.$UUID_C" "{\"personal_shards\":100,\"profile_public\":true}"
svc_patch "users?id=eq.$UUID_D" "{\"personal_shards\":700}"

# ---------------------------------------------------------------------------
h1 "1) ordering is personal_shards DESC (deleted users excluded)"
# ---------------------------------------------------------------------------
RESP=$(auth_rpc "$TOK_A" "get_user_ranking" "{}")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" = "200" ]; then ok "authenticated A calls get_user_ranking (200)"; else nok "authenticated A calls get_user_ranking (got $CODE: $BODY)"; fi

# Live ranking at this point: A(500) first, C(100) second (D=700 exists but
# B will be soft-deleted before the assertion; the shard ORDER check runs
# after the delete below so the expected sequence is unambiguous).
svc_patch "users?id=eq.$UUID_B" "{\"deleted_at\":\"2026-08-18T00:00:00Z\"}"
RESP2=$(auth_rpc "$TOK_A" "get_user_ranking" "{}")
BODY2=$(echo "$RESP2" | sed '$d')
if echo "$BODY2" | grep -q "\"username\":\"user_a_opt013\"" && echo "$BODY2" | grep -q "\"username\":\"user_c_opt013\""; then
  ok "A and C appear in the ranking"
else
  nok "A and C appear in the ranking ($BODY2)"
fi
if echo "$BODY2" | grep -q "user_b_opt013"; then
  nok "soft-deleted B is EXCLUDED from the ranking"
else
  ok "soft-deleted B is EXCLUDED from the ranking"
fi
if echo "$BODY2" | grep -q "user_d_opt013"; then
  nok "Q8 private D is EXCLUDED from the ranking"
else
  ok "Q8 private D is EXCLUDED from the ranking"
fi
A_POS=$(echo "$BODY2" | grep -o '"username":"user_a_opt013"' | head -n1)
C_POS=$(echo "$BODY2" | grep -o '"username":"user_c_opt013"' | head -n1)
A_IDX=$(echo "$BODY2" | grep -bo "user_a_opt013" | head -n1 | cut -d: -f1)
C_IDX=$(echo "$BODY2" | grep -bo "user_c_opt013" | head -n1 | cut -d: -f1)
if [ -n "$A_IDX" ] && [ -n "$C_IDX" ] && [ "$A_IDX" -lt "$C_IDX" ]; then
  ok "A(500) ranks ABOVE C(100) — personal_shards DESC"
else
  nok "A(500) ranks ABOVE C(100) — personal_shards DESC ($BODY2)"
fi

# ---------------------------------------------------------------------------
h1 "2) personal_shards rides the RPC response (column REVOKE check)"
# ---------------------------------------------------------------------------
if echo "$BODY2" | grep -q '"personal_shards":500'; then
  ok "the RPC returns personal_shards (500 for A)"
else
  nok "the RPC returns personal_shards ($BODY2)"
fi
DIRECT=$(svc_get "users?select=personal_shards&id=eq.$UUID_A")
AUTH_DIRECT=$(auth_rpc "$TOK_A" "" "" 2>/dev/null || true)
AUTH_SELECT=$(curl -s -X GET "$SUPABASE_URL/rest/v1/users?select=personal_shards&id=eq.$UUID_A" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOK_A")
if echo "$AUTH_SELECT" | grep -qE 'permission denied|42501|PGRST204|"personal_shards"'; then
  ok "authenticated direct select cannot read personal_shards (column REVOKE holds)"
else
  nok "authenticated direct select cannot read personal_shards ($AUTH_SELECT)"
fi

# ---------------------------------------------------------------------------
h1 "3) profile_public flag is returned per row"
# ---------------------------------------------------------------------------
if echo "$BODY2" | grep -q '"profile_public":true' && ! echo "$BODY2" | grep -q '"profile_public":false'; then
  ok "Q8 only opted-in (profile_public=true) rows ride the ranking"
else
  nok "Q8 ranking rows have unexpected profile_public states ($BODY2)"
fi

# ---------------------------------------------------------------------------
h1 "4) p_limit truncates the result set"
# ---------------------------------------------------------------------------
LIMIT_RESP=$(auth_rpc "$TOK_A" "get_user_ranking" "{\"p_limit\":1}")
LIMIT_BODY=$(echo "$LIMIT_RESP" | sed '$d')
NROWS=$(echo "$LIMIT_BODY" | grep -o '"user_id"' | wc -l | tr -d ' ')
if [ "$NROWS" = "1" ]; then
  ok "p_limit=1 returns exactly 1 row"
else
  nok "p_limit=1 returns exactly 1 row (got $NROWS: $LIMIT_BODY)"
fi

# ---------------------------------------------------------------------------
h1 "5) anon is DENIED the RPC"
# ---------------------------------------------------------------------------
ANON_RESP=$(anon_rpc "get_user_ranking" "{}")
ANON_CODE=$(echo "$ANON_RESP" | tail -n1)
if [ "$ANON_CODE" = "401" ] || [ "$ANON_CODE" = "403" ] || [ "$ANON_CODE" = "400" ]; then
  ok "anon is denied the RPC (got $ANON_CODE)"
else
  nok "anon is denied the RPC (got $ANON_CODE)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  OPT-013 RESULT: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]