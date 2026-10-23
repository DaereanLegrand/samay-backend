#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-066] Events/location precision + invite links (235_events_links)
# -----------------------------------------------------------------------------
# A) city projection + no coordinates in search_events
# B) pending invitee sees city (not venue); accepted attendee sees exact venue
# C) event link: resolve preview, explicit join, no auto-add
# D) private (approval) event link is single-use; second use is rejected
# E) host approves a join request; the approved viewer then sees the venue
# F) host rotate/revoke: revoked link stops resolving
# G) expired link stops resolving
# H) group link creates a pending `invited` membership (never active)
# I) profile link creates a pending friend request (never auto-accepted)
# J) anon cannot resolve links; SEC-023 scan nonce is written once
#
# Usage:
#   SUPABASE_URL=http://127.0.0.1:55736 \
#   PGURL=postgres://postgres:postgres@localhost:55732/postgres \
#   bash test/opt-066-events-links.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0

UUID_A="66666666-6666-6666-6666-666666666a01"
UUID_B="66666666-6666-6666-6666-666666666b02"
UUID_C="66666666-6666-6666-6666-666666666c03"
EVENT_OPEN=""
EVENT_APPROVAL=""
GROUP_ID="66666666-6666-6666-6666-666666666201"
PW="Pass1234!"

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
nok()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
h1()   { echo ""; echo "--- $1 ---"; }

norm_json() {
  sed -E 's/([][,{}:])[[:space:]]+/\1/g; s/[[:space:]]+([][,{}:])/\1/g'
}
psql_q() {
  psql "$PGURL" -q -v ON_ERROR_STOP=0 -c "$1" >/dev/null 2>&1 || true
}
psql_val() {
  psql "$PGURL" -tAq -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null || true
}

cleanup() {
  psql_q "DELETE FROM public.share_links WHERE created_by_user_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.event_join_requests WHERE user_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.event_scan_nonces WHERE user_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.event_attendances WHERE user_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.event_invites WHERE user_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.event_hosts WHERE user_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.events WHERE created_by_user_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.group_members WHERE group_id = '$GROUP_ID'"
  psql_q "DELETE FROM public.groups WHERE id = '$GROUP_ID'"
  psql_q "DELETE FROM public.friendships WHERE requester_id IN ('$UUID_A','$UUID_B','$UUID_C') OR addressee_id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM public.users WHERE id IN ('$UUID_A','$UUID_B','$UUID_C')"
  psql_q "DELETE FROM auth.users WHERE id IN ('$UUID_A','$UUID_B','$UUID_C')"
}

svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d" | norm_json
}
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" | norm_json
}
anon_rpc() {
  curl -s -o /tmp/opt066_anon.$$ -w '%{http_code}' -X POST \
    "$SUPABASE_URL/rest/v1/rpc/$1" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -d "$2"
}
signin() {
  curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PW\"}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'
}
create_link() { # $1 token $2 kind $3 subject $4 json extra
  auth_rpc "$1" "create_share_link" \
    "{\"p_kind\":\"$2\",\"p_subject_id\":\"$3\"${4:-}}"
}
token_of() { echo "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'; }

# =========================================================================
h1 "SETUP"
trap cleanup EXIT
cleanup

i=0
for pair in "A $UUID_A opt066_a" "B $UUID_B opt066_b" "C $UUID_C opt066_c"; do
  set -- $pair
  i=$((i+1))
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$3@samay.test\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$2\"}" >/dev/null
  svc_post "users" "{\"id\":\"$2\",\"username\":\"$3\",\"date_of_birth\":\"1990-01-01\"}" >/dev/null
done
TOKEN_A=$(signin opt066_a@samay.test)
TOKEN_B=$(signin opt066_b@samay.test)
TOKEN_C=$(signin opt066_c@samay.test)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ]; then
  ok "auth users + tokens"
else
  nok "auth setup failed"; exit 1
fi

