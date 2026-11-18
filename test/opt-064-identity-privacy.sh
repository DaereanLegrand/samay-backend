#!/usr/bin/env bash
# [OPT-064] Identity/privacy (Q17/Q8/Q1) — DOB, private profiles, hard delete,
# export completeness, retention and no-restore.
#
# One disposable stack only:
#   STACK_ENV=/tmp/samay-1023-a.env bash test/opt-064-identity-privacy.sh
#
# MODE=auto detects 233_identity_privacy (users.date_of_birth_backfilled) and
# asserts the vulnerable "before" shape or the hardened "after" shape. Set
# MODE=before|after to force.
set -uo pipefail

STACK_ENV="${STACK_ENV:?set STACK_ENV to the disposable stack env}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

read_env() {
  sed -n "s/^${1}=\([^[:space:]#]*\).*/\1/p" "$STACK_ENV" | head -1
}

DB_PORT="$(read_env POSTGRES_PORT)"; DB_PORT="${DB_PORT:-55612}"
KONG_PORT="$(read_env KONG_HTTP_PORT)"; KONG_PORT="${KONG_PORT:-55616}"
JWT_SECRET="$(read_env JWT_SECRET)"
ANON_KEY="$(read_env SUPABASE_ANON_KEY)"
SERVICE_KEY="$(read_env SUPABASE_SERVICE_ROLE_KEY)"
BASE="http://127.0.0.1:${KONG_PORT}"

[ -n "$JWT_SECRET" ] || { echo "missing JWT_SECRET in $STACK_ENV" >&2; exit 1; }
[ -n "$ANON_KEY" ] || { echo "missing SUPABASE_ANON_KEY in $STACK_ENV" >&2; exit 1; }
[ -n "$SERVICE_KEY" ] || { echo "missing SUPABASE_SERVICE_ROLE_KEY in $STACK_ENV" >&2; exit 1; }

A="64646464-6464-4646-8646-646464646401"
B="64646464-6464-4646-8646-646464646402"
C="64646464-6464-4646-8646-646464646403"
EV="64646464-6464-4646-8646-646464646410"
CHAT="64646464-6464-4646-8646-646464646420"
MSG="64646464-6464-4646-8646-646464646421"
SESSION="64646464-6464-4646-8646-646464646430"
ANSWER="64646464-6464-4646-8646-646464646431"
REPORT="64646464-6464-4646-8646-646464646440"
LEDGER="64646464-6464-4646-8646-646464646450"
ATTEND="64646464-6464-4646-8646-646464646460"

EMAIL_A="lane_a_priv_a_opt064@samay.test"
EMAIL_B="lane_a_priv_b_opt064@samay.test"
EMAIL_C="lane_a_priv_c_opt064@samay.test"
PW="LaneA-Pass-064!"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
nok()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
h1()   { echo ""; echo "--- $1 ---"; }

psql_db() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d postgres \
    -v ON_ERROR_STOP=1 -tAq "$@"
}
psql_soft() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d postgres \
    -tAq "$@" >/dev/null 2>&1 || true
}

admin_delete_user() {
  curl -s -o /dev/null -X DELETE "$BASE/auth/v1/admin/users/$1" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY"
}

cleanup() {
  psql_soft -c "DELETE FROM public.account_deletion_audit WHERE user_id_hash = md5('$A');"
  psql_soft -c "DELETE FROM public.auth_cleanup_queue WHERE user_id IN ('$A','$B','$C');"
  psql_soft -c "DELETE FROM public.message_reports WHERE report_id = '$REPORT';"
  psql_soft -c "DELETE FROM public.moderation_evidence WHERE report_id = '$REPORT';"
  psql_soft -c "DELETE FROM public.reports WHERE id = '$REPORT';"
  psql_soft -c "DELETE FROM public.device_tokens WHERE user_id IN ('$A','$B','$C');"
  psql_soft -c "DELETE FROM public.minigame_answers WHERE id = '$ANSWER';"
  psql_soft -c "DELETE FROM public.minigame_sessions WHERE id = '$SESSION';"
  psql_soft -c "DELETE FROM public.messages WHERE id = '$MSG';"
  psql_soft -c "DELETE FROM public.chat_participants WHERE chat_id = '$CHAT';"
  psql_soft -c "DELETE FROM public.chats WHERE id = '$CHAT';"
  psql_soft -c "DELETE FROM public.event_attendances WHERE id = '$ATTEND';"
  psql_soft -c "DELETE FROM public.events WHERE id = '$EV';"
  psql_soft -c "DELETE FROM public.shard_ledger WHERE id = '$LEDGER';"
  psql_soft -c "DELETE FROM public.search_rate_limits WHERE user_id IN ('$A','$B','$C');"
  psql_soft -c "DELETE FROM public.friendships WHERE requester_id IN ('$A','$B','$C') OR addressee_id IN ('$A','$B','$C');"
  psql_soft -c "DELETE FROM public.users WHERE id IN ('$A','$B','$C');"
  admin_delete_user "$A"; admin_delete_user "$B"; admin_delete_user "$C"
}
trap cleanup EXIT

