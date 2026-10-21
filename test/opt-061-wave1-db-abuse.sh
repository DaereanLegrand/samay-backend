#!/usr/bin/env bash
# Wave 1 DB hardening abuse checks (SEC-014/015/018/019/020/030).
#
# One disposable stack only:
#   STACK_ENV=/tmp/samay-g.env bash test/opt-061-wave1-db-abuse.sh
#
# The script auto-detects whether 231_wave1_hardening is applied and asserts
# the vulnerable behavior (before) or the denial (after) accordingly. Set
# MODE=before|after to force a mode.
set -uo pipefail

STACK_ENV="${STACK_ENV:?set STACK_ENV to the disposable stack env}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

read_env() {
  sed -n "s/^${1}=\([^[:space:]#]*\).*/\1/p" "$STACK_ENV" | head -1
}

DB_PORT="$(read_env POSTGRES_PORT)"
KONG_PORT="$(read_env KONG_HTTP_PORT)"
JWT_SECRET="$(read_env JWT_SECRET)"
ANON_KEY="$(read_env SUPABASE_ANON_KEY)"
SERVICE_KEY="$(read_env SUPABASE_SERVICE_ROLE_KEY)"
DB_PORT="${DB_PORT:-54382}"
KONG_PORT="${KONG_PORT:-54386}"
BASE="http://127.0.0.1:${KONG_PORT}"

[ -n "$JWT_SECRET" ] || { echo "missing JWT_SECRET in $STACK_ENV" >&2; exit 1; }
[ -n "$ANON_KEY" ] || { echo "missing SUPABASE_ANON_KEY in $STACK_ENV" >&2; exit 1; }
[ -n "$SERVICE_KEY" ] || { echo "missing SUPABASE_SERVICE_ROLE_KEY in $STACK_ENV" >&2; exit 1; }

mint_jwt() {
  JWT_SECRET="$JWT_SECRET" SUB="$1" ROLE="${2:-authenticated}" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

now = int(time.time())
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload = b64(json.dumps({
    "role": os.environ["ROLE"],
    "aud": "authenticated",
    "sub": os.environ["SUB"],
    "iss": "supabase",
    "iat": now,
    "exp": now + 3600,
}, separators=(",", ":")).encode())
signed = f"{header}.{payload}".encode()
sig = b64(hmac.new(os.environ["JWT_SECRET"].encode(), signed, hashlib.sha256).digest())
print(f"{header}.{payload}.{sig}")
PY
}
mint_user_jwt() { mint_jwt "$1" authenticated; }
mint_service_jwt() { mint_jwt "00000000-0000-0000-0000-000000000000" service_role; }

psql_db() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -tAq "$@"
}
psql_soft() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d postgres -tAq "$@" >/dev/null 2>&1 || true
}

A="11111111-1111-4111-8111-111111111111"
B="22222222-2222-4222-8222-222222222222"
C="77777777-7777-4777-8777-777777777777"
D="99999999-9999-4999-8999-999999999999"
E="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
G="33333333-3333-4333-8333-333333333333"
EV="44444444-4444-4444-8444-444444444444"
CHAT_EVENT="55555555-5555-4555-8555-555555555555"
CHAT_DIRECT="66666666-6666-4666-8666-666666666666"
MSG_EVENT="55555555-5555-4555-8555-555555555501"
MSG_OTHER="66666666-6666-4666-8666-666666666601"
NOTIF="88888888-8888-4888-8888-888888888888"
TOKEN="fcm_token_opt061_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

MODE="${MODE:-auto}"
if [ "$MODE" = "auto" ]; then
  policy="$(psql_db -c "SELECT pg_get_expr(polqual, polrelid) FROM pg_policy WHERE polname='events_update_host' AND polrelid='public.events'::regclass;")"
  if printf '%s' "$policy" | grep -q "host"; then MODE=after; else MODE=before; fi
fi
echo "mode: $MODE"

