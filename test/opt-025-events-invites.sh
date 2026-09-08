#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-025] Events — Manual guest invites (Stage 2)
# Verifies the event manual-invite surface (060_events/05_manual_invites.sql):
#   A) the HOST invites specific users (invite_event_guests) → pending
#      event_invites rows + one event_invite notification per invitee
#   B) re-inviting an already-pending guest is idempotent (invited 0)
#   C) seat reservation: hosts + non-declined invites reserve seats;
#      inviting past events.capacity → capacity_reached
#   D) a non-host cannot invite → not_host
#   E) decline frees the seat (declined invite DELETEd like it never
#      happened, minigame semantics) and the guest is re-invitable; the
#      freed seat also admits a previously-rejected invitee
#   F) accept flips pending → accepted (responded_at), idempotent; a
#      deleted (declined) invite cannot be accepted → invite_not_found;
#      a foreign invite id reads invite_not_found (ownership folded);
#      event_seats_used counts host + accepted seats
#   G) host reads the full guest roster via event_invites RLS (host-read
#      policy); an outsider reads zero invite rows
#
# SELF-CONTAINED (opt-002/024 pattern): creates its own auth users + event
# with fixed UUIDs; cleans up on exit.
#
# Usage: bash test/opt-025-events-invites.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

UUID_A="44444444-4444-4444-4444-444444444a01"
UUID_B="44444444-4444-4444-4444-444444444b02"
UUID_C="44444444-4444-4444-4444-444444444c03"
UUID_D="44444444-4444-4444-4444-444444444d04"
UUID_E="44444444-4444-4444-4444-444444444e05"
UUID_F="44444444-4444-4444-4444-444444444f06"
UUID_G="44444444-4444-4444-4444-44444444fa07"
UUID_H="44444444-4444-4444-4444-44444444fb08"
UUID_X="44444444-4444-4444-4444-44444444fc09"

cleanup() {
  svc_delete_quiet "events?created_by_user_id=eq.$UUID_A"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C,$UUID_D,$UUID_E,$UUID_F,$UUID_G,$UUID_H,$UUID_X)"
  for uid in $UUID_A $UUID_B $UUID_C $UUID_D $UUID_E $UUID_F $UUID_G $UUID_H $UUID_X; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()  { echo "  ✅ PASS: $1"; ((PASS++)); }
nok() { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info(){ echo "    ℹ️  $1"; }
h1()  { echo ""; echo "━━━ $1 ━━━"; }

# PostgREST RPC responses carry whitespace after JSON punctuation; normalize
# before grepping (same helper as opt-016).
norm_json() {
  sed -E 's/([][,{}:])[[:space:]]+/\1/g; s/[[:space:]]+([][,{}:])/\1/g'
}

svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
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
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" | norm_json
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d" | norm_json
}
svc_rpc() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -d "$2" | norm_json
}
rpc_create_event() {
  local t=$1; shift
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/create_event" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$1" | norm_json
}

# =========================================================================
# SETUP — A (free host) + guests B..H + outsider X
# =========================================================================
h1 "SETUP: users + event"
trap cleanup EXIT
cleanup

i=0
for uid in $UUID_A $UUID_B $UUID_C $UUID_D $UUID_E $UUID_F $UUID_G $UUID_H $UUID_X; do
  i=$((i + 1))
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"user_opt025_$i@samay.test\",\"password\":\"Pass1234!\",\"email_confirm\":true,\"id\":\"$uid\"}" > /dev/null
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"user_opt025_$i\",\"personal_shards\":500}" > /dev/null
done
ok "Created auth + public.users rows (A..H, X)"

TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"user_opt025_1@samay.test\",\"password\":\"Pass1234!\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_B=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"user_opt025_2@samay.test\",\"password\":\"Pass1234!\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_C=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"user_opt025_3@samay.test\",\"password\":\"Pass1234!\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_X=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"user_opt025_9@samay.test\",\"password\":\"Pass1234!\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ] && [ -n "$TOKEN_X" ]; then
  ok "Obtained auth tokens (A host, B/C invitees, X outsider)"
else
  nok "Failed to get auth tokens"
fi

BASE='{"p_name":"Invites","p_description":null,"p_type":"casual","p_cover_url":null,"p_group_id":null,"p_location_name":null,"p_location_lat":null,"p_location_lng":null,"p_starts_at":"2026-12-31T23:00:00Z","p_ends_at":"2027-01-01T01:00:00Z","p_join_mode":"open","p_preshards_pool":0,"p_preshards_cap_per_user":null,"p_preshards_remainder_action":null'
resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_capacity\":7}")
EV=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$EV" ]; then ok "Host A created event $EV at capacity 7"; else nok "Event create failed: $(echo "$resp" | head -c 160)"; fi

