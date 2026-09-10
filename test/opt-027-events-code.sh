#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-027] Events — Rotating attendance code (Stage 4)
# Verifies the attendance-code surface (060_events/07_code.sql):
#   A) get_my_code issues a per-attendee secret + a deterministic 24-hex
#      code for the current 10-s time window (authenticator style)
#   B) the code is STABLE within the window and DIFFERS across users; the
#      event_code helper reproduces the server code and the next window
#      yields a different code
#   C) gates: an outsider is not_invited for issue; only host/staff can
#      validate (not_host); a non-attendee cannot get a code; a PENDING
#      invitee is NOT an attendee — no code, never confirmable (2026-09-09)
#   D) not_in_window before activation (qr.activation_minutes_before)
#   E) staff are attendees (issue their own code; host confirms them once)
#   F) guest confirmation flips event_invites to attended, recorded in
#      event_attendances, single-confirmation (already_scanned)
#   G) malformed / unmatched codes → invalid_code
#   H) the per-attendee secret never leaks through the REST surface
#
# SELF-CONTAINED (opt-024/025/026 pattern): creates its own auth users +
# events with fixed UUIDs; cleans up on exit.
#
# Usage: bash test/opt-027-events-code.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

UUID_A="66666666-6666-6666-6666-66666667a001"
UUID_B="66666666-6666-6666-6666-66666667b002"
UUID_H="66666666-6666-6666-6666-66666667c003"
UUID_X="66666666-6666-6666-6666-66666667d004"
UUID_P="66666666-6666-6666-6666-66666667e005"

cleanup() {
  svc_delete_quiet "events?created_by_user_id=eq.$UUID_A"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_H,$UUID_X,$UUID_P)"
  for uid in $UUID_A $UUID_B $UUID_H $UUID_X $UUID_P; do
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
svc_patch() {
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
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
# field_of <json> <field> — extracts a json string field value
field_of() {
  echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}
# num_field_of <json> <field> — extracts a non-string json number field
num_field_of() {
  echo "$1" | grep -o "\"$2\":[0-9]*" | head -1 | cut -d':' -f2
}

# =========================================================================
# SETUP — A (host), B (staff), H (guest), X (outsider)
# =========================================================================
h1 "SETUP: users + events"
trap cleanup EXIT
cleanup

i=0
for uid in $UUID_A $UUID_B $UUID_H $UUID_X $UUID_P; do
  i=$((i + 1))
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"user_opt027_$i@samay.test\",\"password\":\"Pass1234!\",\"email_confirm\":true,\"id\":\"$uid\"}" > /dev/null
  svc_post "users" "{\"id\":\"$uid\",\"username\":\"user_opt027_$i\",\"personal_shards\":500}" > /dev/null
done
ok "Created auth + public.users rows (A, B, H, X)"

token_of() { # token_of <email-number>
  curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"user_opt027_$1@samay.test\",\"password\":\"Pass1234!\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}
TOKEN_A=$(token_of 1)
TOKEN_B=$(token_of 2)
TOKEN_H=$(token_of 3)
TOKEN_X=$(token_of 4)
TOKEN_P=$(token_of 5)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_H" ] && [ -n "$TOKEN_X" ] \
   && [ -n "$TOKEN_P" ]; then
  ok "Obtained auth tokens (A host, B staff, H guest, X outsider, P pending)"
else
  nok "Failed to get auth tokens"
fi

BASE='{"p_name":"Code","p_description":null,"p_type":"casual","p_cover_url":null,"p_group_id":null,"p_location_name":null,"p_location_lat":null,"p_location_lng":null,"p_join_mode":"open","p_preshards_pool":0,"p_preshards_cap_per_user":null,"p_preshards_remainder_action":null'

# EV2 is created INSIDE the code activation window (starts 10 min ago, ends in
# 2h) so codes issue + validate.
START2=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)
END2=$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)
resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_starts_at\":\"$START2\",\"p_ends_at\":\"$END2\",\"p_capacity\":7}")
EV2=$(field_of "$resp" id)
# EVF starts in 60 min — OUTSIDE the 30-min activation window.
STARTF=$(date -u -v+60M +%Y-%m-%dT%H:%M:%SZ)
ENDF=$(date -u -v+4H +%Y-%m-%dT%H:%M:%SZ)
resp=$(rpc_create_event "$TOKEN_A" "$BASE,\"p_starts_at\":\"$STARTF\",\"p_ends_at\":\"$ENDF\",\"p_capacity\":7}")
EVF=$(field_of "$resp" id)
if [ -n "$EV2" ] && [ -n "$EVF" ]; then
  ok "Host A created in-window event $EV2 + future event $EVF"