# The running auth service is the authority for the signing key (a disposable
# stack may use the compose default rather than the env-file value).
_probe_code="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/rest/v1/users?select=id&limit=1" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $(mint_user_jwt "$A")")"
if [ "$_probe_code" = "401" ]; then
  _prefix="$(read_env STACK_PREFIX)"
  _live_secret="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${_prefix:-samay}-auth" 2>/dev/null \
    | sed -n 's/^GOTRUE_JWT_SECRET=//p' | head -1)"
  [ -n "$_live_secret" ] && JWT_SECRET="$_live_secret"
fi
SVC_JWT="$(mint_service_jwt)"


PASS=0
FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
expect() { # expect <name> <allowed-codes> <actual>
  local name="$1" allowed="$2" actual="$3"
  if [[ " $allowed " == *" $actual "* ]]; then ok "$name ($actual)"; else bad "$name (got $actual, allowed $allowed)"; fi
}
expect_before() { expect "$1" "200 201 204" "$2"; }
expect_after()  { expect "$1" "400 401 403 404 409 415 422" "$2"; }

code() {
  curl -sS -o /tmp/opt061-resp -w '%{http_code}' "$@"
}

api() {
  local jwt="$1" method="$2" path="$3" body="${4:-}"
  if [ -n "$body" ]; then
    code -X "$method" "$BASE/rest/v1/$path" \
      -H "apikey: $ANON_KEY" -H "Authorization: Bearer $jwt" \
      -H 'Content-Type: application/json' -H 'Prefer: return=representation' -d "$body"
  else
    code -X "$method" "$BASE/rest/v1/$path" \
      -H "apikey: $ANON_KEY" -H "Authorization: Bearer $jwt" \
      -H 'Prefer: return=representation'
  fi
}

rpc() {
  local jwt="$1" fn="$2" body="$3"
  code -X POST "$BASE/rest/v1/rpc/$fn" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $jwt" \
    -H 'Content-Type: application/json' -d "$body"
}

upload() { # upload <jwt> <bucket> <path> <mime> <file>
  code -X POST "$BASE/storage/v1/object/$2/$3" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: $4" --data-binary "@$5"
}

storage_delete() {
  curl -sS -o /dev/null -X DELETE "$BASE/storage/v1/object/$1/$2" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SVC_JWT" >/dev/null 2>&1 || true
}

cleanup() {
  storage_delete avatars "$A/opt061.svg"
  storage_delete avatars "$A/opt061-big.jpg"
  storage_delete groups "opt061.html"
  storage_delete events "$EV/photos/opt061-host.jpg"
  storage_delete events "$EV/photos/opt061-outsider.jpg"
  storage_delete events "$EV/photos/opt061-pending.jpg"
  storage_delete events "notanevent/opt061-host.jpg"
  psql_soft -c "DELETE FROM public.deleted_messages WHERE deleted_by IN ('$A','$B','$C','$D','$E');"
  psql_soft -c "DELETE FROM public.message_reads WHERE user_id IN ('$A','$B','$C','$D','$E');"
  psql_soft -c "DELETE FROM public.messages WHERE chat_id IN ('$CHAT_EVENT','$CHAT_DIRECT');"
  psql_soft -c "DELETE FROM public.chat_participants WHERE chat_id IN ('$CHAT_EVENT','$CHAT_DIRECT');"
  psql_soft -c "DELETE FROM public.chats WHERE id IN ('$CHAT_EVENT','$CHAT_DIRECT');"
  psql_soft -c "DELETE FROM public.notifications WHERE id = '$NOTIF';"
  psql_soft -c "DELETE FROM public.device_tokens WHERE user_id IN ('$A','$B','$C','$D','$E') OR token LIKE 'fcm_token_opt061%';"
  psql_soft -c "DELETE FROM public.event_attendances WHERE event_id = '$EV';"
  psql_soft -c "DELETE FROM public.event_invites WHERE event_id = '$EV';"
  psql_soft -c "DELETE FROM public.event_hosts WHERE event_id = '$EV';"
  psql_soft -c "DELETE FROM public.events WHERE id = '$EV';"
  psql_soft -c "DELETE FROM public.group_members WHERE group_id = '$G';"
  psql_soft -c "DELETE FROM public.groups WHERE id = '$G';"
  psql_soft -c "DELETE FROM public.users WHERE id IN ('$A','$B','$C','$D','$E');"
  rm -f /tmp/opt061-resp /tmp/opt061.bin /tmp/opt061-big.bin
}
trap cleanup EXIT

