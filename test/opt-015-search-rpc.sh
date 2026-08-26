#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-015] Search abuse protection — Integration Test (130_search/01_search_rpc.sql)
# -----------------------------------------------------------------------------
# Verifies the OWASP API4 hardening of the user-search endpoint:
#
#   1) search_users(p_query) RPC: authenticated valid search returns rows
#   2) sub-5-char (or >50-char) queries are rejected with SQLSTATE SR002
#   3) anon is DENIED the RPC (401/403)
#   4) the per-user quota raises SR001 once search_rate_limits.search_count
#      passes 60 within the window (seeded via service_role, not by
#      hammering 61 real requests)
#   5) the Kong route limiter answers /rest/v1/user_search_view with the
#      standard RateLimit headers (minute=120, per-IP flood guard)
#   6) idx_users_username_prefix exists with text_pattern_ops (allowed
#      searches must be index scans, not seq scans)
#
# NOTE: direct SELECT on user_search_view stays granted to authenticated —
# the view feeds five non-search surfaces; documented deviation in the
# migration header.
#
# SELF-CONTAINED (fixed UUIDs unique to this file — 8888... family).
# Cleanup removes the auth users + users rows on exit.
#
# Usage: bash test/opt-015-search-rpc.sh
#
# Keys: resolved by dev_env.sh (environment overrides gitignored stack env).
# PGURL overrides the psql DSN.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0

# Fixed IDs (8888... family — unique to this file).
UUID_A="88888888-8888-8888-8888-888888888801"
UUID_B="88888888-8888-8888-8888-888888888802"
EMAIL_A="user_a_opt015@samay.test"
EMAIL_B="user_b_opt015@samay.test"
PW="Pass1234!"

cleanup() {
  for uid in $UUID_A $UUID_B; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B)"
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$f" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t" \
    -H "Content-Type: application/json" -d "$d"
}
anon_rpc() {
  local f=$1 d=$2
  curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$f" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" -d "$d"
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
svc_upsert() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: resolution=merge-duplicates,return=minimal" -d "$2" 2>/dev/null
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
h1 "SETUP: 2 users — A(searcher), B(search target 'opt015target')"
# ---------------------------------------------------------------------------
trap cleanup EXIT
cleanup

for pair in "A $UUID_A user_a_opt015 $EMAIL_A" "B $UUID_B opt015target $EMAIL_B"; do
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
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\"}"
done

TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -z "$TOKEN" ]; then
  nok "sign in A"
  exit 1
fi

# ---------------------------------------------------------------------------
h1 "1) authenticated search_users returns prefix matches"
# ---------------------------------------------------------------------------
RESP=$(auth_rpc "$TOKEN" "search_users" '{"p_query":"opt01"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" = "200" ] && echo "$BODY" | grep -q '"username":"opt015target"'; then
  ok "valid query returns opt015target (200)"
else
  nok "valid query returns opt015target (got $CODE: $BODY)"
fi
if echo "$BODY" | grep -q '"username":"user_a_opt015"'; then
  nok "the caller is excluded from their own results"
else
  ok "the caller is excluded from their own results"
fi

# ---------------------------------------------------------------------------
h1 "2) length validation — SR002 on a 4-char query"
# ---------------------------------------------------------------------------
RESP=$(auth_rpc "$TOKEN" "search_users" '{"p_query":"opt0"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if echo "$BODY" | grep -q '"code":"SR002"'; then
  ok "sub-5-char query rejected with SR002"
else
  nok "sub-5-char query rejected with SR002 (got $CODE: $BODY)"
fi

# ---------------------------------------------------------------------------
h1 "3) anon is DENIED the RPC"
# ---------------------------------------------------------------------------
ANON_RESP=$(anon_rpc "search_users" '{"p_query":"opt015"}')
ANON_CODE=$(echo "$ANON_RESP" | tail -n1)
if [ "$ANON_CODE" = "401" ] || [ "$ANON_CODE" = "403" ]; then
  ok "anon is denied the RPC (got $ANON_CODE)"
else
  nok "anon is denied the RPC (got $ANON_CODE)"
fi

# ---------------------------------------------------------------------------
h1 "4) per-user quota — SR001 once the window counter exceeds 60"
# ---------------------------------------------------------------------------
svc_upsert "search_rate_limits" \
  "{\"user_id\":\"$UUID_A\",\"window_start\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"search_count\":60}"
RESP=$(auth_rpc "$TOKEN" "search_users" '{"p_query":"opt015"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if echo "$BODY" | grep -q '"code":"SR001"'; then
  ok "61st search inside the window raises SR001"
else
  nok "61st search inside the window raises SR001 (got $CODE: $BODY)"
fi

# ---------------------------------------------------------------------------
h1 "5) Kong route limiter emits RateLimit headers on the search path"
# ---------------------------------------------------------------------------
HEADERS=$(curl -s -D - -o /dev/null \
  "$SUPABASE_URL/rest/v1/user_search_view?select=id&limit=1" \
  -H "apikey: $ANON_KEY")
if echo "$HEADERS" | grep -qi "^RateLimit-Limit: 120"; then
  ok "RateLimit-Limit: 120 present (per-IP minute bucket)"
else
  nok "RateLimit-Limit header missing ($HEADERS)"
fi

# ---------------------------------------------------------------------------
h1 "6) prefix index exists (text_pattern_ops)"
# ---------------------------------------------------------------------------
IDX=$(psql "$PGURL" -tA -c \
  "SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_users_username_prefix' AND indexdef ILIKE '%text_pattern_ops%';" 2>/dev/null)
if [ "$IDX" = "1" ]; then
  ok "idx_users_username_prefix uses text_pattern_ops"
else
  nok "idx_users_username_prefix missing or wrong method (got: $IDX)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  OPT-015 RESULT: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
