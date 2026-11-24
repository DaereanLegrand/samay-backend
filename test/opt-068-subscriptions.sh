#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-068] Subscription privileges + paid-state helper (237_subscription_expiry)
# -----------------------------------------------------------------------------
#   1) authenticated cannot run apply_subscription_state / grace / downgrade
#   2) authenticated cannot run admin_grant/revoke or reconcile
#   3) authenticated cannot call has_paid_access / effective_tier
#   4) service_role applies a grant and the helper reports paid
#   5) an active grant has a future expiry and the revenuecat source
#
# SELF-CONTAINED (7575… UUID family). Cleanup on exit.
# Usage: bash test/opt-068-subscriptions.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54382/postgres}"

PASS=0
FAIL=0
ok()  { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
h1()  { echo ""; echo "━━━ $1 ━━━"; }
q()   { PGPASSWORD=postgres psql "$PGURL" -Atq -v ON_ERROR_STOP=1 -c "$1"; }

UUID="75757575-7575-4575-8575-757575680001"
EMAIL="sub_opt068@samay.test"
PW="Pass1234!"

cleanup() {
  q "DELETE FROM public.subscription_overrides WHERE user_id = '$UUID';" >/dev/null 2>&1
  q "DELETE FROM public.admin_audit_log WHERE target_id = '$UUID';" >/dev/null 2>&1
  curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$UUID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
  q "DELETE FROM public.users WHERE id = '$UUID';" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

h1 "SETUP: one auth user"
curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID\"}" >/dev/null
q "INSERT INTO public.users (id, username, date_of_birth)
   VALUES ('$UUID', 'opt068_user', '1990-01-01');" >/dev/null

TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[ -n "$TOKEN" ] && ok "user signed in" || { nok "sign-in"; exit 1; }

rpc_code() { # $1 key  $2 token  $3 fn  $4 body
  curl -s -o /dev/null -w '%{http_code}' -X POST "$SUPABASE_URL/rest/v1/rpc/$3" \
    -H "apikey: $1" -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" -d "$4"
}

h1 "1) authenticated cannot run the privileged subscription RPCs"
for fn in apply_subscription_state apply_subscription_grace \
          downgrade_invalid_subscriptions admin_grant_subscription \
          admin_revoke_subscription reconcile_subscription_overrides \
          has_paid_access effective_tier; do
  CODE=$(rpc_code "$ANON_KEY" "$TOKEN" "$fn" '{}')
  case "$CODE" in
    401|403|404) ok "$fn denied to authenticated ($CODE)" ;;
    *) nok "$fn denied to authenticated (got $CODE)" ;;
  esac
done

h1 "2) service_role applies a grant; the helper reports paid"
EXPIRES=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)
CODE=$(rpc_code "$SERVICE_KEY" "$SERVICE_KEY" apply_subscription_state \
  "{\"p_user\":\"$UUID\",\"p_tier\":\"pro\",\"p_expires\":\"$EXPIRES\",\"p_event_type\":\"INITIAL_PURCHASE\"}")
[ "$CODE" = "204" ] || [ "$CODE" = "200" ] && ok "service applies pro" || nok "service apply (got $CODE)"

PAID=$(q "SELECT public.has_paid_access('$UUID')::text;")
SOURCE=$(q "SELECT subscription_source FROM public.users WHERE id = '$UUID';")
FUTURE=$(q "SELECT (subscription_expires_at > now())::text FROM public.users WHERE id = '$UUID';")
if [ "$PAID" = "true" ] && [ "$SOURCE" = "revenuecat" ] && [ "$FUTURE" = "true" ]; then
  ok "paid state is tier + future expiry, source=revenuecat"
else
  nok "paid state (paid=$PAID source=$SOURCE future=$FUTURE)"
fi

REPORT=$(q "SELECT count(*) FROM public.admin_audit_log
  WHERE action = 'subscription_initial_purchase' AND target_id = '$UUID';")
[ "$REPORT" = "1" ] && ok "the grant is audited" || nok "grant audit (count=$REPORT)"

h1 "3) REFUND downgrades immediately"
CODE=$(rpc_code "$SERVICE_KEY" "$SERVICE_KEY" apply_subscription_state \
  "{\"p_user\":\"$UUID\",\"p_tier\":\"free\",\"p_expires\":null,\"p_event_type\":\"REFUND\"}")
PAID=$(q "SELECT public.has_paid_access('$UUID')::text;")
[ "$PAID" = "false" ] && ok "refund clears paid access" || nok "refund paid=$PAID"

echo ""
echo "=================================================="
echo "  OPT-068: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ]