else
  nok "Event create failed: $resp"
fi

if [ -n "$EV2" ]; then
  resp=$(auth_rpc "$TOKEN_A" "designate_event_staff" "{\"p_event_id\":\"$EV2\",\"p_staff_ids\":[\"$UUID_B\"]}")
  if echo "$resp" | grep -q '"added":1'; then
    ok "A designated B as staff on $EV2"
  else
    nok "B designate failed: $resp"
  fi
  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV2\",\"p_invitees\":[\"$UUID_H\"]}")
  if echo "$resp" | grep -q '"invited":1'; then
    ok "A invited H to $EV2"
  else
    nok "invite H failed: $resp"
  fi
  INVITE_H=$(svc_get "event_invites?event_id=eq.$EV2&user_id=eq.$UUID_H&select=id")
  INVITE_H=$(field_of "$INVITE_H" id)
  if [ -n "$INVITE_H" ]; then
    resp=$(auth_rpc "$TOKEN_H" "accept_event_invite" "{\"p_invite_id\":\"$INVITE_H\"}")
    if echo "$resp" | grep -q '"status":"accepted"'; then
      ok "H accepted their invite (attendee)"
    else
      nok "H accept failed: $resp"
    fi
  else
    nok "H invite row not found"
  fi

  resp=$(auth_rpc "$TOKEN_A" "invite_event_guests" "{\"p_event_id\":\"$EV2\",\"p_invitees\":[\"$UUID_P\"]}")
  if echo "$resp" | grep -q '"invited":1'; then
    ok "A invited P to $EV2 (left PENDING on purpose)"
  else
    nok "invite P failed: $resp"
  fi
fi