cleanup

psql_db <<SQL >/dev/null
INSERT INTO public.users (id, username, personal_shards, preshards)
VALUES
  ('$A', 'opt061a', 1000, 1000),
  ('$B', 'opt061b', 1000, 1000),
  ('$C', 'opt061c', 1000, 1000),
  ('$D', 'opt061d', 1000, 1000),
  ('$E', 'opt061e', 1000, 1000);

INSERT INTO public.groups (id, name, created_by_user_id, group_shards)
VALUES ('$G', 'opt061 group', '$A', 0);

INSERT INTO public.group_members (group_id, user_id, role, status)
VALUES
  ('$G', '$A', 'host', 'active'),
  ('$G', '$B', 'member', 'active'),
  ('$G', '$C', 'member', 'invited');

INSERT INTO public.events
  (id, name, type, created_by_user_id, group_id, location_name,
   location_lat, location_lng, starts_at, ends_at, capacity, status)
VALUES
  ('$EV', 'opt061 event', 'casual', '$A', '$G', 'Venue', 12.0, -77.0,
   now() + interval '1 day', now() + interval '2 days', 5, 'upcoming');

INSERT INTO public.event_hosts (event_id, user_id, role)
VALUES ('$EV', '$A', 'host'), ('$EV', '$B', 'staff');

INSERT INTO public.event_invites (event_id, user_id, invited_by_user_id, status)
VALUES
  ('$EV', '$C', '$A', 'pending'),
  ('$EV', '$D', '$A', 'accepted');

INSERT INTO public.chats (id, type, reference_id)
VALUES
  ('$CHAT_EVENT', 'event', '$EV'),
  ('$CHAT_DIRECT', 'direct', NULL);

INSERT INTO public.chat_participants (chat_id, user_id)
VALUES
  ('$CHAT_EVENT', '$A'), ('$CHAT_EVENT', '$B'), ('$CHAT_EVENT', '$C'),
  ('$CHAT_DIRECT', '$A'), ('$CHAT_DIRECT', '$B');

INSERT INTO public.messages (id, chat_id, sender_id, content)
VALUES
  ('$MSG_EVENT', '$CHAT_EVENT', '$A', 'ciphertext-event'),
  ('$MSG_OTHER', '$CHAT_DIRECT', '$A', 'ciphertext-direct');

INSERT INTO public.notifications (id, user_id, type, title, body, data)
VALUES ('$NOTIF', '$A', 'system', 'original title', 'original body', '{}'::jsonb);
SQL

echo "fixtures ready"
A_JWT="$(mint_user_jwt "$A")"
B_JWT="$(mint_user_jwt "$B")"
C_JWT="$(mint_user_jwt "$C")"
E_JWT="$(mint_user_jwt "$E")"


# ---------------------------------------------------------------------------
# SEC-014 — staff must not mutate the event.
# ---------------------------------------------------------------------------
event_before="$(psql_db -c "SELECT name FROM public.events WHERE id='$EV';")"
api "$B_JWT" PATCH "events?id=eq.$EV" '{"name":"staff-renamed"}' >/dev/null
event_after="$(psql_db -c "SELECT name FROM public.events WHERE id='$EV';")"
if [ "$MODE" = "before" ]; then
  [ "$event_after" = "staff-renamed" ] && ok "SEC-014 staff PATCH renamed event" \
    || bad "SEC-014 staff PATCH did not rename event ($event_before -> $event_after)"
else
  [ "$event_after" = "$event_before" ] && ok "SEC-014 staff PATCH denied (name unchanged)" \
    || bad "SEC-014 staff PATCH changed event name ($event_after)"
fi

# Host edit still works after the fix.
api "$A_JWT" PATCH "events?id=eq.$EV" '{"name":"host-renamed"}' >/dev/null
event_after="$(psql_db -c "SELECT name FROM public.events WHERE id='$EV';")"
[ "$event_after" = "host-renamed" ] && ok "SEC-014 host PATCH allowed" \
  || bad "SEC-014 host PATCH broke ($event_after)"

