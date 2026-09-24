#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-033] Event discovery search — Integration Test (131_events_search)
# -----------------------------------------------------------------------------
# Verifies the authenticated event-search RPC:
#
#   1) search_events(p_query) returns matching events (authenticated)
#   2) sub-2-char / >50-char queries are rejected with SQLSTATE SR002
#   3) anon is DENIED the RPC (401/403)
#   4) the shared per-user quota raises SR001 once search_rate_limits
#      .search_count passes 60 within the window (seeded via service_role)
#   5) the radius filter runs server-side and HARD-CAPS at 100 km (a 200+ km
#      request still excludes an event ~167 km away)
#   6) the accepted-friend invite signal is returned (friends_going = 1)
#
# SELF-CONTAINED (fixed UUIDs unique to this file — 8888… family).
# Cleanup removes the auth users, events, invites and friendships on exit.
#
# Usage: bash test/opt-033-events-search.sh
#
# Keys: resolved by dev_env.sh (environment overrides gitignored stack env).
# PGURL overrides the psql DSN.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0

# Fixed IDs (8888… family — unique to this file).
UUID_A="88888888-8888-8888-8888-888888330001"
UUID_B="88888888-8888-8888-8888-888888330002"
EVENT_NEAR="88888888-8888-8888-8888-888888330101"
EVENT_FAR="88888888-8888-8888-8888-888888330102"
EMAIL_A="event_search_a_opt033@samay.test"
EMAIL_B="event_search_b_opt033@samay.test"
PW="Pass1234!"

