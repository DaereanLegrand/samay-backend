#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-067] Economy privileges + cancellation window (236_economy_distribution)
# -----------------------------------------------------------------------------
#   1) an authenticated host CANNOT cancel a live/ended event (no refund)
#   2) authenticated callers cannot execute distribute_shards
#   3) authenticated callers cannot execute admin_correct_balance
#   4) the reconciliation report and the cron fallback are service-only
#
# SELF-CONTAINED (7474… UUID family). Cleanup on exit.
# Usage: bash test/opt-067-economy.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0
ok()  { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
h1()  { echo ""; echo "━━━ $1 ━━━"; }
q()   { PGPASSWORD=postgres psql "$PGURL" -Atq -v ON_ERROR_STOP=1 -c "$1"; }

UUID_H="74747474-7474-4474-8474-747474670001"
UUID_A="74747474-7474-4474-8474-747474670002"
EVENT="74747474-7474-4474-8474-747474670101"
EMAIL_H="econ_host_opt067@samay.test"
EMAIL_A="econ_attendee_opt067@samay.test"
PW="Pass1234!"

cleanup() {
  q "DELETE FROM public.event_attendances WHERE event_id = '$EVENT';" >/dev/null 2>&1
  q "DELETE FROM public.event_hosts WHERE event_id = '$EVENT';" >/dev/null 2>&1
  q "DELETE FROM public.shard_ledger WHERE reference_id = '$EVENT';" >/dev/null 2>&1
  q "DELETE FROM public.preshard_ledger WHERE reference_id = '$EVENT';" >/dev/null 2>&1
  q "DELETE FROM public.events WHERE id = '$EVENT';" >/dev/null 2>&1
  for uid in "$UUID_H" "$UUID_A"; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
    q "DELETE FROM public.preshard_ledger WHERE user_id = '$uid';" >/dev/null 2>&1
    q "DELETE FROM public.shard_ledger WHERE user_id = '$uid';" >/dev/null 2>&1
    q "DELETE FROM public.users WHERE id = '$uid';" >/dev/null 2>&1
  done
}
trap cleanup EXIT
cleanup

h1 "SETUP: host + attendee + a live event with a funded pool"
for pair in "H $UUID_H $EMAIL_H" "A $UUID_A $EMAIL_A"; do
  set -- $pair
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$3\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$2\"}" >/dev/null
done
q "INSERT INTO public.users (id, username, date_of_birth, preshards)
   VALUES ('$UUID_H', 'opt067_host', '1990-01-01', 450),
          ('$UUID_A', 'opt067_attendee', '1990-01-01', 0);" >/dev/null
q "INSERT INTO public.preshard_ledger (user_id, delta, reason)
   VALUES ('$UUID_H', 500, 'admin_grant');" >/dev/null
q "INSERT INTO public.preshard_ledger (user_id, delta, reason, reference_id)
   VALUES ('$UUID_H', -50, 'event_pool_set', '$EVENT');" >/dev/null
q "INSERT INTO public.events (id, name, type, created_by_user_id, starts_at, ends_at,
     preshards_pool, capacity, invite_token, status)
   VALUES ('$EVENT', 'opt067 live event', 'juerga', '$UUID_H',
           now() - interval '1 hour', now() + interval '1 hour', 50, 5, 'opt067', 'live');" >/dev/null
q "INSERT INTO public.event_hosts (event_id, user_id, role, preshards_contributed)
   VALUES ('$EVENT', '$UUID_H', 'host', 50);" >/dev/null
q "INSERT INTO public.event_attendances (event_id, user_id)
   VALUES ('$EVENT', '$UUID_A');" >/dev/null

TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_H\",\"password\":\"$PW\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[ -n "$TOKEN" ] && ok "host signed in" || { nok "host sign-in"; exit 1; }

h1 "1) a live event cannot be cancelled by its host"
RESP=$(curl -s -w "\n%{http_code}" -X PATCH \
  "$SUPABASE_URL/rest/v1/events?id=eq.$EVENT" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d '{"status":"cancelled"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" = "400" ] && echo "$BODY" | grep -q "cancel_only_before_start"; then
  ok "cancel is rejected once the event is live (400)"
else
  nok "cancel rejected once live (got $CODE: $BODY)"
fi
BAL=$(q "SELECT preshards FROM public.users WHERE id = '$UUID_H';")
POOL=$(q "SELECT preshards_pool || ':' || preshards_distributed FROM public.events WHERE id = '$EVENT';")
if [ "$BAL" = "450" ] && [ "$POOL" = "50:false" ]; then
  ok "no refund and the pool is untouched"
else
  nok "no refund/pool (balance=$BAL pool=$POOL)"
fi

h1 "2) authenticated callers cannot run the economy admin functions"
for fn in distribute_shards admin_correct_balance economy_ledger_reconciliation distribute_pending_event_shards; do
  RESP=$(curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/$fn" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -d '{}')
  CODE=$(echo "$RESP" | tail -n1)
  case "$CODE" in
    401|403|404) ok "$fn denied to authenticated ($CODE)" ;;
    *) nok "$fn denied to authenticated (got $CODE: $(echo "$RESP" | sed '$d'))" ;;
  esac
done

h1 "3) service_role can run the report and the fallback"
for fn in economy_ledger_reconciliation distribute_pending_event_shards; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$SUPABASE_URL/rest/v1/rpc/$fn" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" -d '{}')
  [ "$CODE" = "200" ] && ok "$fn available to service_role" || nok "$fn service_role (got $CODE)"
done

echo ""
echo "=================================================="
echo "  OPT-067: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ]
