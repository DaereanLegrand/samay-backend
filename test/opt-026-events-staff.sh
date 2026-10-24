#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-026] Events — Host designates staff (Stage 3)
# Verifies the event staff surface (060_events/06_staff.sql):
#   A) the HOST designates specific users as staff (designate_event_staff)
#      → event_hosts rows with role staff; host+staff read the full roster
#      (ep_read_event_access); an outsider reads zero rows
#   B) re-designating an already-privileged user is a no-op (added 0)
#   C) capacity is respected: host + staff seats never exceed events.capacity
#   D) only a role=host member may designate (staff/outsider → not_host)
#   E) remove_event_staff removes a staff row (seat freed, idempotent); the
#      host row can never be removed (host_not_removable)
#   F) converting an ACCEPTED guest to staff is seat-neutral: their invite is
#      deleted and the seat moves into event_hosts (no double count)
#   G) host AND staff are attendees: get_my_code issues staff B their own
#      attendance code (no not_invited) and host A validates it once with
#      validate_code (event_attendances marker; re-validate → already_scanned)
#   H) event_hosts RLS: host/staff read all rows of their event; an outsider
#      reads zero rows
#
# SELF-CONTAINED (opt-024/025 pattern): creates its own auth users + events
# with fixed UUIDs; cleans up on exit.
#
# Usage: bash test/opt-026-events-staff.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

UUID_A="66666666-6666-6666-6666-666666666a01"
UUID_B="66666666-6666-6666-6666-666666666b02"
UUID_C="66666666-6666-6666-6666-666666666c03"
UUID_D="66666666-6666-6666-6666-666666666d04"
UUID_E="66666666-6666-6666-6666-666666666e05"
UUID_F="66666666-6666-6666-6666-666666666f06"
UUID_G="66666666-6666-6666-6666-66666666fa07"
UUID_H="66666666-6666-6666-6666-66666666fb08"
UUID_X="66666666-6666-6666-6666-66666666fc09"

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
# SETUP — A (free host) + candidates B..G, H (invite/conversion), X (outsider)
# =========================================================================
h1 "SETUP: users + events"
trap cleanup EXIT
cleanup

i=0
for uid in $UUID_A $UUID_B $UUID_C $UUID_D $UUID_E $UUID_F $UUID_G $UUID_H $UUID_X; do
  i=$((i + 1))
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"user_opt026_$i@samay.test\",\"password\":\"Pass1234!\",\"email_confirm\":true,\"id\":\"$uid\"}" > /dev/null
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"user_opt026_$i\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":500}" > /dev/null
done
ok "Created auth + public.users rows (A..H, X)"

token_of() { # token_of <email-number>
  curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"user_opt026_$1@samay.test\",\"password\":\"Pass1234!\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}
TOKEN_A=$(token_of 1)
TOKEN_B=$(token_of 2)
TOKEN_D=$(token_of 4)
TOKEN_H=$(token_of 8)
TOKEN_X=$(token_of 9)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_D" ] && [ -n "$TOKEN_H" ] && [ -n "$TOKEN_X" ]; then
  ok "Obtained auth tokens (A host, B/D staff targets, H invitee, X outsider)"
else
  nok "Failed to get auth tokens"
fi

BASE='{"p_name":"Staff","p_description":null,"p_type":"casual","p_cover_url":null,"p_group_id":null,"p_location_name":null,"p_location_lat":null,"p_location_lng":null,"p_join_mode":"open","p_preshards_pool":0,"p_preshards_cap_per_user":null,"p_preshards_remainder_action":null'
resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_starts_at\":\"2026-12-31T23:00:00Z\",\"p_ends_at\":\"2027-01-01T01:00:00Z\",\"p_capacity\":7}")
EV1=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$EV1" ]; then ok "Host A created event $EV1 at capacity 7"; else nok "Event EV1 create failed: $(echo "$resp" | head -c 160)"; fi