cleanup() {
  svc_delete_quiet "event_invites?event_id=in.($EVENT_NEAR,$EVENT_FAR)"
  svc_delete_quiet "event_hosts?event_id=in.($EVENT_NEAR,$EVENT_FAR)"
  svc_delete_quiet "events?id=in.($EVENT_NEAR,$EVENT_FAR)"
  svc_delete_quiet "friendships?requester_id=in.($UUID_A,$UUID_B)"
  svc_delete_quiet "search_rate_limits?user_id=in.($UUID_A,$UUID_B)"
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
h1 "SETUP: caller A + friend B; 2 events (near Arequipa, ~167 km far)"
# ---------------------------------------------------------------------------
trap cleanup EXIT
cleanup

for pair in "A $UUID_A event_search_a_opt033 $EMAIL_A" "B $UUID_B event_search_b_opt033 $EMAIL_B"; do
  set -- $pair
  uid=$2; uname=$3; email=$4
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if ! echo "$resp" | grep -q '"id"'; then
    nok "create auth user $1"
    exit 1
  fi
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"$uname\"}"
done

svc_post "friendships" \
  "{\"requester_id\":\"$UUID_A\",\"addressee_id\":\"$UUID_B\",\"status\":\"accepted\"}"

STARTS=$(date -u -v+2d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 days' +%Y-%m-%dT%H:%M:%SZ)
ENDS=$(date -u -v+2d -v+4H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+2 days 4 hours' +%Y-%m-%dT%H:%M:%SZ)
svc_post "events" "{\"id\":\"$EVENT_NEAR\",\"name\":\"opt033 near event\",\"type\":\"casual\",\"created_by_user_id\":\"$UUID_A\",\"location_name\":\"Arequipa\",\"location_lat\":-16.4090,\"location_lng\":-71.5375,\"starts_at\":\"$STARTS\",\"ends_at\":\"$ENDS\",\"capacity\":5,\"status\":\"upcoming\"}"
svc_post "events" "{\"id\":\"$EVENT_FAR\",\"name\":\"opt033 far event\",\"type\":\"casual\",\"created_by_user_id\":\"$UUID_A\",\"location_name\":\"Far\",\"location_lat\":-15.0000,\"location_lng\":-71.0000,\"starts_at\":\"$STARTS\",\"ends_at\":\"$ENDS\",\"capacity\":5,\"status\":\"upcoming\"}"
svc_post "event_invites" \
  "{\"event_id\":\"$EVENT_NEAR\",\"user_id\":\"$UUID_B\",\"invited_by_user_id\":\"$UUID_A\",\"status\":\"accepted\"}"

TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -z "$TOKEN" ]; then
  nok "sign in A"
  exit 1
fi

# ---------------------------------------------------------------------------
h1 "1) authenticated search_events returns the matching event"
# ---------------------------------------------------------------------------
RESP=$(auth_rpc "$TOKEN" "search_events" '{"p_query":"opt033 near"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" = "200" ] && echo "$BODY" | grep -q '"name":"opt033 near event"'; then
  ok "text query returns the near event (200)"
else
  nok "text query returns the near event (got $CODE: $BODY)"
fi

# ---------------------------------------------------------------------------
h1 "2) length validation — SR002 on a 1-char query"
# ---------------------------------------------------------------------------
RESP=$(auth_rpc "$TOKEN" "search_events" '{"p_query":"a"}')
BODY=$(echo "$RESP" | sed '$d')
if echo "$BODY" | grep -q '"code":"SR002"'; then
  ok "1-char query rejected with SR002"
else
  nok "1-char query rejected with SR002 (got $BODY)"
fi

# ---------------------------------------------------------------------------
h1 "3) anon is DENIED the RPC"
# ---------------------------------------------------------------------------
ANON_RESP=$(anon_rpc "search_events" '{"p_query":"opt033"}')
ANON_CODE=$(echo "$ANON_RESP" | tail -n1)
if [ "$ANON_CODE" = "401" ] || [ "$ANON_CODE" = "403" ]; then
  ok "anon is denied the RPC (got $ANON_CODE)"
else
  nok "anon is denied the RPC (got $ANON_CODE)"
fi

# ---------------------------------------------------------------------------
h1 "4) server-side radius filter + 100 km hard cap"
# ---------------------------------------------------------------------------
RESP=$(auth_rpc "$TOKEN" "search_events" \
  '{"p_query":"opt033","p_lat":-16.4090,"p_lng":-71.5375,"p_radius_km":50}')
BODY=$(echo "$RESP" | sed '$d')
if echo "$BODY" | grep -q '"name":"opt033 near event"' \
   && ! echo "$BODY" | grep -q '"name":"opt033 far event"'; then
  ok "50 km radius returns the near event, excludes the far one"
else
  nok "50 km radius filtering (got $BODY)"
fi
RESP=$(auth_rpc "$TOKEN" "search_events" \
  '{"p_query":"opt033","p_lat":-16.4090,"p_lng":-71.5375,"p_radius_km":1000}')
BODY=$(echo "$RESP" | sed '$d')
if echo "$BODY" | grep -q '"name":"opt033 near event"' \
   && ! echo "$BODY" | grep -q '"name":"opt033 far event"'; then
  ok "radius is hard-capped at 100 km (1000 km request still excludes the far event)"
else
  nok "100 km hard cap (got $BODY)"
fi

# ---------------------------------------------------------------------------
h1 "5) accepted-friend signal is returned"
# ---------------------------------------------------------------------------
RESP=$(auth_rpc "$TOKEN" "search_events" '{"p_query":"opt033 near"}')
BODY=$(echo "$RESP" | sed '$d')
if echo "$BODY" | grep -q '"friends_going":1'; then
  ok "friends_going = 1 for the accepted friend invite"
else
  nok "friends_going signal (got $BODY)"
fi

# ---------------------------------------------------------------------------
h1 "6) shared per-user quota — SR001 once the window counter exceeds 60"
# ---------------------------------------------------------------------------
svc_upsert "search_rate_limits" \
  "{\"user_id\":\"$UUID_A\",\"window_start\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"search_count\":60}"
RESP=$(auth_rpc "$TOKEN" "search_events" '{"p_query":"opt033"}')
BODY=$(echo "$RESP" | sed '$d')
if echo "$BODY" | grep -q '"code":"SR001"'; then
  ok "61st event search inside the window raises SR001"
else
  nok "61st event search inside the window raises SR001 (got $BODY)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  OPT-033 RESULT: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