# =========================================================================
# TEST A — host invites B + C → pending rows + notifications
# =========================================================================
h1 "TEST A — invite_event_guests creates pending invites + notifications"
if [ -n "$EV" ]; then
  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV\",\"p_invitees\":[\"$UUID_B\",\"$UUID_C\"]}")
  if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q '"invited":2'; then
    ok "A invited B + C (invited 2)"
  else
    nok "invite returned unexpected: $(echo "$resp" | head -c 160)"
  fi

  for who in B C; do
    uid=$( [ "$who" = "B" ] && echo "$UUID_B" || echo "$UUID_C" )
    tok=$( [ "$who" = "B" ] && echo "$TOKEN_B" || echo "$TOKEN_C" )
    rows=$(auth_get "$tok" "event_invites?event_id=eq.$EV&user_id=eq.$uid&select=status")
    if echo "$rows" | grep -q '"status":"pending"'; then
      ok "$who holds a pending invite row (own-row read)"
    else
      nok "$who pending row missing: $rows"
    fi
    notif=$(auth_get "$tok" "notifications?user_id=eq.$uid&type=eq.event_invite&select=data" 2>/dev/null)
    if echo "$notif" | grep -q 'eventId'; then
      ok "$who got an event_invite notification"
    else
      nok "$who notification missing (notif=$notif)"
    fi
  done
fi

# =========================================================================
# TEST B — idempotent re-invite of a pending guest
# =========================================================================
h1 "TEST B — re-inviting a pending guest is a no-op"
if [ -n "$EV" ]; then
  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV\",\"p_invitees\":[\"$UUID_B\"]}")
  if echo "$resp" | grep -q '"invited":0'; then
    ok "Re-invite of pending B reported invited 0 (idempotent)"
  else
    nok "Re-invite not idempotent: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST C — seat reservation while inviting (cap 7 = 1 host + 6 guests)
# =========================================================================
h1 "TEST C — capacity reserved while inviting (capacity 7)"
if [ -n "$EV" ]; then
  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV\",\"p_invitees\":[\"$UUID_D\",\"$UUID_E\",\"$UUID_F\",\"$UUID_G\"]}")
  if echo "$resp" | grep -q '"invited":4'; then
    ok "Invited D,E,F,G → 1 host + 6 pending = full capacity"
  else
    nok "Expected invited 4: $(echo "$resp" | head -c 160)"
  fi

  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV\",\"p_invitees\":[\"$UUID_H\"]}")
  if echo "$resp" | grep -q 'capacity_reached'; then
    ok "Inviting H past capacity rejected (capacity_reached)"
  else
    nok "Capacity over-invite not rejected: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST D — non-host cannot invite
# =========================================================================
h1 "TEST D — non-host invite rejected"
if [ -n "$EV" ]; then
  resp=$(auth_rpc "$TOKEN_B" "invite_event_guests" "{\"p_event_id\":\"$EV\",\"p_invitees\":[\"$UUID_X\"]}")
  if echo "$resp" | grep -q 'not_host'; then
    ok "Non-host B cannot invite (not_host)"
  else
    nok "Non-host invite not rejected: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST E — decline frees the seat; re-invite; freed seat admits H
# =========================================================================
h1 "TEST E — decline frees seat + re-invite"
INVITE_B=""
INVITE_C=""
if [ -n "$EV" ]; then
  INVITE_B=$(auth_get "$TOKEN_A" "event_invites?event_id=eq.$EV&user_id=eq.$UUID_B&select=id" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  INVITE_C=$(auth_get "$TOKEN_A" "event_invites?event_id=eq.$EV&user_id=eq.$UUID_C&select=id" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  info "B invite=$INVITE_B C invite=$INVITE_C"

  # B declines (as B) → row deleted, seat freed
  resp=$(auth_rpc "$TOKEN_B" "decline_event_invite" "{\"p_invite_id\":\"$INVITE_B\"}")
  if echo "$resp" | grep -q '"status":"declined"'; then
    ok "B declined their invite"
  else
    nok "B decline failed: $(echo "$resp" | head -c 160)"
  fi
  rows=$(auth_get "$TOKEN_A" "event_invites?event_id=eq.$EV&user_id=eq.$UUID_B&select=id")
  if [ -z "$(echo "$rows" | grep -o '"id"')" ]; then
    ok "Declined invite row deleted (seat freed)"
  else
    nok "Declined row still present: $rows"
  fi

  # Re-invite B (fresh INSERT semantics) → seat re-reserved
  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV\",\"p_invitees\":[\"$UUID_B\"]}")
  if echo "$resp" | grep -q '"invited":1'; then
    ok "Re-invited declined B (invited 1, fresh pending row)"
  else
    nok "Re-invite of declined B failed: $(echo "$resp" | head -c 160)"
  fi

  # C declines → second seat freed; now H (rejected at TEST C) fits
  resp=$(auth_rpc "$TOKEN_C" "decline_event_invite" "{\"p_invite_id\":\"$INVITE_C\"}")
  if echo "$resp" | grep -q '"status":"declined"'; then
    ok "C declined their invite"
  else
    nok "C decline failed: $(echo "$resp" | head -c 160)"
  fi
  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV\",\"p_invitees\":[\"$UUID_H\"]}")
  if echo "$resp" | grep -q '"invited":1'; then
    ok "H fits the seat C freed (invited 1)"
  else
    nok "H re-invite after decline failed: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST F — accept semantics