# EV2 is created INSIDE the QR activation window (starts 10 min ago, ends in
# 2h) so get_my_code / validate_code accept it.
START2=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)
END2=$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)
resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_starts_at\":\"$START2\",\"p_ends_at\":\"$END2\",\"p_capacity\":7}")
EV2=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$EV2" ]; then ok "Host A created live-window event $EV2 (code issue/validate usable)"; else nok "Event EV2 create failed: $(echo "$resp" | head -c 160)"; fi

# =========================================================================
# TEST A — host designates B + C as staff; host/staff read the roster
# =========================================================================
h1 "TEST A — designate_event_staff + host/staff roster read"
if [ -n "$EV1" ]; then
  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_ids\":[\"$UUID_B\",\"$UUID_C\"]}")
  if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q '"added":2'; then
    ok "A designated B + C as staff (added 2)"
  else
    nok "designate returned unexpected: $(echo "$resp" | head -c 160)"
  fi

  rows=$(svc_get "event_hosts?event_id=eq.$EV1&select=user_id,role")
  cnt=$(echo "$rows" | grep -o '"user_id"' | wc -l | tr -d ' ')
  staff_cnt=$(echo "$rows" | grep -o '"role":"staff"' | wc -l | tr -d ' ')
  if [ "$cnt" -eq 3 ] && [ "$staff_cnt" -eq 2 ]; then
    ok "event_hosts holds 1 host + 2 staff ($cnt rows)"
  else
    nok "event_hosts expected 3 rows/2 staff: $rows"
  fi

  roster_a=$(auth_get "$TOKEN_A" "event_hosts?event_id=eq.$EV1&select=user_id,role")
  n_a=$(echo "$roster_a" | grep -o '"user_id"' | wc -l | tr -d ' ')
  if [ "$n_a" -ge 3 ]; then
    ok "Host A reads the full host+staff roster ($n_a rows, ep_read_event_access)"
  else
    nok "Host A roster too small ($n_a): $roster_a"
  fi

  roster_b=$(auth_get "$TOKEN_B" "event_hosts?event_id=eq.$EV1&select=user_id,role")
  n_b=$(echo "$roster_b" | grep -o '"user_id"' | wc -l | tr -d ' ')
  if [ "$n_b" -ge 3 ]; then
    ok "Staff B also reads the full roster ($n_b rows)"
  else
    nok "Staff B roster too small ($n_b): $roster_b"
  fi
fi

# =========================================================================
# TEST B — re-designating an existing staff member is a no-op
# =========================================================================
h1 "TEST B — idempotent designate"
if [ -n "$EV1" ]; then
  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_ids\":[\"$UUID_C\"]}")
  if echo "$resp" | grep -q '"added":0'; then
    ok "Re-designating staff C reported added 0 (idempotent)"
  else
    nok "Re-designate not idempotent: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST C — capacity respected while designating (cap 7 = 1 host + 6 staff)
# =========================================================================
h1 "TEST C — capacity respected (capacity 7)"
if [ -n "$EV1" ]; then
  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_ids\":[\"$UUID_D\",\"$UUID_E\",\"$UUID_F\"]}")
  if echo "$resp" | grep -q '"added":3'; then
    ok "Designated D,E,F → 1 host + 5 staff"
  else
    nok "Expected added 3: $(echo "$resp" | head -c 160)"
  fi

  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_ids\":[\"$UUID_G\"]}")
  if echo "$resp" | grep -q '"added":1'; then
    ok "G fills the last seat (1 host + 6 staff = 7)"
  else
    nok "G designate failed: $(echo "$resp" | head -c 160)"
  fi

  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_ids\":[\"$UUID_H\"]}")
  if echo "$resp" | grep -q 'capacity_reached'; then
    ok "Designating H past capacity rejected (capacity_reached)"
  else
    nok "Capacity over-designate not rejected: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST D — only a role=host member can designate