# =========================================================================
# TEST A/B — code issuance + determinism + per-user distinctness
# =========================================================================
h1 "TEST A/B — get_my_code (24-hex, 10-s window, deterministic)"
SECRET_A="" CODE_A="" SECRET_H="" CODE_H="" CTR_A=""
if [ -n "$EV2" ]; then
  resp=$(auth_rpc "$TOKEN_A" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  CODE_A=$(field_of "$resp" code)
  SECRET_A=$(field_of "$resp" secret)
  CTR_A=$(num_field_of "$resp" counter)
  WS=$(num_field_of "$resp" windowSeconds)
  if echo "$CODE_A" | grep -qE '^[0-9a-f]{24}$' \
     && echo "$SECRET_A" | grep -qE '^[0-9a-f]{64}$' \
     && [ "$WS" = "10" ] && [ -n "$CTR_A" ]; then
    ok "Host A got a 24-hex code + 64-hex secret (10-s window, counter $CTR_A)"
  else
    nok "get_my_code(A) malformed: $resp"
  fi

  # Server clock anchor (2026-09-09): get_my_code returns the SERVER's current
  # time in ms so the device can offset its (possibly skewed) wall clock and
  # derive the same rotation lattice as the server — no device-epoch counters.
  SNOW=$(num_field_of "$resp" serverNowMs)
  WSTART=$(num_field_of "$resp" windowStart)
  WEND=$(num_field_of "$resp" windowEnd)
  if [ -n "$SNOW" ] && echo "$SNOW" | grep -qE '^[0-9]+$'; then
    ok "get_my_code returns serverNowMs as a number ($SNOW)"
  else
    nok "serverNowMs missing/not a number: $resp"
  fi
  if [ -n "$SNOW" ] && [ -n "$WSTART" ] && [ -n "$WEND" ] \
     && [ "$SNOW" -ge $((WSTART * 1000)) ] && [ "$SNOW" -lt $((WEND * 1000)) ]; then
    ok "serverNowMs is inside the issued window (windowStart*1000 <= serverNowMs < windowEnd*1000)"
  else
    nok "serverNowMs outside its window: serverNowMs=$SNOW start=$WSTART end=$WEND"
  fi

  resp2=$(auth_rpc "$TOKEN_A" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  CODE_A2=$(field_of "$resp2" code)
  if [ -n "$CODE_A" ] && [ "$CODE_A" = "$CODE_A2" ]; then
    ok "Two calls inside the same window return the SAME code (no rotation churn)"
  else
    nok "Code changed between same-window calls: $CODE_A vs $CODE_A2"
  fi

  resp=$(auth_rpc "$TOKEN_H" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  CODE_H=$(field_of "$resp" code)
  SECRET_H=$(field_of "$resp" secret)
  if echo "$CODE_H" | grep -qE '^[0-9a-f]{24}$' && [ "$CODE_H" != "$CODE_A" ] \
     && [ "$SECRET_H" != "$SECRET_A" ]; then
    ok "Guest H got their OWN distinct code + secret (attendees differ)"
  else
    nok "Guest H code/secret not distinct: $resp"
  fi

  if [ -n "$SECRET_A" ] && [ -n "$CTR_A" ]; then
    derived=$(svc_rpc "event_code" "{\"p_secret\":\"$SECRET_A\",\"p_counter\":$CTR_A}")
    deriv_code=$(echo "$derived" | tr -d '"')
    if echo "$derived" | grep -qE '^"?[0-9a-f]{24}"?$'; then
      ok "event_code helper reproduces a 24-hex code"
    else
      nok "event_code helper output odd: $derived"
    fi
    if [ "$deriv_code" = "$CODE_A" ]; then
      ok "Server-derived code for window $CTR_A == the code the app shows (server-authoritative)"
    else
      nok "Derivation mismatch: helper=$deriv_code code=$CODE_A"
    fi
    next=$(svc_rpc "event_code" "{\"p_secret\":\"$SECRET_A\",\"p_counter\":$((CTR_A + 1))}")
    next_code=$(echo "$next" | tr -d '"')
    if [ -n "$next_code" ] && [ "$next_code" != "$CODE_A" ]; then
      ok "The NEXT 10-s window derives a DIFFERENT code (regeneration by time)"
    else
      nok "Next-window code did not change: $next"
    fi
  fi
fi

# =========================================================================
# TEST C — gates: not_invited, not_host (issue + validate)
# =========================================================================
h1 "TEST C — outsider/attendee gates"
if [ -n "$EV2" ] && [ -n "$CODE_A" ]; then
  resp=$(auth_rpc "$TOKEN_X" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  if echo "$resp" | grep -q 'not_invited'; then
    ok "Outsider X cannot issue a code (not_invited)"
  else
    nok "X issue not rejected: $resp"
  fi

  resp=$(auth_rpc "$TOKEN_X" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$CODE_A\"}")
  if echo "$resp" | grep -q 'not_host'; then
    ok "Outsider X cannot validate a code (not_host)"
  else
    nok "X validate not rejected: $resp"
  fi

  resp=$(auth_rpc "$TOKEN_H" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$CODE_A\"}")
  if echo "$resp" | grep -q 'not_host'; then
    ok "Attendee H (not host/staff) cannot validate (not_host)"
  else
    nok "H validate not rejected: $resp"
  fi
fi

# =========================================================================
# TEST C2 — a PENDING invitee is NOT an attendee (2026-09-09 security fix)
# A pending invitee may only accept/decline: no code, and never confirmable.
# =========================================================================
h1 "TEST C2 — pending invitee cannot mint or be confirmed"
if [ -n "$EV2" ]; then
  # Fresh pending invitee P cannot issue a code.
  resp=$(auth_rpc "$TOKEN_P" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  if echo "$resp" | grep -q 'not_invited'; then
    ok "Pending invitee P cannot issue a code (not_invited)"
  else
    nok "Pending P issue not rejected: $resp"
  fi

  # Leak scenario: mint a code while temporarily accepted, then revert the
  # invite to pending. A leaked/rotated code must never confirm a pending
  # invitee (no event_attendances row, invite stays pending).
  P_INVITE=$(svc_get "event_invites?event_id=eq.$EV2&user_id=eq.$UUID_P&select=id")
  P_INVITE=$(field_of "$P_INVITE" id)
  P_CODE=""
  if [ -n "$P_INVITE" ]; then
    resp=$(auth_rpc "$TOKEN_P" "accept_event_invite" "{\"p_invite_id\":\"$P_INVITE\"}")
    if echo "$resp" | grep -q '"status":"accepted"'; then
      resp=$(auth_rpc "$TOKEN_P" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
      P_CODE=$(field_of "$resp" code)
    fi
  fi
  if echo "$P_CODE" | grep -qE '^[0-9a-f]{24}$'; then
    ok "P minted a code while temporarily accepted (leak scenario seeded)"
  else
    nok "P leak-scenario code not minted: $resp"
  fi
  svc_patch "event_invites?event_id=eq.$EV2&user_id=eq.$UUID_P" '{"status":"pending"}'

  resp=$(auth_rpc "$TOKEN_P" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  if echo "$resp" | grep -q 'not_invited'; then
    ok "Reverted-to-pending P can no longer issue a code (not_invited)"
  else
    nok "Pending P issue not rejected after revert: $resp"
  fi

  if [ -n "$P_CODE" ]; then
    resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$P_CODE\"}")
    if echo "$resp" | grep -q 'not_invited'; then
      ok "Host cannot confirm a pending invitee from a leaked code (not_invited)"
    else
      nok "Pending P code was confirmable: $resp"
    fi
    att=$(svc_get "event_attendances?event_id=eq.$EV2&user_id=eq.$UUID_P&select=id")
    if ! echo "$att" | grep -q '"id"'; then
      ok "No event_attendances row written for pending P"
    else
      nok "event_attendances row leaked for P: $att"
    fi
    inv=$(svc_get "event_invites?event_id=eq.$EV2&user_id=eq.$UUID_P&select=status")
    if echo "$inv" | grep -q '"status":"pending"'; then
      ok "P's invite row stays pending after the refused scan"
    else
      nok "P invite not pending: $inv"
    fi
  fi
fi

# =========================================================================
# TEST D — not_in_window before activation (EVF starts in 60 min)
# =========================================================================
h1 "TEST D — not_in_window on a future event"
if [ -n "$EVF" ]; then
  resp=$(auth_rpc "$TOKEN_A" "get_my_code" "{\"p_event_id\":\"$EVF\"}")
  if echo "$resp" | grep -q 'not_in_window'; then
    ok "Issue before the activation window → not_in_window"
  else
    nok "Future-event issue not blocked: $resp"
  fi
  resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EVF\",\"p_code\":\"000000000000000000000000\"}")
  if echo "$resp" | grep -q 'not_in_window'; then
    ok "Validate before the activation window → not_in_window"
  else
    nok "Future-event validate not blocked: $resp"
  fi
fi

# =========================================================================
# TEST E — staff are attendees: B issues, host confirms once
# =========================================================================
h1 "TEST E — staff attendee parity + single confirmation"
CODE_B=""
if [ -n "$EV2" ]; then
  resp=$(auth_rpc "$TOKEN_B" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  CODE_B=$(field_of "$resp" code)
  if echo "$CODE_B" | grep -qE '^[0-9a-f]{24}$'; then
    ok "Staff B (no invite row) issues their own code"
  else
    nok "Staff B code issue failed: $resp"
  fi

  if [ -n "$CODE_B" ]; then
    resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$CODE_B\"}")
    if echo "$resp" | grep -q '"status":"confirmed"'; then
      ok "Host A confirmed staff B from their code (confirmed)"
    else
      nok "Confirm staff B failed: $resp"
    fi
    att=$(svc_get "event_attendances?event_id=eq.$EV2&user_id=eq.$UUID_B&select=id")
    if echo "$att" | grep -q '"id"'; then
      ok "Attendance recorded for staff B (event_attendances)"
    else
      nok "event_attendances missing for B: $att"
    fi
    resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$CODE_B\"}")
    if echo "$resp" | grep -q 'already_scanned'; then
      ok "Re-validating B's same-window code → already_scanned (single confirmation)"
    else
      nok "B re-validate not blocked: $resp"
    fi
  fi
fi

# =========================================================================
# TEST F — guest confirmation + invite flip + single confirmation
# =========================================================================
h1 "TEST F — guest confirmation (invite → attended)"
if [ -n "$EV2" ] && [ -n "$CODE_H" ]; then
  resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$CODE_H\"}")
  if echo "$resp" | grep -q '"status":"confirmed"'; then
    ok "Host A confirmed guest H from their code (confirmed)"
  else
    nok "Confirm guest H failed: $resp"
  fi
  inv=$(svc_get "event_invites?event_id=eq.$EV2&user_id=eq.$UUID_H&select=status")
  if echo "$inv" | grep -q '"status":"attended"'; then
    ok "H's event_invites row flipped to attended"
  else
    nok "H invite not attended: $inv"
  fi
  resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"$CODE_H\"}")
  if echo "$resp" | grep -q 'already_scanned'; then
    ok "Re-validating H's same-window code → already_scanned"
  else
    nok "H re-validate not blocked: $resp"
  fi

  fresh=$(auth_rpc "$TOKEN_H" "get_my_code" "{\"p_event_id\":\"$EV2\"}")
  if echo "$fresh" | grep -q 'not_invited'; then
    ok "An already-attended H can no longer mint a code (not_invited)"
  else
    nok "Attended H still mints a code: $fresh"
  fi
fi

# =========================================================================
# TEST G — malformed / unmatched codes → invalid_code
# =========================================================================
h1 "TEST G — invalid codes rejected"
if [ -n "$EV2" ]; then
  resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"nothex!\"}")
  if echo "$resp" | grep -q 'invalid_code'; then
    ok "Malformed code rejected (invalid_code)"
  else
    nok "Malformed code accepted: $resp"
  fi
  resp=$(auth_rpc "$TOKEN_A" "validate_code" "{\"p_event_id\":\"$EV2\",\"p_code\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"}")
  if echo "$resp" | grep -q 'invalid_code'; then
    ok "Well-formed but unmatched code rejected (invalid_code)"
  else
    nok "Unmatched code accepted: $resp"
  fi
fi

# =========================================================================
# TEST H — the code secret never leaks through REST
# =========================================================================
h1 "TEST H — secret is not readable via REST"
if [ -n "$EV2" ] && [ -n "$SECRET_A" ]; then
  leak=$(auth_get "$TOKEN_A" "event_code_keys?event_id=eq.$EV2")
  if ! echo "$leak" | grep -q "$SECRET_A"; then
    ok "Attendee A cannot read code secrets through the REST surface"
  else
    nok "Secret leaked via REST: $leak"
  fi
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  RESULTS: PASS=$PASS FAIL=$FAIL"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
