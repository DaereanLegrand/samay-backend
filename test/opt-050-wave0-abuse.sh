#!/usr/bin/env bash
# Minimal Wave 0 abuse checks (SEC-001..010) against one disposable stack.
# Usage: STACK_ENV=/path/to/stack.env bash test/opt-050-wave0-abuse.sh
set -euo pipefail

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

mint_user_jwt() {
  JWT_SECRET="$JWT_SECRET" SUB="$1" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

now = int(time.time())
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload = b64(json.dumps({
    "role": "authenticated",
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

psql_db() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -tAq "$@"
}

A="11111111-1111-4111-8111-111111111111"
B="22222222-2222-4222-8222-222222222222"
C="77777777-7777-4777-8777-777777777777"
G="33333333-3333-4333-8333-333333333333"
E="44444444-4444-4444-8444-444444444444"
BLOCK="55555555-5555-4555-8555-555555555555"
S1="66666666-6666-4666-8666-666666666666"
S2="88888888-8888-4888-8888-888888888888"

cleanup() {
  psql_db -c "DELETE FROM public.minigame_sessions WHERE id IN ('$S1','$S2');" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.moderation_evidence WHERE report_id IN (SELECT id FROM public.reports WHERE reporter_id IN ('$A','$B','$C'));" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.reports WHERE reporter_id IN ('$A','$B','$C');" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.notifications WHERE user_id IN ('$A','$B','$C');" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.events WHERE id = '$E';" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.groups WHERE id = '$G';" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.friendships WHERE requester_id IN ('$A','$B','$C') OR addressee_id IN ('$A','$B','$C');" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.users WHERE id IN ('$A','$B','$C');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
psql_db <<SQL >/dev/null
INSERT INTO public.users (id, username, date_of_birth, personal_shards, preshards)
VALUES
  ('$A', 'wave0a', DATE '1990-01-01', 1000, 1000),
  ('$B', 'wave0b', DATE '1990-01-01', 1000, 1000),
  ('$C', 'wave0c', DATE '1990-01-01', 1000, 1000);

INSERT INTO public.groups (id, name, created_by_user_id, group_shards)
VALUES ('$G', 'wave0 group', '$A', 0);

INSERT INTO public.group_members (group_id, user_id, role, status)
VALUES ('$G', '$A', 'host', 'active');

INSERT INTO public.events
  (id, name, type, created_by_user_id, group_id, location_name,
   location_lat, location_lng, starts_at, ends_at, capacity, status)
VALUES
  ('$E', 'wave0 private event', 'casual', '$A', NULL, 'Exact Venue',
   12.0464, -77.0428, now() + interval '1 day', now() + interval '2 days',
   5, 'upcoming');
SQL

A_JWT="$(mint_user_jwt "$A")"
B_JWT="$(mint_user_jwt "$B")"
H_ANON=(-H "apikey: $ANON_KEY")
H_A=(-H "apikey: $ANON_KEY" -H "Authorization: Bearer $A_JWT")
H_B=(-H "apikey: $ANON_KEY" -H "Authorization: Bearer $B_JWT")
H_SVC=(-H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")

fail=0
check() {
  local name="$1"
  local actual="${@: -1}"
  local expected
  if [ "$#" -eq 3 ]; then
    expected="$2"
  else
    expected="${*:2:$(($# - 2))}"
  fi
  if [[ " $expected " == *" $actual "* ]]; then
    echo "PASS  $name ($actual)"
  else
    echo "FAIL  $name (got $actual, expected $expected)"
    fail=1
  fi
}

code() {
  curl -sS -o /tmp/wave0-resp -w '%{http_code}' "$@"
}

# SEC-001 — writable views.
check "view PATCH denied" 400 401 403 "$(code -X PATCH "${H_A[@]}" \
  "$BASE/rest/v1/user_search_view?id=eq.$B" -H 'Content-Type: application/json' -d '{"bio":"pwned"}')"
check "view DELETE denied" 401 403 "$(code -X DELETE "${H_A[@]}" \
  "$BASE/rest/v1/discovery_view?id=eq.$B")"
check "view anon SELECT denied" 401 403 "$(code "${H_ANON[@]}" \
  "$BASE/rest/v1/user_search_view?select=id&limit=1")"

# SEC-002 — negative donation must not mint shards.
check "negative donation rejected" 400 "$(code -X POST "${H_A[@]}" \
  "$BASE/rest/v1/rpc/donate_shards_to_group" -H 'Content-Type: application/json' \
  -d "{\"p_group_id\":\"$G\",\"p_user_id\":\"$A\",\"p_amount\":-100,\"p_expires_at\":null}")"
balance="$(psql_db -c "SELECT personal_shards FROM public.users WHERE id='$A';")"
[ "$balance" = "1000" ] && echo "PASS  balance unchanged ($balance)" || { echo "FAIL  balance changed ($balance)"; fail=1; }

# SEC-003 — direct cosmetic write denied.
check "direct cosmetic insert denied" 401 403 "$(code -X POST "${H_A[@]}" \
  "$BASE/rest/v1/user_cosmetics" -H 'Content-Type: application/json' \
  -d "{\"user_id\":\"$A\",\"cosmetic_id\":\"$(psql_db -c 'SELECT id FROM public.cosmetics LIMIT 1;')\"}")"

# SEC-004 — client settlement denied.
check "client settlement denied" 401 403 "$(code -X POST "${H_A[@]}" \
  "$BASE/rest/v1/rpc/finish_minigame_game" -H 'Content-Type: application/json' \
  -d "{\"p_session_id\":\"$(uuidgen | tr '[:upper:]' '[:lower:]')\"}")"

# SEC-005 — direct private event read denied; discovery hides exact data.
check "private event read denied" 200 "$(code "${H_A[@]}" \
  "$BASE/rest/v1/events?select=id,location_lat,location_lng,invite_token&id=eq.$E")"
if grep -q '"location_lat"' /tmp/wave0-resp; then
  echo "FAIL  private event row leaked"; fail=1
else
  echo "PASS  private event row not returned"
fi
check "search_events allowed" 200 "$(code -X POST "${H_A[@]}" \
  "$BASE/rest/v1/rpc/search_events" -H 'Content-Type: application/json' -d '{}')"
if grep -q '"location_lat": *[0-9]' /tmp/wave0-resp || grep -q '"invite_token"' /tmp/wave0-resp; then
  echo "FAIL  discovery leaked exact location/token"; fail=1
else
  echo "PASS  discovery returned no exact location/token"
fi

# SEC-006 — forged accepted friendship denied; blocked user cannot delete block.
check "forged accepted friendship denied" 401 403 "$(code -X POST "${H_A[@]}" \
  "$BASE/rest/v1/friendships" -H 'Content-Type: application/json' \
  -d "{\"requester_id\":\"$A\",\"addressee_id\":\"$B\",\"status\":\"accepted\"}")"
psql_db -c "INSERT INTO public.friendships (id, requester_id, addressee_id, status) VALUES ('$BLOCK','$A','$B','blocked');" >/dev/null
code -X DELETE "${H_B[@]}" "$BASE/rest/v1/friendships?id=eq.$BLOCK" >/dev/null
block_left="$(psql_db -c "SELECT count(*) FROM public.friendships WHERE id='$BLOCK';")"
[ "$block_left" = "1" ] && echo "PASS  blocked user cannot delete block" || { echo "FAIL  block row deleted"; fail=1; }

# SEC-007 — direct event insert denied.
check "direct event insert denied" 401 403 "$(code -X POST "${H_A[@]}" \
  "$BASE/rest/v1/events" -H 'Content-Type: application/json' \
  -d "{\"name\":\"forged\",\"type\":\"casual\",\"created_by_user_id\":\"$A\",\"starts_at\":\"2027-01-01T00:00:00Z\",\"ends_at\":\"2027-01-02T00:00:00Z\",\"capacity\":10}")"

# SEC-010 — non-attendee photo insert denied.
check "non-attendee photo denied" 401 403 "$(code -X POST "${H_A[@]}" \
  "$BASE/rest/v1/event_photos" -H 'Content-Type: application/json' \
  -d "{\"event_id\":\"$E\",\"uploaded_by_user_id\":\"$A\",\"storage_path\":\"$E/photos/x.jpg\"}")"

# Q7 — abandonment refunds only when all non-host participants abandon, or
# the host abandons. A subset of non-host abandonments must not refund.
psql_db <<SQL >/dev/null
INSERT INTO public.minigame_sessions
  (id, group_id, game_type, status, shard_wager, player_limit, participants)
VALUES
  ('$S1', NULL, 'questions', 'active', 10, 8, ARRAY['$A','$B','$C']::uuid[]),
  ('$S2', NULL, 'questions', 'active', 10, 8, ARRAY['$A','$B']::uuid[]);

INSERT INTO public.minigame_game_state (session_id, game_type, state)
VALUES
  ('$S1', 'questions', '{"phase":"playing"}'),
  ('$S2', 'questions', '{"phase":"playing"}');

UPDATE public.users SET personal_shards = personal_shards - 10 WHERE id IN ('$A','$B','$C');
UPDATE public.users SET personal_shards = personal_shards - 10 WHERE id IN ('$A','$B');
SQL

r="$(psql_db -c "SET request.jwt.claims='{\"sub\":\"$B\",\"role\":\"authenticated\"}'; SELECT public.abandon_minigame_game('$S1')->>'status';")"
[ "$r" = "recorded" ] && echo "PASS  subset abandonment records without refund" || { echo "FAIL  subset abandonment status=$r"; fail=1; }
bal="$(psql_db -c "SELECT personal_shards FROM public.users WHERE id='$A';")"
[ "$bal" = "980" ] && echo "PASS  subset abandonment kept balances" || { echo "FAIL  subset abandonment changed balance ($bal)"; fail=1; }

r="$(psql_db -c "SET request.jwt.claims='{\"sub\":\"$C\",\"role\":\"authenticated\"}'; SELECT public.abandon_minigame_game('$S1')->>'status';")"
[ "$r" = "abandoned" ] && echo "PASS  all non-host abandonment refunds" || { echo "FAIL  all non-host abandonment status=$r"; fail=1; }

r="$(psql_db -c "SET request.jwt.claims='{\"sub\":\"$A\",\"role\":\"authenticated\"}'; SELECT public.abandon_minigame_game('$S2')->>'status';")"
[ "$r" = "abandoned" ] && echo "PASS  host abandonment refunds" || { echo "FAIL  host abandonment status=$r"; fail=1; }
bal="$(psql_db -c "SELECT personal_shards FROM public.users WHERE id='$A';")"
[ "$bal" = "1000" ] && echo "PASS  abandonment refunded exactly once" || { echo "FAIL  abandonment refund balance ($bal)"; fail=1; }

# SEC-008 — a banned user cannot write through RLS or an RPC.
psql_db -c "INSERT INTO public.group_members (group_id, user_id, role, status) VALUES ('$G','$B','member','active') ON CONFLICT DO NOTHING; UPDATE public.users SET banned_at = now() WHERE id='$B';" >/dev/null
check "banned user direct write denied" 400 403 "$(code -X POST "${H_B[@]}" \
  "$BASE/rest/v1/friendships" -H 'Content-Type: application/json' \
  -d "{\"requester_id\":\"$B\",\"addressee_id\":\"$A\",\"status\":\"pending\"}")"
check "banned user RPC write denied" 400 403 "$(code -X POST "${H_B[@]}" \
  "$BASE/rest/v1/rpc/donate_shards_to_group" -H 'Content-Type: application/json' \
  -d "{\"p_group_id\":\"$G\",\"p_user_id\":\"$B\",\"p_amount\":10,\"p_expires_at\":null}")"
psql_db -c "UPDATE public.users SET banned_at = NULL WHERE id='$B';" >/dev/null

# SEC-009 — report removal actually removes + snapshots + notifies + audits.
psql_db -c "INSERT INTO public.reports (reporter_id, target_type, target_id, reason, status) VALUES ('$A','event','$E','abuse','pending');" >/dev/null
REPORT_ID="$(psql_db -c "SELECT id FROM public.reports WHERE target_id='$E' AND reporter_id='$A' ORDER BY created_at DESC LIMIT 1;" | tr -d '[:space:]')"
printf '{"p_report_id":"%s","p_action":"remove","p_admin_user_id":"00000000-0000-0000-0000-000000000000"}' "$REPORT_ID" > /tmp/wave0-mr.json
check "moderate_report remove" 200 "$(code -X POST "${H_SVC[@]}" \
  "$BASE/rest/v1/rpc/moderate_report" -H 'Content-Type: application/json' \
  --data-binary @/tmp/wave0-mr.json)"
event_state="$(psql_db -c "SELECT status || ':' || name FROM public.events WHERE id='$E';")"
[ "$event_state" = "cancelled:[removed]" ] && echo "PASS  reported event removed" || { echo "FAIL  reported event state=$event_state"; fail=1; }
evidence="$(psql_db -c "SELECT count(*) FROM public.moderation_evidence WHERE report_id='$REPORT_ID';")"
[ "$evidence" = "1" ] && echo "PASS  moderation evidence preserved" || { echo "FAIL  moderation evidence count=$evidence"; fail=1; }
notified="$(psql_db -c "SELECT count(*) FROM public.notifications WHERE user_id='$A' AND type='report_outcome';")"
[ "$notified" = "1" ] && echo "PASS  reporter notified" || { echo "FAIL  reporter notification count=$notified"; fail=1; }

echo
if [ "$fail" -eq 0 ]; then
  echo "Wave 0 abuse checks: PASS"
else
  echo "Wave 0 abuse checks: FAIL"
  exit 1
fi