# =========================================================================
h1 "TEST D — non-host designate rejected"
if [ -n "$EV1" ]; then
  resp=$(auth_rpc "$TOKEN_B" "designate_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_ids\":[\"$UUID_X\"]}")
  if echo "$resp" | grep -q 'not_host'; then
    ok "Staff B cannot designate (not_host)"
  else
    nok "Staff designate not rejected: $(echo "$resp" | head -c 160)"
  fi

  resp=$(auth_rpc "$TOKEN_X" "designate_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_ids\":[\"$UUID_B\"]}")
  if echo "$resp" | grep -q 'not_host'; then
    ok "Outsider X cannot designate (not_host)"
  else
    nok "Outsider designate not rejected: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST E — remove_event_staff (seat freed, host never removable)
# =========================================================================
h1 "TEST E — remove staff"
if [ -n "$EV1" ]; then
  resp=$(auth_rpc "$TOKEN_A" "remove_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_user_id\":\"$UUID_C\"}")
  if echo "$resp" | grep -q '"status":"ok"'; then
    ok "A removed C from staff"
  else
    nok "remove_event_staff failed: $(echo "$resp" | head -c 160)"
  fi

  rows=$(svc_get "event_hosts?event_id=eq.$EV1&select=user_id,role")
  cnt=$(echo "$rows" | grep -o '"user_id"' | wc -l | tr -d ' ')
  if [ "$cnt" -eq 6 ]; then
    ok "Roster back to 1 host + 5 staff (seat freed, $cnt rows)"
  else
    nok "Roster expected 6 after removal: $rows"
  fi

  resp=$(auth_rpc "$TOKEN_A" "remove_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_user_id\":\"$UUID_C\"}")
  if echo "$resp" | grep -q '"status":"ok"'; then
    ok "Removing an already-removed staff member is idempotent (ok)"
  else
    nok "Idempotent removal failed: $(echo "$resp" | head -c 160)"
  fi

  resp=$(auth_rpc "$TOKEN_A" "remove_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_user_id\":\"$UUID_A\"}")
  if echo "$resp" | grep -q 'host_not_removable'; then
    ok "The host row (A) can never be removed (host_not_removable)"
  else
    nok "Host removal not blocked: $(echo "$resp" | head -c 160)"
  fi

  resp=$(auth_rpc "$TOKEN_D" "remove_event_staff" "{\"p_event_id\":\"$EV1\",\"p_staff_user_id\":\"$UUID_G\"}")
  if echo "$resp" | grep -q 'not_host'; then
    ok "Staff D cannot remove another staff member (not_host)"
  else
    nok "Staff removal not rejected: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST F — accepted guest converted to staff is seat-neutral
# =========================================================================
h1 "TEST F — invite → staff conversion (no double count)"
if [ -n "$EV2" ]; then
  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV2\",\"p_invitees\":[\"$UUID_H\"]}")
  if echo "$resp" | grep -q '"invited":1'; then
    ok "A invited H to EV2"
  else
    nok "invite H failed: $(echo "$resp" | head -c 160)"
  fi

  INVITE_H=$(svc_get "event_invites?event_id=eq.$EV2&user_id=eq.$UUID_H&select=id" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$INVITE_H" ]; then
    resp=$(auth_rpc "$TOKEN_H" "accept_event_invite" "{\"p_invite_id\":\"$INVITE_H\"}")
    if echo "$resp" | grep -q '"status":"accepted"'; then
      ok "H accepted their invite (pending → accepted)"
    else
      nok "H accept failed: $(echo "$resp" | head -c 160)"
    fi
  else
    nok "H invite row not found"
  fi

  seats=$(svc_rpc "event_seats_used" "{\"p_event_id\":\"$EV2\"}")
  if echo "$seats" | grep -q '2'; then
    ok "event_seats_used = 2 (host + accepted H)"
  else
    nok "event_seats_used expected 2: $seats"
  fi

  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV2\",\"p_staff_ids\":[\"$UUID_H\"]}")
  if echo "$resp" | grep -q '"added":1'; then
    ok "A converted accepted guest H into staff"
  else
    nok "H conversion failed: $(echo "$resp" | head -c 160)"
  fi

  left=$(svc_get "event_invites?event_id=eq.$EV2&user_id=eq.$UUID_H&select=id")
  if [ -z "$(echo "$left" | grep -o '"id"')" ]; then
    ok "H's invite row deleted on conversion (seat moved into event_hosts)"
  else
    nok "H invite row still present: $left"
  fi

  hrow=$(svc_get "event_hosts?event_id=eq.$EV2&user_id=eq.$UUID_H&select=role")
  if echo "$hrow" | grep -q '"role":"staff"'; then
    ok "H now holds a staff event_hosts row"
  else
    nok "H staff row missing: $hrow"
  fi

  seats=$(svc_rpc "event_seats_used" "{\"p_event_id\":\"$EV2\"}")
  if echo "$seats" | grep -q '2'; then
    ok "event_seats_used still 2 after conversion (no double count)"
  else
    nok "event_seats_used expected 2 after conversion: $seats"
  fi