create_auth_user() {
  local id=$1 email=$2
  curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$id\",\"email\":\"$email\",\"password\":\"$PW\",\"email_confirm\":true}"
}

login_token() {
  curl -s -X POST "$BASE/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PW\"}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

rpc() {
  local token=$1 fn=$2 body=$3
  curl -s -w "\n%{http_code}" -X POST "$BASE/rest/v1/rpc/$fn" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" -d "$body"
}

svc_get() {
  curl -s "$BASE/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}

MODE="${MODE:-auto}"
if [ "$MODE" = "auto" ]; then
  if [ "$(psql_db -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='date_of_birth_backfilled';")" = "1" ]; then
    MODE=after
  else
    MODE=before
  fi
fi
echo "OPT-064 identity/privacy — mode=$MODE"

cleanup
h1 "0) fixtures"
[ "$(create_auth_user "$A" "$EMAIL_A")" = "200" ] || nok "create auth A"
[ "$(create_auth_user "$B" "$EMAIL_B")" = "200" ] || nok "create auth B"
[ "$(create_auth_user "$C" "$EMAIL_C")" = "200" ] || nok "create auth C"
TOKEN_A="$(login_token "$EMAIL_A")"
TOKEN_B="$(login_token "$EMAIL_B")"
TOKEN_C="$(login_token "$EMAIL_C")"
[ -n "$TOKEN_A" ] && ok "A login" || nok "A login"
[ -n "$TOKEN_B" ] && ok "B login" || nok "B login"
[ -n "$TOKEN_C" ] && ok "C login" || nok "C login"

h1 "1) Q17 DOB"
BODY=$(rpc "$TOKEN_A" create_my_profile "{\"p_username\":\"privacytestA\",\"p_date_of_birth\":\"1990-01-01\"}")
[ "$(echo "$BODY" | tail -1)" = "204" ] && ok "adult profile created" || nok "adult profile: $BODY"
BODY=$(rpc "$TOKEN_B" create_my_profile "{\"p_username\":\"privacytestB\",\"p_date_of_birth\":\"1990-01-02\"}")
[ "$(echo "$BODY" | tail -1)" = "204" ] && ok "second adult profile created" || nok "B profile: $BODY"
BODY=$(rpc "$TOKEN_C" create_my_profile "{\"p_username\":\"privacytestC\",\"p_date_of_birth\":null}")
if echo "$BODY" | grep -qi "obligatoria\|null value\|not-null"; then ok "NULL DOB rejected"; else nok "NULL DOB not rejected: $BODY"; fi
BODY=$(rpc "$TOKEN_C" create_my_profile "{\"p_username\":\"privacytestC\",\"p_date_of_birth\":\"2020-01-01\"}")
if echo "$BODY" | grep -qi "18 años\|18 anos\|adult"; then ok "under-18 DOB rejected server-side"; else nok "under-18 DOB not rejected: $BODY"; fi
if [ "$MODE" = "after" ]; then
  # Slim-prod: guests carry no DOB (300_slim/01_onboarding), so the column is
  # nullable; the adult-DOB trigger still rejects a non-guest NULL and any
  # under-18 value (asserted above).
  NOTNULL=$(psql_db -c "SELECT is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='date_of_birth';")
  [ "$NOTNULL" = "YES" ] && ok "users.date_of_birth is nullable for guests (adult trigger still enforced)" || nok "date_of_birth nullable=$NOTNULL"
  HAS_RESTORE=$(psql_db -c "SELECT count(*) FROM pg_proc WHERE proname='restore_my_account';")
  [ "$HAS_RESTORE" = "0" ] && ok "restore_my_account removed" || nok "restore_my_account still exists"
fi

# private B; make A opted-in so ranking/search rules are exercised both ways.
psql_soft -c "UPDATE public.users SET profile_public=false, personal_shards=999999 WHERE id='$B';"
psql_soft -c "UPDATE public.users SET profile_public=true, personal_shards=1 WHERE id='$A';"

h1 "2) Q8 private search + ranking"
BODY=$(rpc "$TOKEN_A" search_users '{"p_query":"privacytestB"}')
COUNT=$(echo "$BODY" | python3 -c 'import sys,json; l=sys.stdin.read().splitlines(); s="\n".join(l[:-1]); print(len(json.loads(s)) if s.strip() else 0)' 2>/dev/null)
[ "$COUNT" = "1" ] && ok "private profile found by exact username" || nok "exact private search count=$COUNT body=$BODY"
BODY=$(rpc "$TOKEN_A" search_users '{"p_query":"privacytest"}')
COUNT=$(echo "$BODY" | python3 -c 'import sys,json; l=sys.stdin.read().splitlines(); s="\n".join(l[:-1]); rows=json.loads(s) if s.strip() else []; print(sum(1 for r in rows if r.get("username")=="privacytestB"))' 2>/dev/null)
if [ "$MODE" = "after" ]; then
  [ "$COUNT" = "0" ] && ok "private profile NOT returned by prefix" || nok "private prefix leaked ($COUNT)"
else
  [ "$COUNT" = "1" ] && ok "(before) private profile leaked by prefix" || nok "(before) expected prefix leak"
fi
BODY=$(rpc "$TOKEN_A" search_users '{"p_query":"privacytest"}')
if echo "$BODY" | grep -q '"bio"'; then nok "search result carries bio"; else ok "search result has no bio field"; fi

BODY=$(rpc "$TOKEN_A" get_user_ranking '{"p_limit":100}')
HAS_B=$(echo "$BODY" | python3 -c 'import sys,json; l=sys.stdin.read().splitlines(); s="\n".join(l[:-1]); rows=json.loads(s) if s.strip() else []; print(1 if any(r.get("user_id")=="64646464-6464-4646-8646-646464646402" for r in rows) else 0)' 2>/dev/null)
if [ "$MODE" = "after" ]; then
  [ "$HAS_B" = "0" ] && ok "private profile absent from ranking" || nok "private profile present in ranking"
else
  [ "$HAS_B" = "1" ] && ok "(before) private profile present in ranking" || nok "(before) expected private ranking leak"
fi
psql_soft -c "UPDATE public.users SET profile_public=true WHERE id='$B';"
BODY=$(rpc "$TOKEN_A" get_user_ranking '{"p_limit":100}')
HAS_B=$(echo "$BODY" | python3 -c 'import sys,json; l=sys.stdin.read().splitlines(); s="\n".join(l[:-1]); rows=json.loads(s) if s.strip() else []; print(1 if any(r.get("user_id")=="64646464-6464-4646-8646-646464646402" for r in rows) else 0)' 2>/dev/null)
if [ "$HAS_B" = "1" ]; then ok "opted-in profile enters ranking"; else
  nok "opted-in profile missing from ranking (profile_public=$(psql_db -c "SELECT profile_public FROM public.users WHERE id='$B';") body=$BODY)"
fi
BODY=$(rpc "$TOKEN_A" search_users '{"p_query":"privacytest"}')
COUNT=$(echo "$BODY" | python3 -c 'import sys,json; l=sys.stdin.read().splitlines(); s="\n".join(l[:-1]); rows=json.loads(s) if s.strip() else []; print(sum(1 for r in rows if r.get("username")=="privacytestB"))' 2>/dev/null)
[ "$COUNT" = "1" ] && ok "public profile discoverable by prefix" || nok "public prefix count=$COUNT"
psql_soft -c "UPDATE public.users SET profile_public=false WHERE id='$B';"

h1 "3) SEC-050 export"
BODY=$(rpc "$TOKEN_A" register_device_token '{"p_token":"lanea_opt064_token_abcdefghijklmnop","p_platform":"ios"}')
if echo "$BODY" | tail -1 | grep -q "204"; then ok "device token registered"; else nok "device token: $BODY"; fi
psql_soft -c "INSERT INTO public.chats (id,type,created_at) VALUES ('$CHAT','direct',now()) ON CONFLICT DO NOTHING;"
psql_soft -c "INSERT INTO public.chat_participants (chat_id,user_id) VALUES ('$CHAT','$A'),('$CHAT','$B') ON CONFLICT DO NOTHING;"
psql_soft -c "INSERT INTO public.messages (id,chat_id,sender_id,content,recipient_id) VALUES ('$MSG','$CHAT','$B','ciphertext-from-b','$A') ON CONFLICT DO NOTHING;"
psql_soft -c "INSERT INTO public.minigame_sessions (id,game_type,status,shard_wager,player_limit,participants) VALUES ('$SESSION','two_lies_one_truth','active',0,8,ARRAY['$A','$B']::uuid[]) ON CONFLICT DO NOTHING;"
psql_soft -c "INSERT INTO public.minigame_answers (id,session_id,round,subject_id,prompt_type,answer_ciphertext) VALUES ('$ANSWER','$SESSION',1,'$A','text','answer-cipher-a') ON CONFLICT DO NOTHING;"
psql_soft -c "INSERT INTO public.reports (id,reporter_id,target_type,target_id,reason) VALUES ('$REPORT','$A','user','$B','lane-a-export-fixture') ON CONFLICT DO NOTHING;"
BODY=$(rpc "$TOKEN_A" export_my_data '{}')
for key in messages_received minigame_answers device_tokens reports exclusions retention; do
  if echo "$BODY" | grep -q "\"$key\""; then ok "export includes $key"; else nok "export missing $key"; fi
done
if [ "$MODE" = "after" ]; then
  if echo "$BODY" | grep -q "samay.export.v2"; then ok "export schema v2"; else nok "export schema not v2"; fi
fi

h1 "4) Q1 hard delete / retention"
if [ "$MODE" = "after" ]; then
  R=$(rpc "$TOKEN_A" restore_my_account '{}')
  CODE=$(echo "$R" | tail -1)
  if [ "$CODE" = "404" ] || echo "$R" | grep -qi "could not find\|does not exist"; then ok "restore_my_account absent (no restore path)"; else nok "restore still callable: $R"; fi
fi
psql_soft -c "INSERT INTO public.shard_ledger (id,user_id,delta,reason) VALUES ('$LEDGER','$A',5,'admin_grant') ON CONFLICT DO NOTHING;"
psql_soft -c "INSERT INTO public.events (id,name,type,created_by_user_id,starts_at,ends_at,capacity,status) VALUES ('$EV','lane-a-attendance','casual','$B',now()+interval '1 day',now()+interval '1 day 2 hours',5,'upcoming') ON CONFLICT DO NOTHING;"
psql_soft -c "INSERT INTO public.event_attendances (id,event_id,user_id) VALUES ('$ATTEND','$EV','$A') ON CONFLICT DO NOTHING;"
BODY=$(rpc "$TOKEN_A" delete_my_account '{}')
CODE=$(echo "$BODY" | tail -1)
[ "$CODE" = "204" ] && ok "delete_my_account returned 204" || nok "delete_my_account: $CODE $BODY"
ROW=$(svc_get "users?id=eq.$A&select=id")
if [ "$MODE" = "after" ]; then
  [ "$ROW" = "[]" ] && ok "public.users row hard-deleted" || nok "users row still present: $ROW"
  AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/auth/v1/admin/users/$A" -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")
  [ "$AUTH_CODE" = "404" ] && ok "auth.users row deleted (404)" || nok "auth.users still present (HTTP $AUTH_CODE)"
  REP=$(psql_db -c "SELECT (reporter_id IS NULL)::text || '|' || COALESCE(reporter_pseudonym,'') FROM public.reports WHERE id='$REPORT';")
  echo "$REP" | grep -qE "^(t|true)\|deleted:" && ok "report evidence retained + pseudonymized" || nok "report evidence wrong: $REP"
  LED=$(psql_db -c "SELECT (user_id IS NULL)::text || '|' || (retention_until IS NOT NULL)::text FROM public.shard_ledger WHERE id='$LEDGER';")
  echo "$LED" | grep -qE "^(t|true)\|(t|true)$" && ok "ledger retained pseudonymized with 5y clock" || nok "ledger retention wrong: $LED"
  ATT=$(psql_db -c "SELECT (user_id IS NULL)::text || '|' || (retention_until IS NOT NULL)::text FROM public.event_attendances WHERE id='$ATTEND';")
  echo "$ATT" | grep -qE "^(t|true)\|(t|true)$" && ok "attendance retained pseudonymized with 5y clock" || nok "attendance retention wrong: $ATT"
else
  [ "$ROW" != "[]" ] && ok "(before) users row tombstoned, not deleted" || nok "(before) unexpected hard delete"
fi

echo ""
echo "OPT-064 ($MODE): PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
