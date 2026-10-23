#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-024] Events — Attendee Capacity & Entitlement Tier
# Verifies the Stage-1 events capacity surface (060_events/04_capacity.sql):
#   A) free-tier creator CANNOT create an event above their cap (7) — the
#      create_event RPC + assert_event_capacity_trigger reject capacity 8
#      with 'capacity_exceeds_tier'
#   B) free-tier creator CAN create an event at capacity 7 (default seat
#      accounting: creator host row + capacity frozen server-side)
#   C) raising the creator's subscription_tier to PRO (service_role, the only
#      writer today) lifts the cap to 56; 57 is rejected again
#   D) service_role direct insert WITHOUT capacity gets the tier default (7
#      for the free creator); event_seats_used returns 1 for a fresh event
#      (the host seat)
#
# SELF-CONTAINED (opt-002 pattern): creates its own auth users + events with
# fixed UUIDs; cleans up on exit. Static-verified only in this agent run.
#
# Usage: bash test/opt-024-events-capacity.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

UUID_A="44444444-4444-4444-4444-444444444901"
UUID_B="44444444-4444-4444-4444-444444444902"
EMAIL_A="user_a_opt024@samay.test"
EMAIL_B="user_b_opt024@samay.test"
PW="Pass1234!"

cleanup() {
  svc_delete_quiet "events?created_by_user_id=in.($UUID_A,$UUID_B)"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B)"
  for uid in $UUID_A $UUID_B; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()  { echo "  ✅ PASS: $1"; ((PASS++)); }
nok() { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info(){ echo "    ℹ️  $1"; }
h1()  { echo ""; echo "━━━ $1 ━━━"; }

# PostgREST RPC responses carry whitespace after JSON punctuation (`{"id": "…"}`);
# greps in this file expect compact JSON, so normalize before use (opt-016
# pattern — added 2026-09-08 after the reset surfaced the spacing drift).
norm_json() {
  sed -E 's/([][,{}:])[[:space:]]+/\1/g; s/[[:space:]]+([][,{}:])/\1/g'
}

anon_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d "$2"
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
svc_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}
rpc_create_event() {
  local t=$1; shift
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/create_event" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$1" | norm_json
}
rpc_seats_used() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/event_seats_used" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -d "$1" | norm_json
}

h1 "SETUP: users A (free) + B (outsider)"
trap cleanup EXIT
cleanup

for pair in "A $UUID_A $EMAIL_A" "B $UUID_B $EMAIL_B"; do
  set -- $pair
  name=$1; uid=$2; mail=$3
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$mail\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$uid\"}")
  if echo "$resp" | grep -q '"id"'; then ok "Created auth user $name"; else nok "Create user $name"; fi
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"user_${name}_opt024\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":500}" > /dev/null
done
ok "Inserted public.users rows (both default entitlement free)"

TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ]; then ok "Obtained token for A"; else nok "No token for A"; fi

# =========================================================================
# TEST A — free tier: capacity above 7 rejected
# =========================================================================
h1 "TEST A — free creator cannot exceed 7 seats"

BASE='{"p_name":"Cap A","p_description":null,"p_type":"casual","p_cover_url":null,"p_group_id":null,"p_location_name":null,"p_location_lat":null,"p_location_lng":null,"p_starts_at":"2026-12-31T23:00:00Z","p_ends_at":"2027-01-01T01:00:00Z","p_join_mode":"open","p_preshards_pool":0,"p_preshards_cap_per_user":null,"p_preshards_remainder_action":null'
resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_capacity\":8}")
if echo "$resp" | grep -qi "capacity_exceeds_tier"; then
  ok "capacity 8 on free tier rejected (capacity_exceeds_tier)"
else
  nok "capacity 8 should be rejected: $(echo "$resp" | head -c 120)"
fi

# =========================================================================
# TEST B — free tier: capacity 7 accepted, host seat + capacity frozen
# =========================================================================
h1 "TEST B — free creator at capacity 7"
resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_capacity\":7}")
EV1=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$EV1" ]; then ok "Created event $EV1 at capacity 7"; else nok "Event not created: $(echo "$resp" | head -c 160)"; fi

if [ -n "$EV1" ]; then
  row=$(svc_get "events?id=eq.$EV1&select=capacity")
  if echo "$row" | grep -q '"capacity":7'; then
    ok "events.capacity frozen at 7"
  else
    nok "capacity not 7: $row"
  fi

  host=$(svc_get "event_hosts?event_id=eq.$EV1&select=user_id,role")
  if echo "$host" | grep -q "$UUID_A" && echo "$host" | grep -q '"role":"host"'; then
    ok "Creator host row created in event_hosts"
  else
    nok "host row missing: $host"
  fi

  seats=$(rpc_seats_used "{\"p_event_id\":\"$EV1\"}")
  if echo "$seats" | grep -q '1'; then
    ok "event_seats_used = 1 (host seat reserved)"
  else
    nok "event_seats_used expected 1: $seats"
  fi
fi

# =========================================================================
# TEST C — PRO subscription: cap lifts to 56
# =========================================================================
h1 "TEST C — PRO creator cap = 56"
svc_patch "users?id=eq.$UUID_A" '{"subscription_tier":"pro"}' > /dev/null
ok "Raised A subscription_tier to pro (service_role)"

resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_capacity\":56}")
EV2=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$EV2" ]; then ok "Created event at capacity 56 (pro)"; else nok "pro cap-56 create failed: $(echo "$resp" | head -c 160)"; fi

resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_capacity\":57}")
if echo "$resp" | grep -qi "capacity_exceeds_tier"; then
  ok "capacity 57 on pro rejected (capacity_exceeds_tier)"
else
  nok "capacity 57 should be rejected on pro: $(echo "$resp" | head -c 120)"
fi

# =========================================================================
# TEST D — direct service_role insert without capacity gets the default
# =========================================================================
h1 "TEST D — svc insert without capacity defaults + seat count"
svc_post "events" "{\"id\":\"44444444-4444-4444-4444-444444444903\",\"name\":\"NoCap\",\"type\":\"casual\",\"created_by_user_id\":\"$UUID_B\",\"group_id\":null,\"starts_at\":\"2026-12-31T23:00:00Z\",\"ends_at\":\"2027-01-01T01:00:00Z\",\"join_mode\":\"open\",\"preshards_pool\":0,\"status\":\"upcoming\"}" > /dev/null
row=$(svc_get "events?id=eq.44444444-4444-4444-4444-444444444903&select=capacity")
if echo "$row" | grep -q '"capacity":7'; then
  ok "svc insert without capacity defaults to 7 (creator free)"
else
  nok "default capacity not 7: $row"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  RESULTS: PASS=$PASS FAIL=$FAIL"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