BASE='{"p_name":"Opt066 Meetup","p_description":"links","p_type":"casual","p_cover_url":null,"p_group_id":null,"p_location_name":"Calle Falsa 123, Arequipa","p_location_city":"Arequipa","p_location_lat":-16.4090,"p_location_lng":-71.5375,"p_starts_at":"2026-12-31T23:00:00Z","p_ends_at":"2027-01-01T01:00:00Z","p_join_mode":"open","p_preshards_pool":0,"p_preshards_cap_per_user":null,"p_preshards_remainder_action":null'
resp=$(auth_rpc "$TOKEN_A" create_event "$BASE,\"p_capacity\":7}")
EVENT_OPEN=$(echo "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
if [ -n "$EVENT_OPEN" ]; then
  ok "open event created with city + exact venue ($EVENT_OPEN)"
else
  nok "open event create: $(echo "$resp" | head -c 160)"; exit 1
fi
resp=$(auth_rpc "$TOKEN_A" create_event "$(echo "$BASE" | sed 's/Opt066 Meetup/Opt066 Approval/; s/"p_location_name":"[^"]*"/"p_location_name":"Venue Approval 9"/; s/"p_join_mode":"open"/"p_join_mode":"approval"/'),\"p_capacity\":7}")
EVENT_APPROVAL=$(echo "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
if [ -n "$EVENT_APPROVAL" ]; then
  ok "approval event created ($EVENT_APPROVAL)"
else
  nok "approval event create: $(echo "$resp" | head -c 160)"; exit 1
fi

# =========================================================================
h1 "A) search projection: city + distance, coordinates always null"
RESP=$(auth_rpc "$TOKEN_C" search_events '{"p_query":"Opt066 Meetup","p_lat":-16.4090,"p_lng":-71.5375}')
if echo "$RESP" | grep -q '"location_city":"Arequipa"' \
   && echo "$RESP" | grep -q '"location_lat":null' \
   && echo "$RESP" | grep -q '"location_lng":null' \
   && echo "$RESP" | grep -q '"location_name":null' \
   && echo "$RESP" | grep -q '"distance_km":0'; then
  ok "viewer gets city + 0 km distance, no venue, no coordinates"
else
  nok "search projection: $(echo "$RESP" | head -c 360)"
fi

# =========================================================================
h1 "B) pending invitee: city only; accepted: exact venue"
auth_rpc "$TOKEN_A" invite_event_guests \
  "{\"p_event_id\":\"$EVENT_OPEN\",\"p_invitees\":[\"$UUID_C\"]}" >/dev/null
RESP=$(auth_rpc "$TOKEN_C" get_event_for_viewer "{\"p_event_id\":\"$EVENT_OPEN\"}")
if echo "$RESP" | grep -q '"viewer_role":"pending"' \
   && echo "$RESP" | grep -q '"location_city":"Arequipa"' \
   && echo "$RESP" | grep -q '"location_name":null' \
   && echo "$RESP" | grep -q '"viewer_has_exact_location":false'; then
  ok "pending invitee sees city, not exact venue"
else
  nok "pending projection: $(echo "$RESP" | head -c 360)"
fi

# =========================================================================
h1 "C) event link resolve does not auto-add; explicit join does"
LINK_RESP=$(create_link "$TOKEN_A" event "$EVENT_OPEN" ',"p_single_use":false')
TOKEN_LINK=$(token_of "$LINK_RESP")
if [ -n "$TOKEN_LINK" ]; then ok "host created event link"; else nok "create event link: $LINK_RESP"; fi
RESP=$(auth_rpc "$TOKEN_B" resolve_share_link "{\"p_token\":\"$TOKEN_LINK\"}")
if echo "$RESP" | grep -q '"kind":"event"' \
   && echo "$RESP" | grep -q '"location_city":"Arequipa"' \
   && echo "$RESP" | grep -q '"location_name":null' \
   && echo "$RESP" | grep -q '"location_lat":null' \
   && echo "$RESP" | grep -q '"viewer_state":"viewer"' \
   && echo "$RESP" | grep -q '"can_join":true'; then
  ok "link preview: city only, viewer state, join offered"
else
  nok "resolve event link: $(echo "$RESP" | head -c 360)"
fi
N=$(psql_val "SELECT count(*) FROM public.event_invites WHERE event_id='$EVENT_OPEN' AND user_id='$UUID_B'")
if [ "$N" = "0" ]; then ok "resolving did not auto-join"; else nok "resolve auto-added an invite"; fi

RESP=$(auth_rpc "$TOKEN_B" join_event_by_link "{\"p_token\":\"$TOKEN_LINK\"}")
if echo "$RESP" | grep -q '"status":"joined"'; then ok "explicit join accepted for open event"; else nok "join: $RESP"; fi
RESP=$(auth_rpc "$TOKEN_B" get_event_for_viewer "{\"p_event_id\":\"$EVENT_OPEN\"}")
if echo "$RESP" | grep -q '"viewer_has_exact_location":true' \
   && echo "$RESP" | grep -q 'Calle Falsa 123'; then
  ok "accepted attendee now sees the exact venue"
else
  nok "accepted projection: $(echo "$RESP" | head -c 360)"
fi

# =========================================================================
h1 "D) private event link is single-use"
LINK_RESP=$(create_link "$TOKEN_A" event "$EVENT_APPROVAL" '')
TOKEN_PRIVATE=$(token_of "$LINK_RESP")
if echo "$LINK_RESP" | grep -q '"single_use":true'; then
  ok "approval-event link defaults to single_use"
else
  nok "private link single_use: $LINK_RESP"
fi
RESP=$(auth_rpc "$TOKEN_C" join_event_by_link "{\"p_token\":\"$TOKEN_PRIVATE\"}")
if echo "$RESP" | grep -q '"status":"requested"'; then
  ok "private link creates a join request (not a membership)"
else
  nok "private join: $RESP"
fi
RESP=$(auth_rpc "$TOKEN_C" resolve_share_link "{\"p_token\":\"$TOKEN_PRIVATE\"}")
if echo "$RESP" | grep -q '"status":"invalid_link"'; then
  ok "single-use token is dead after the request"
else
  nok "replayed single-use token: $(echo "$RESP" | head -c 200)"
fi

# =========================================================================
h1 "E) host approves; viewer then sees the venue"
REQ=$(auth_rpc "$TOKEN_A" get_event_join_requests "{\"p_event_id\":\"$EVENT_APPROVAL\"}")
REQ_ID=$(echo "$REQ" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)
if [ -n "$REQ_ID" ]; then ok "host reads pending join request"; else nok "join request not visible: $REQ"; fi
RESP=$(auth_rpc "$TOKEN_A" decide_event_join_request "{\"p_request_id\":\"$REQ_ID\",\"p_approve\":true}")
if echo "$RESP" | grep -q '"status":"approved"'; then ok "host approved request"; else nok "approve: $RESP"; fi
RESP=$(auth_rpc "$TOKEN_C" get_event_for_viewer "{\"p_event_id\":\"$EVENT_APPROVAL\"}")
if echo "$RESP" | grep -q '"viewer_has_exact_location":true' \
   && echo "$RESP" | grep -q 'Venue Approval 9'; then
  ok "approved viewer sees exact venue"
else
  nok "approved projection: $(echo "$RESP" | head -c 360)"
fi

# =========================================================================
h1 "F) revoke stops resolution"
LINK_RESP=$(create_link "$TOKEN_A" event "$EVENT_OPEN" ',"p_single_use":false')
TOKEN_REVOKE=$(token_of "$LINK_RESP")
auth_rpc "$TOKEN_A" revoke_share_link "{\"p_kind\":\"event\",\"p_subject_id\":\"$EVENT_OPEN\"}" >/dev/null
RESP=$(auth_rpc "$TOKEN_B" resolve_share_link "{\"p_token\":\"$TOKEN_REVOKE\"}")
if echo "$RESP" | grep -q '"status":"invalid_link"'; then ok "revoked link rejected"; else nok "revoked link: $RESP"; fi

# =========================================================================
h1 "G) expiry stops resolution"
LINK_RESP=$(create_link "$TOKEN_A" profile "$UUID_A" ",\"p_expires_at\":\"$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 second' +%Y-%m-%dT%H:%M:%SZ)\"")
TOKEN_EXPIRE=$(token_of "$LINK_RESP")
sleep 2
RESP=$(auth_rpc "$TOKEN_B" resolve_share_link "{\"p_token\":\"$TOKEN_EXPIRE\"}")
if echo "$RESP" | grep -q '"status":"invalid_link"'; then ok "expired link rejected"; else nok "expired link: $RESP"; fi

# =========================================================================
h1 "H) group link creates an invited membership (not active)"
svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Opt066 Group\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
LINK_RESP=$(create_link "$TOKEN_A" group "$GROUP_ID" '')
TOKEN_GROUP=$(token_of "$LINK_RESP")
RESP=$(auth_rpc "$TOKEN_B" join_group_by_link "{\"p_token\":\"$TOKEN_GROUP\"}")
if echo "$RESP" | grep -q '"status":"invited"'; then ok "group link creates pending invite"; else nok "group join: $RESP"; fi
STATUS=$(psql_val "SELECT status FROM public.group_members WHERE group_id='$GROUP_ID' AND user_id='$UUID_B'")
if [ "$STATUS" = "invited" ]; then ok "membership stays invited (no auto-join)"; else nok "membership status: $STATUS"; fi
RESP=$(auth_rpc "$TOKEN_B" resolve_share_link "{\"p_token\":\"$TOKEN_GROUP\"}")
if echo "$RESP" | grep -q '"viewer_state":"invited"'; then ok "resolver reports invited state"; else nok "group resolve: $(echo "$RESP" | head -c 240)"; fi

# =========================================================================
h1 "I) profile link creates a pending friend request"
LINK_RESP=$(create_link "$TOKEN_A" profile "$UUID_A" '')
TOKEN_PROFILE=$(token_of "$LINK_RESP")
RESP=$(auth_rpc "$TOKEN_B" request_friend_by_profile_link "{\"p_token\":\"$TOKEN_PROFILE\"}")
if echo "$RESP" | grep -q '"status":"requested"'; then ok "profile link creates pending request"; else nok "profile request: $RESP"; fi
FSTATUS=$(psql_val "SELECT status FROM public.friendships WHERE requester_id='$UUID_B' AND addressee_id='$UUID_A' ORDER BY created_at DESC LIMIT 1")
if [ "$FSTATUS" = "pending" ]; then ok "friendship stays pending (no auto-accept)"; else nok "friendship status: $FSTATUS"; fi
RESP=$(auth_rpc "$TOKEN_B" request_friend_by_profile_link "{\"p_token\":\"$TOKEN_PROFILE\"}")
if echo "$RESP" | grep -q '"status":"already_requested"'; then ok "repeat profile request is idempotent"; else nok "repeat profile request: $RESP"; fi

# =========================================================================
h1 "J) anon denial + SEC-023 nonce"
CODE=$(anon_rpc resolve_share_link "{\"p_token\":\"$TOKEN_PROFILE\"}")
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then ok "anon cannot resolve links ($CODE)"; else nok "anon resolve status $CODE"; fi
psql_q "INSERT INTO public.event_attendances (event_id,user_id) VALUES ('$EVENT_APPROVAL','$UUID_C') ON CONFLICT DO NOTHING"
NONCES=$(psql_val "SELECT count(*) FROM public.event_scan_nonces WHERE event_id='$EVENT_APPROVAL' AND user_id='$UUID_C'")
if [ "$NONCES" = "1" ]; then ok "confirmed scan writes exactly one nonce"; else nok "scan nonce count: $NONCES"; fi

echo ""
echo "=================================================="
echo "  OPT-066 RESULT: $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