# ---------------------------------------------------------------------------
# SEC-018 — pending invitee must not read event chat.
# ---------------------------------------------------------------------------
api "$C_JWT" GET "messages?chat_id=eq.$CHAT_EVENT&select=id" >/dev/null
if grep -q "$MSG_EVENT" /tmp/opt061-resp; then
  if [ "$MODE" = "before" ]; then ok "SEC-018 pending invitee read event messages"; else bad "SEC-018 pending invitee still reads messages"; fi
else
  if [ "$MODE" = "before" ]; then bad "SEC-018 pending invitee read was already denied"; else ok "SEC-018 pending invitee read denied"; fi
fi

D_JWT="$(mint_user_jwt "$D")"
api "$D_JWT" GET "messages?chat_id=eq.$CHAT_EVENT&select=id" >/dev/null
grep -q "$MSG_EVENT" /tmp/opt061-resp && ok "SEC-018 accepted invitee can read event messages" \
  || bad "SEC-018 accepted invitee lost event message read"

# Pending invitee cannot post to event chat.
api "$C_JWT" POST "messages" "{\"chat_id\":\"$CHAT_EVENT\",\"sender_id\":\"$C\",\"content\":\"pending-write\"}" >/dev/null
pending_msgs="$(psql_db -c "SELECT count(*) FROM public.messages WHERE chat_id='$CHAT_EVENT' AND sender_id='$C';")"
if [ "$MODE" = "before" ]; then
  [ "$pending_msgs" = "1" ] && ok "SEC-018 pending invitee posted to event chat" \
    || bad "SEC-018 pending invitee post blocked before fix"
else
  [ "$pending_msgs" = "0" ] && ok "SEC-018 pending invitee post denied" \
    || bad "SEC-018 pending invitee post persisted"
fi

# Active group member read stays allowed; invited group member denied.
api "$B_JWT" GET "groups?id=eq.$G&select=id" >/dev/null
grep -q "$G" /tmp/opt061-resp && ok "SEC-018 active group member reads group" \
  || bad "SEC-018 active group member lost group read"
api "$C_JWT" GET "groups?id=eq.$G&select=id" >/dev/null
if grep -q "$G" /tmp/opt061-resp; then
  if [ "$MODE" = "before" ]; then ok "SEC-018 invited group member read group"; else bad "SEC-018 invited group member still reads group"; fi
else
  if [ "$MODE" = "before" ]; then bad "SEC-018 invited group member read denied before fix"; else ok "SEC-018 invited group member read denied"; fi
fi

# ---------------------------------------------------------------------------
# SEC-015 — participant cannot delete another sender's message.
# ---------------------------------------------------------------------------
rpc "$B_JWT" delete_undecryptable_messages "{\"p_chat_id\":\"$CHAT_DIRECT\",\"p_message_ids\":[\"$MSG_OTHER\"]}" >/dev/null
resp="$(cat /tmp/opt061-resp)"
own_msg_left="$(psql_db -c "SELECT count(*) FROM public.messages WHERE id='$MSG_OTHER';")"
if [ "$MODE" = "before" ]; then
  [ "$resp" = "1" ] && [ "$own_msg_left" = "0" ] && ok "SEC-015 participant deleted another sender's message" \
    || bad "SEC-015 delete result=$resp, rows_left=$own_msg_left"
else
  [ "$resp" = "0" ] && [ "$own_msg_left" = "1" ] && ok "SEC-015 delete of another sender's message denied" \
    || bad "SEC-015 delete result=$resp, rows_left=$own_msg_left"
fi

# Direct deleted_messages writes must be revoked after the fix.
dm_code="$(code -X POST "$BASE/rest/v1/deleted_messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $A_JWT" \
  -H 'Content-Type: application/json' \
  -d "{\"message_id\":\"$MSG_OTHER\",\"chat_id\":\"$CHAT_DIRECT\",\"deleted_by\":\"$A\",\"reason\":\"undecryptable_cleanup\"}")"
