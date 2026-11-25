#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-070] Group theme — tier gate, control mode, rate limit, RLS (240)
# -----------------------------------------------------------------------------
#   1) a free host cannot use an RGB palette (theme_requires_paid)
#   2) a member may change a paid group theme under `everyone`
#   3) `host_only` rejects a member but allows the host
#   4) `locked` rejects every colour change
#   5) 3 changes/min/group, the 4th is rate-limited
#   6) non-members cannot read the theme; direct client writes are denied
#
# SELF-CONTAINED (7070… UUID family). Cleanup on exit.
# Usage: bash test/opt-070-group-theme.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54396}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"
# Default matches the testing-local stack these scripts hit (Kong 54396 →
# Postgres 54392); override PGURL to point psql at another stack.
PGURL="${PGURL:-postgres://postgres:postgres@localhost:54392/postgres}"

PASS=0
FAIL=0
ok()  { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
h1()  { echo ""; echo "━━━ $1 ━━━"; }
q()   { PGPASSWORD=postgres psql "$PGURL" -Atq -v ON_ERROR_STOP=1 -c "$1"; }

FREE="70707070-7070-4070-8070-707070700001"
PRO="70707070-7070-4070-8070-707070700002"
MEMBER="70707070-7070-4070-8070-707070700003"
OUT="70707070-7070-4070-8070-707070700004"
G_FREE="70707070-7070-4070-8070-707070700101"
G_PRO="70707070-7070-4070-8070-707070700102"
G_LOCK="70707070-7070-4070-8070-707070700103"
PW="Pass1234!"

cleanup() {
  q "DELETE FROM public.group_theme_changes WHERE group_id IN ('$G_FREE','$G_PRO','$G_LOCK');" >/dev/null 2>&1
  q "DELETE FROM public.action_rate_limits WHERE user_id IN ('$FREE','$PRO','$MEMBER','$OUT') OR user_id IN ('$G_FREE','$G_PRO','$G_LOCK');" >/dev/null 2>&1
  q "DELETE FROM public.groups WHERE id IN ('$G_FREE','$G_PRO','$G_LOCK');" >/dev/null 2>&1
  for uid in "$FREE" "$PRO" "$MEMBER" "$OUT"; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
    q "DELETE FROM public.users WHERE id = '$uid';" >/dev/null 2>&1
  done
}
trap cleanup EXIT
cleanup

h1 "SETUP: free host, pro host, member, outsider + three groups"
for pair in "F $FREE free_opt070" "P $PRO pro_opt070" "M $MEMBER member_opt070" "O $OUT out_opt070"; do
  set -- $pair
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$3@samay.test\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$2\"}" >/dev/null
done
q "INSERT INTO public.users (id, username, date_of_birth)
   VALUES ('$FREE', 'opt070_free', '1990-01-01'),
          ('$PRO', 'opt070_pro', '1990-01-01'),
          ('$MEMBER', 'opt070_member', '1990-01-01'),
          ('$OUT', 'opt070_out', '1990-01-01');" >/dev/null
q "SELECT public.apply_subscription_state('$PRO', 'pro', now() + interval '30 days', 'INITIAL_PURCHASE');" >/dev/null
q "INSERT INTO public.groups (id, name, created_by_user_id)
   VALUES ('$G_FREE', 'opt070 free', '$FREE'),
          ('$G_PRO', 'opt070 pro', '$PRO'),
          ('$G_LOCK', 'opt070 lock', '$PRO');" >/dev/null
q "INSERT INTO public.group_members (group_id, user_id, role, status)
   VALUES ('$G_FREE', '$FREE', 'host', 'active'),
          ('$G_PRO', '$PRO', 'host', 'active'),
          ('$G_PRO', '$MEMBER', 'member', 'active'),
          ('$G_LOCK', '$PRO', 'host', 'active');" >/dev/null

signin() { # signin <email>
  curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PW\"}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}
T_FREE="$(signin free_opt070@samay.test)"
T_PRO="$(signin pro_opt070@samay.test)"
T_MEMBER="$(signin member_opt070@samay.test)"
T_OUT="$(signin out_opt070@samay.test)"
[ -n "$T_FREE" ] && [ -n "$T_PRO" ] && [ -n "$T_MEMBER" ] && [ -n "$T_OUT" ] \
  && ok "all four users signed in" || { nok "sign-in"; exit 1; }

rpc() { # rpc <token> <json-body>
  curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/set_group_theme" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$2"
}
body() { echo "$1" | sed '$d'; }
code() { echo "$1" | tail -n1; }

h1 "1) a free host cannot use an RGB palette"
# Unlock first (control mode is host-owned); the palette stays black.
R=$(rpc "$T_FREE" "{\"p_group_id\":\"$G_FREE\",\"p_control_mode\":\"everyone\"}")
[ "$(code "$R")" = "200" ] && ok "free host can change the control mode" \
  || nok "free host control mode (got $(code "$R"): $(body "$R"))"
R=$(rpc "$T_FREE" "{\"p_group_id\":\"$G_FREE\",\"p_background_color\":\"#1E3A8A\"}")
if [ "$(code "$R")" = "400" ] && body "$R" | grep -q "theme_requires_paid"; then
  ok "free palette rejects RGB (theme_requires_paid)"
else
  nok "free palette rejects RGB (got $(code "$R"): $(body "$R"))"
fi

h1 "2) a member may change a paid theme under everyone"
R=$(rpc "$T_MEMBER" "{\"p_group_id\":\"$G_PRO\",\"p_background_color\":\"#1E3A8A\",\"p_accent_color\":\"#FACC15\"}")
if [ "$(code "$R")" = "200" ] && body "$R" | grep -q '"background_color": "#1E3A8A"'; then
  ok "member sets an RGB theme"
else
  nok "member RGB theme (got $(code "$R"): $(body "$R"))"
fi
FG=$(q "SELECT foreground_color FROM public.group_themes WHERE group_id = '$G_PRO';")
[ "$FG" = "#FFFFFF" ] && ok "foreground derived (white on navy)" || nok "foreground (got $FG)"

h1 "3) host_only rejects a member, allows the host"
R=$(rpc "$T_PRO" "{\"p_group_id\":\"$G_PRO\",\"p_control_mode\":\"host_only\"}")
[ "$(code "$R")" = "200" ] && body "$R" | grep -q '"control_mode": "host_only"' \
  && ok "host switches to host_only" || nok "host_only switch (got $(code "$R"))"
R=$(rpc "$T_MEMBER" "{\"p_group_id\":\"$G_PRO\",\"p_background_color\":\"#14532D\"}")
if [ "$(code "$R")" = "400" ] && body "$R" | grep -q "not_host"; then
  ok "host_only rejects a member"
else
  nok "host_only rejects a member (got $(code "$R"): $(body "$R"))"
fi
R=$(rpc "$T_PRO" "{\"p_group_id\":\"$G_PRO\",\"p_background_color\":\"#14532D\"}")
[ "$(code "$R")" = "200" ] && ok "host_only allows the host" \
  || nok "host_only allows the host (got $(code "$R"): $(body "$R"))"

h1 "4) locked rejects colour changes"
R=$(rpc "$T_PRO" "{\"p_group_id\":\"$G_LOCK\",\"p_control_mode\":\"locked\"}")
[ "$(code "$R")" = "200" ] && ok "host can lock the theme" || nok "lock (got $(code "$R"))"
R=$(rpc "$T_PRO" "{\"p_group_id\":\"$G_LOCK\",\"p_background_color\":\"#4C1D95\"}")
if [ "$(code "$R")" = "400" ] && body "$R" | grep -q "theme_locked"; then
  ok "locked rejects a colour change"
else
  nok "locked rejects a colour change (got $(code "$R"): $(body "$R"))"
fi

h1 "5) 3 changes/min/group (G_PRO already used member + host_only + host colour)"
R=$(rpc "$T_PRO" "{\"p_group_id\":\"$G_PRO\",\"p_background_color\":\"#4C1D95\"}")
if [ "$(code "$R")" = "400" ] && body "$R" | grep -q "rate_limited:group_theme_group"; then
  ok "the 4th change in a minute is rate-limited"
else
  nok "rate limit (got $(code "$R"): $(body "$R"))"
fi

h1 "6) RLS: outsiders read nothing; direct writes are denied"
RESP=$(curl -s -w "\n%{http_code}" \
  "$SUPABASE_URL/rest/v1/group_themes?group_id=eq.$G_PRO&select=group_id" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $T_OUT")
[ "$(code "$RESP")" = "200" ] && [ "$(body "$RESP" | tr -d '[:space:]')" = "[]" ] \
  && ok "non-member reads no theme" || nok "non-member read ($(code "$RESP"): $(body "$RESP"))"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/group_themes" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $T_MEMBER" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"group_id\":\"$G_PRO\"}")
case "$(code "$RESP")" in
  401|403|400) ok "direct theme insert denied ($(code "$RESP"))" ;;
  *) nok "direct theme insert denied (got $(code "$RESP"): $(body "$RESP"))" ;;
esac

echo ""
echo "=================================================="
echo "  OPT-070: PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[ "$FAIL" -eq 0 ]