fi

# =========================================================================
# TEST G — staff/host are attendees: issue + validate their own code
# =========================================================================
h1 "TEST G — staff generate + are validated (attendee parity)"
if [ -n "$EV2" ]; then
  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV2\",\"p_staff_ids\":[\"$UUID_B\"]}")
  if echo "$resp" | grep -q '"added":1'; then
    ok "A designated B as staff on EV2"
  else
    nok "B designate on EV2 failed: $(echo "$resp" | head -c 160)"
  fi

  resp=$(auth_rpc "$TOKEN_B" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  if echo "$resp" | grep -q '"status":"ok"' && echo "$resp" | grep -q '"code":"'; then
    ok "Staff B can issue an attendance code (no not_invited)"
  else
    nok "Staff B get_my_code failed: $(echo "$resp" | head -c 160)"
  fi
  BCODE=$(echo "$resp" | grep -o '"code":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ -n "$BCODE" ]; then
    resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$BCODE\"}")
    if echo "$resp" | grep -q '"status":"confirmed"'; then
      ok "Host A validated staff B's code (confirmed)"
    else
      nok "validate staff code failed: $(echo "$resp" | head -c 160)"
    fi

    att=$(svc_get "event_attendances?event_id=eq.$EV2&user_id=eq.$UUID_B&select=id")
    if echo "$att" | grep -q '"id"'; then
      ok "Attendance recorded for staff B"
    else
      nok "event_attendances missing for B: $att"
    fi

    resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$BCODE\"}")
    if echo "$resp" | grep -q 'already_scanned'; then
      ok "Re-validating the same code → already_scanned (no double count)"
    else
      nok "Re-validate not blocked: $(echo "$resp" | head -c 160)"
    fi
  fi

  resp=$(auth_rpc "$TOKEN_A" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  if echo "$resp" | grep -q '"status":"ok"'; then
    ok "Host A (host role) can also generate their own attendance code"
  else
    nok "Host A get_my_code failed: $(echo "$resp" | head -c 160)"
  fi
fi

# =========================================================================
# TEST H — event_hosts RLS: outsiders read zero rows
# =========================================================================
h1 "TEST H — RLS: outsider reads zero host rows"
if [ -n "$EV1" ]; then
  rows_x=$(auth_get "$TOKEN_X" "event_hosts?event_id=eq.$EV1&select=user_id")
  if [ -z "$(echo "$rows_x" | grep -o '"user_id"')" ]; then
    ok "Outsider X reads no event_hosts rows on EV1"
  else
    nok "Outsider X leaked host rows: $rows_x"
  fi

  rows_b=$(auth_get "$TOKEN_B" "event_hosts?event_id=eq.$EV2&select=user_id,role")
  n_b2=$(echo "$rows_b" | grep -o '"user_id"' | wc -l | tr -d ' ')
  if [ "$n_b2" -ge 3 ]; then
    ok "Staff B reads the EV2 roster (host + H + B, $n_b2 rows)"
  else
    nok "Staff B EV2 roster too small ($n_b2): $rows_b"
  fi
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  RESULTS: PASS=$PASS FAIL=$FAIL"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