if [ "$MODE" = "before" ]; then
  # RLS already denied direct writes (no_access); the grant is defense in depth.
  expect_after "SEC-015 direct deleted_messages write denied (RLS)" "$dm_code"
else
  expect_after "SEC-015 direct deleted_messages write denied" "$dm_code"
fi

# Batch cap: 51 ids must be refused after the fix.
ids="$(python3 - <<'PY'
import json
print(json.dumps([f"00000000-0000-4000-8000-{i:012d}" for i in range(51)]))
PY
)"
batch_code="$(code -X POST "$BASE/rest/v1/rpc/delete_undecryptable_messages" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $A_JWT" \
  -H 'Content-Type: application/json' \
  -d "{\"p_chat_id\":\"$CHAT_DIRECT\",\"p_message_ids\":$ids}")"
if [ "$MODE" = "before" ]; then
  expect_before "SEC-015 oversized batch accepted before fix" "$batch_code"
else
  expect_after "SEC-015 oversized batch denied" "$batch_code"
fi

# ---------------------------------------------------------------------------
# SEC-019 — owner may only update read.
# ---------------------------------------------------------------------------
title_code="$(api "$A_JWT" PATCH "notifications?id=eq.$NOTIF" '{"title":"spoofed"}')"
title_now="$(psql_db -c "SELECT title FROM public.notifications WHERE id='$NOTIF';")"
if [ "$MODE" = "before" ]; then
  [ "$title_now" = "spoofed" ] && ok "SEC-019 owner PATCH rewrote title" \
    || bad "SEC-019 owner PATCH title did not apply before fix"
else
  [ "$title_now" = "original title" ] && expect_after "SEC-019 owner PATCH title denied" "$title_code" \
    || bad "SEC-019 owner PATCH changed title ($title_now)"
fi

api "$A_JWT" PATCH "notifications?id=eq.$NOTIF" '{"push_sent_at":"2026-01-01T00:00:00Z"}' >/dev/null
push_now="$(psql_db -c "SELECT coalesce(push_sent_at::text,'NULL') FROM public.notifications WHERE id='$NOTIF';")"
if [ "$MODE" = "before" ]; then
  [ "$push_now" != "NULL" ] && ok "SEC-019 owner PATCH set push_sent_at" \
    || bad "SEC-019 owner PATCH push_sent_at did not apply before fix"
else
  [ "$push_now" = "NULL" ] && ok "SEC-019 owner PATCH push_sent_at denied" \
    || bad "SEC-019 owner PATCH set push_sent_at ($push_now)"
fi

api "$A_JWT" PATCH "notifications?id=eq.$NOTIF" '{"read":true}' >/dev/null
read_now="$(psql_db -c "SELECT "read"::text FROM public.notifications WHERE id='$NOTIF';")"
[ "$read_now" = "true" ] && ok "SEC-019 owner can still mark read" \
  || bad "SEC-019 owner read update broke ($read_now)"

# ---------------------------------------------------------------------------
# SEC-020 — device token re-homing and cap.
# ---------------------------------------------------------------------------
rpc "$A_JWT" register_device_token "{\"p_token\":\"$TOKEN\",\"p_platform\":\"android\"}" >/dev/null
token_owner="$(psql_db -c "SELECT user_id FROM public.device_tokens WHERE token='$TOKEN';")"
[ "$token_owner" = "$A" ] && ok "SEC-020 owner A registered token" \
  || bad "SEC-020 owner A token registration failed ($token_owner)"

home_code="$(rpc "$B_JWT" register_device_token "{\"p_token\":\"$TOKEN\",\"p_platform\":\"ios\"}")"
token_owner="$(psql_db -c "SELECT user_id FROM public.device_tokens WHERE token='$TOKEN';")"
if [ "$MODE" = "before" ]; then
  [ "$token_owner" = "$B" ] && ok "SEC-020 token re-homed to B" \
    || bad "SEC-020 token did not re-home before fix ($token_owner)"
else
  [ "$token_owner" = "$A" ] && expect_after "SEC-020 token re-homing denied" "$home_code" \
    || bad "SEC-020 token changed owner ($token_owner)"