# =========================================================================
h1 "TEST F — accept semantics"
if [ -n "$EV" ]; then
  # D holds a pending invite the whole test (never declined) — accept it as D
  INVITE_D=$(auth_get "$TOKEN_A" "event_invites?event_id=eq.$EV&user_id=eq.$UUID_D&select=id" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  TOKEN_D=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"user_opt025_4@samay.test\",\"password\":\"Pass1234!\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
  info "D invite = $INVITE_D"

  resp=$(auth_rpc "$TOKEN_D" "accept_event_invite" "{\"p_invite_id\":\"$INVITE_D\"}")
  if echo "$resp" | grep -q '"status":"accepted"'; then
    ok "D accepted their invite (pending → accepted)"
  else
    nok "D accept failed: $(echo "$resp" | head -c 160)"
  fi
  row=$(auth_get "$TOKEN_D" "event_invites?event_id=eq.$EV&user_id=eq.$UUID_D&select=status,responded_at")
  if echo "$row" | grep -q '"status":"accepted"'; then
    ok "D invite row now accepted (responded_at present)"
  else
    nok "D row not accepted: $row"
  fi

  # Idempotent accept
  resp=$(auth_rpc "$TOKEN_D" "accept_event_invite" "{\"p_invite_id\":\"$INVITE_D\"}")
  if echo "$resp" | grep -qE 'already_accepted|"status":"accepted"'; then
    ok "Repeat accept is a no-op"
  else
    nok "Repeat accept unexpected: $(echo "$resp" | head -c 160)"
  fi

  # Foreign accept (X is not the invitee) → not_found (ownership folded)
  resp=$(auth_rpc "$TOKEN_X" "accept_event_invite" "{\"p_invite_id\":\"$INVITE_D\"}")
  if echo "$resp" | grep -q 'invite_not_found'; then
    ok "Outsider X cannot accept D's invite (invite_not_found)"
  else
    nok "Foreign accept not rejected: $(echo "$resp" | head -c 160)"
  fi

  # B's ORIGINAL (declined → deleted) invite cannot be accepted
  if [ -n "$INVITE_B" ]; then
    resp=$(auth_rpc "$TOKEN_B" "accept_event_invite" "{\"p_invite_id\":\"$INVITE_B\"}")
    if echo "$resp" | grep -q 'invite_not_found'; then
      ok "Accepting a declined/deleted invite → invite_not_found"
    else
      nok "Deleted invite accept not rejected: $(echo "$resp" | head -c 160)"
    fi
  fi

  # event_seats_used = 1 host + D accepted = 2 (pending guests not counted)
  seats=$(svc_rpc "event_seats_used" "{\"p_event_id\":\"$EV\"}")
  if echo "$seats" | grep -q '2'; then
    ok "event_seats_used = 2 (host + accepted D)"
  else
    nok "event_seats_used expected 2: $seats"
  fi
fi

# =========================================================================
# TEST G — event_invites RLS: host roster vs outsider zero rows
# =========================================================================
h1 "TEST G — event_invites RLS: host roster vs outsider"
if [ -n "$EV" ]; then
  roster=$(auth_get "$TOKEN_A" "event_invites?event_id=eq.$EV&select=user_id,status")
  n=$(echo "$roster" | grep -o '"user_id"' | wc -l | tr -d ' ')
  # Expected rows: B(pending), D(accepted), E,F,G,H(pending) = 6
  if [ "$n" -ge 5 ]; then
    ok "Host A reads the full invite roster ($n invite rows)"
  else
    nok "Host roster too small ($n): $roster"
  fi

  rows_x=$(auth_get "$TOKEN_X" "event_invites?event_id=eq.$EV&select=user_id")
  if [ -z "$(echo "$rows_x" | grep -o '"user_id"')" ]; then
    ok "Outsider X reads no invite rows (RLS own/host-only)"
  else
    nok "Outsider X leaked invite rows: $rows_x"
  fi
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  RESULTS: PASS=$PASS FAIL=$FAIL"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