fi

# Per-user cap (10): the 11th distinct token is refused after the fix.
: > /tmp/opt061-tokens.txt
cap_code=""
for i in $(seq 1 11); do
  t="fcm_token_opt061_cap_$(printf '%02d' "$i")_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  c="$(rpc "$A_JWT" register_device_token "{\"p_token\":\"$t\",\"p_platform\":\"android\"}")"
  [ "$i" = "11" ] && cap_code="$c"
done
a_tokens="$(psql_db -c "SELECT count(*) FROM public.device_tokens WHERE user_id='$A';")"
if [ "$MODE" = "before" ]; then
  [ "$a_tokens" -ge 11 ] && ok "SEC-020 per-user token cap absent before fix ($a_tokens)" \
    || bad "SEC-020 cap unexpectedly present before fix ($a_tokens)"
else
  [ "$a_tokens" -le 10 ] && expect_after "SEC-020 per-user token cap enforced" "$cap_code" \
    || bad "SEC-020 per-user token count=$a_tokens"
fi

# Invalid token shape.
bad_code="$(rpc "$A_JWT" register_device_token '{"p_token":"short token with spaces","p_platform":"android"}')"
if [ "$MODE" = "before" ]; then
  expect_before "SEC-020 malformed token accepted before fix" "$bad_code"
else
  expect_after "SEC-020 malformed token rejected" "$bad_code"
fi

# ---------------------------------------------------------------------------
# SEC-030 — storage MIME/size/path abuse.
# ---------------------------------------------------------------------------
printf '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>' > /tmp/opt061.svg
printf '<html><script>alert(1)</script></html>' > /tmp/opt061.html
head -c 6291456 /dev/zero > /tmp/opt061-big.bin

svg_code="$(upload "$A_JWT" avatars "$A/opt061.svg" "image/svg+xml" /tmp/opt061.svg)"
html_code="$(upload "$A_JWT" groups "opt061.html" "text/html" /tmp/opt061.html)"
big_code="$(upload "$A_JWT" avatars "$A/opt061-big.jpg" "image/jpeg" /tmp/opt061-big.bin)"
host_code="$(upload "$A_JWT" events "$EV/photos/opt061-host.jpg" "image/jpeg" /tmp/opt061.svg)"
out_code="$(upload "$E_JWT" events "$EV/photos/opt061-outsider.jpg" "image/jpeg" /tmp/opt061.svg)"
pending_code="$(upload "$C_JWT" events "$EV/photos/opt061-pending.jpg" "image/jpeg" /tmp/opt061.svg)"
wrongpath_code="$(upload "$A_JWT" events "notanevent/opt061-host.jpg" "image/jpeg" /tmp/opt061.svg)"

if [ "$MODE" = "before" ]; then
  expect_before "SEC-030 SVG upload accepted before fix" "$svg_code"
  expect_before "SEC-030 HTML upload accepted before fix" "$html_code"
  expect_before "SEC-030 oversized upload accepted before fix" "$big_code"
  expect_before "SEC-030 host event upload accepted" "$host_code"
  expect_before "SEC-030 non-attendee event upload accepted before fix" "$out_code"
  expect_before "SEC-030 pending invitee event upload accepted before fix" "$pending_code"
  expect_before "SEC-030 non-event path upload accepted before fix" "$wrongpath_code"
else
  expect_after "SEC-030 SVG upload denied" "$svg_code"
  expect_after "SEC-030 HTML upload denied" "$html_code"
  expect_after "SEC-030 oversized upload denied" "$big_code"
  expect_before "SEC-030 host event upload allowed" "$host_code"
  expect_after "SEC-030 non-attendee event upload denied" "$out_code"
  expect_after "SEC-030 pending invitee event upload denied" "$pending_code"
  expect_after "SEC-030 non-event path upload denied" "$wrongpath_code"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "Wave 1 DB abuse checks ($MODE): PASS ($PASS checks)"
else
  echo "Wave 1 DB abuse checks ($MODE): FAIL ($FAIL failed, $PASS passed)"
  exit 1
fi
