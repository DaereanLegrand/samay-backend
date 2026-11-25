#!/usr/bin/env bash
# Safety fixture for the Wave 0 / G2 tests.
#
# Usage:
#   STACK_ENV=/tmp/samay-c.env bash test/safety-fixture.sh setup|cleanup|print
#
# Source it from another test to get the fixture functions + globals:
#   . test/safety-fixture.sh
#   safety_fixture_cleanup
#   safety_fixture_setup
#
# It only creates the two users, one direct chat, one message, one event and
# one reported photo object. It never touches staging/prod or another stack.
set -uo pipefail

SAFETY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_ENV="${STACK_ENV:-$SAFETY_ROOT/.env/testing-local.env}"

safety_read_env() {
  sed -n "s/^${1}=\([^[:space:]#]*\).*/\1/p" "$STACK_ENV" | head -1
}

SAFETY_DB_PORT="$(safety_read_env POSTGRES_PORT)"
SAFETY_KONG_PORT="$(safety_read_env KONG_HTTP_PORT)"
SAFETY_DB_PORT="${SAFETY_DB_PORT:-54392}"
SAFETY_KONG_PORT="${SAFETY_KONG_PORT:-54386}"
SAFETY_URL="${SUPABASE_URL:-http://127.0.0.1:${SAFETY_KONG_PORT}}"
SAFETY_ANON_KEY="${SUPABASE_ANON_KEY:-$(safety_read_env SUPABASE_ANON_KEY)}"
SAFETY_SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-$(safety_read_env SUPABASE_SERVICE_ROLE_KEY)}"

SAFETY_USER_A="c1111111-1111-4111-8111-111111111111"
SAFETY_USER_B="c2222222-2222-4222-8222-222222222222"
SAFETY_CHAT_ID="c3333333-3333-4333-8333-333333333333"
SAFETY_MESSAGE_ID="c4444444-4444-4444-8444-444444444444"
SAFETY_EVENT_ID="c5555555-5555-4555-8555-555555555555"
SAFETY_PHOTO_ID="c6666666-6666-4666-8666-666666666666"
SAFETY_STORAGE_PATH="safety-fixtures/lane-c-photo.jpg"
SAFETY_EMAIL_A="safety_a_lane_c@samay.test"
SAFETY_EMAIL_B="safety_b_lane_c@samay.test"
SAFETY_PASSWORD="Pass1234!"
SAFETY_MSG_PLAINTEXT="reported plaintext (fixture)"
SAFETY_MSG_REPORT_ID=""
SAFETY_PHOTO_REPORT_ID=""
SAFETY_TOKEN_A=""
SAFETY_TOKEN_B=""
SAFETY_REFRESH_B=""
SAFETY_ADMIN_ROW_CREATED=0

safety_psql() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$SAFETY_DB_PORT" -U postgres \
    -d postgres -v ON_ERROR_STOP=1 -tAq "$@"
}

safety_pyget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, list):
        d = d[0] if d else None
    d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        break
print("" if d is None else d)
' "$1"
}

safety_svc() {
  curl -sS -H "apikey: $SAFETY_SERVICE_KEY" \
    -H "Authorization: Bearer $SAFETY_SERVICE_KEY" "$@"
}

safety_auth_token() {
  curl -sS -X POST "$SAFETY_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $SAFETY_ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$SAFETY_PASSWORD\"}"
}

safety_delete_object() {
  curl -sS -o /dev/null -X DELETE \
    "$SAFETY_URL/storage/v1/object/events/$SAFETY_STORAGE_PATH" \
    -H "apikey: $SAFETY_SERVICE_KEY" \
    -H "Authorization: Bearer $SAFETY_SERVICE_KEY" >/dev/null 2>&1 || true
}

safety_fixture_cleanup() {
  safety_delete_object
  safety_psql <<SQL >/dev/null 2>&1 || true
DELETE FROM public.pending_object_deletions
 WHERE bucket = 'events' AND object_name = '$SAFETY_STORAGE_PATH';
DELETE FROM public.moderation_evidence
 WHERE report_id IN (
   SELECT id FROM public.reports
    WHERE reporter_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B')
 );
DELETE FROM public.message_reports
 WHERE reporter_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B');
DELETE FROM public.reports
 WHERE reporter_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B');
DELETE FROM public.notifications
 WHERE user_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B');
DELETE FROM public.messages
 WHERE chat_id IN (
   SELECT chat_id FROM public.chat_participants
    WHERE user_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B')
 ) OR sender_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B');
DELETE FROM public.chats
 WHERE id IN (
   SELECT chat_id FROM public.chat_participants
    WHERE user_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B')
 );
DELETE FROM public.chat_participants
 WHERE user_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B');
DELETE FROM public.event_photo_likes WHERE photo_id = '$SAFETY_PHOTO_ID';
DELETE FROM public.event_photos WHERE id = '$SAFETY_PHOTO_ID' OR event_id = '$SAFETY_EVENT_ID';
DELETE FROM public.events WHERE id = '$SAFETY_EVENT_ID';
DELETE FROM public.friendships
 WHERE requester_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B')
    OR addressee_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B');
DELETE FROM public.admin_audit_log
 WHERE target_id IN ('$SAFETY_USER_A', '$SAFETY_USER_B', '$SAFETY_MESSAGE_ID', '$SAFETY_PHOTO_ID');
DELETE FROM public.users WHERE id IN ('$SAFETY_USER_A', '$SAFETY_USER_B');
SQL
  for uid in "$SAFETY_USER_A" "$SAFETY_USER_B"; do
    curl -sS -o /dev/null -X DELETE "$SAFETY_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SAFETY_SERVICE_KEY" \
      -H "Authorization: Bearer $SAFETY_SERVICE_KEY" >/dev/null 2>&1 || true
  done
  if [ "${SAFETY_ADMIN_ROW_CREATED:-0}" = "1" ] && [ -n "${SUPABASE_ADMIN_USER_ID:-}" ]; then
    safety_psql -c "DELETE FROM public.admin_audit_log
                    WHERE admin_user_id='$SUPABASE_ADMIN_USER_ID';
                    DELETE FROM public.admin_users WHERE id='$SUPABASE_ADMIN_USER_ID';" >/dev/null 2>&1 || true
    SAFETY_ADMIN_ROW_CREATED=0
  fi
  SAFETY_MSG_REPORT_ID=""
  SAFETY_PHOTO_REPORT_ID=""
  SAFETY_TOKEN_A=""
  SAFETY_TOKEN_B=""
  SAFETY_REFRESH_B=""
}

safety_fixture_setup() {
  safety_fixture_cleanup

  if [ -n "${SUPABASE_ADMIN_USER_ID:-}" ]; then
    local admin_exists
    admin_exists="$(safety_psql -c "SELECT count(*) FROM public.admin_users WHERE id='$SUPABASE_ADMIN_USER_ID';")"
    if [ "$admin_exists" = "0" ]; then
      safety_psql -c "INSERT INTO public.admin_users (id, email, display_name, role)
        VALUES ('$SUPABASE_ADMIN_USER_ID', 'safety-admin-lane-c@samay.test',
                'Safety Admin', 'moderator');" >/dev/null
      SAFETY_ADMIN_ROW_CREATED=1
    fi
  fi

  local uid email username resp token_json
  for spec in \
    "$SAFETY_USER_A $SAFETY_EMAIL_A safety_a" \
    "$SAFETY_USER_B $SAFETY_EMAIL_B safety_b"; do
    set -- $spec
    uid="$1"; email="$2"; username="$3"
    resp="$(safety_svc -X POST "$SAFETY_URL/auth/v1/admin/users" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"$email\",\"password\":\"$SAFETY_PASSWORD\",\"email_confirm\":true,\"id\":\"$uid\"}")"
    if ! printf '%s' "$resp" | grep -q '"id"'; then
      echo "safety-fixture: auth create failed for $username: $(printf '%s' "$resp" | head -c 160)" >&2
      return 1
    fi
    safety_svc -X POST "$SAFETY_URL/rest/v1/users" \
      -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
      -d "{\"id\":\"$uid\",\"username\":\"$username\",\"date_of_birth\":\"1990-01-01\",\"personal_shards\":100}" >/dev/null
  done

  token_json="$(safety_auth_token "$SAFETY_EMAIL_A")"
  SAFETY_TOKEN_A="$(printf '%s' "$token_json" | safety_pyget access_token)"
  token_json="$(safety_auth_token "$SAFETY_EMAIL_B")"
  SAFETY_TOKEN_B="$(printf '%s' "$token_json" | safety_pyget access_token)"
  SAFETY_REFRESH_B="$(printf '%s' "$token_json" | safety_pyget refresh_token)"
  if [ -z "$SAFETY_TOKEN_A" ] || [ -z "$SAFETY_TOKEN_B" ] || [ -z "$SAFETY_REFRESH_B" ]; then
    echo "safety-fixture: password grant failed" >&2
    return 1
  fi

  safety_psql <<SQL >/dev/null
INSERT INTO public.events
  (id, name, type, created_by_user_id, location_name, location_lat, location_lng,
   starts_at, ends_at, capacity, status)
VALUES
  ('$SAFETY_EVENT_ID', 'safety fixture event', 'casual', '$SAFETY_USER_A',
   'Fixture Venue', 12.0464, -77.0428, now() + interval '1 day',
   now() + interval '2 days', 5, 'upcoming');
SQL

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/samay-safety-photo.XXXXXX")"
  printf 'safety fixture image bytes\n' >"$tmp"
  resp="$(curl -sS -X POST "$SAFETY_URL/storage/v1/object/events/$SAFETY_STORAGE_PATH" \
    -H "apikey: $SAFETY_SERVICE_KEY" \
    -H "Authorization: Bearer $SAFETY_SERVICE_KEY" \
    -H 'Content-Type: image/jpeg' -H 'x-upsert: true' \
    --data-binary "@$tmp")"
  rm -f "$tmp"
  if ! printf '%s' "$resp" | grep -q '"Key"\|"key"\|Successfully'; then
    echo "safety-fixture: storage upload failed: $(printf '%s' "$resp" | head -c 160)" >&2
    return 1
  fi

  safety_psql <<SQL >/dev/null
INSERT INTO public.event_photos
  (id, event_id, uploaded_by_user_id, storage_path, likes_count, reported)
VALUES
  ('$SAFETY_PHOTO_ID', '$SAFETY_EVENT_ID', '$SAFETY_USER_A',
   '$SAFETY_STORAGE_PATH', 0, true);
SQL

  local chat_resp
  chat_resp="$(curl -sS -X POST "$SAFETY_URL/rest/v1/rpc/create_direct_chat" \
    -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $SAFETY_TOKEN_A" \
    -H 'Content-Type: application/json' \
    -d "{\"p_peer_id\":\"$SAFETY_USER_B\"}")"
  local chat_id
  chat_id="$(printf '%s' "$chat_resp" | safety_pyget chatId)"
  if [ -z "$chat_id" ]; then
    echo "safety-fixture: create_direct_chat returned no chatId: $(printf '%s' "$chat_resp" | head -c 160)" >&2
    return 1
  fi
  SAFETY_CHAT_ID="$chat_id"

  curl -sS -X POST "$SAFETY_URL/rest/v1/messages" \
    -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $SAFETY_TOKEN_A" \
    -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
    -d "{\"id\":\"$SAFETY_MESSAGE_ID\",\"chat_id\":\"$SAFETY_CHAT_ID\",\"sender_id\":\"$SAFETY_USER_A\",\"content\":\"safety fixture ciphertext\"}" >/dev/null

  local report_resp
  report_resp="$(curl -sS -X POST "$SAFETY_URL/rest/v1/rpc/report_message" \
    -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $SAFETY_TOKEN_B" \
    -H 'Content-Type: application/json' \
    -d "{\"p_message_id\":\"$SAFETY_MESSAGE_ID\",\"p_reason\":\"harassment\",\"p_plaintext\":\"$SAFETY_MSG_PLAINTEXT\"}")"
  SAFETY_MSG_REPORT_ID="$(printf '%s' "$report_resp" | safety_pyget report_id)"
  if [ -z "$SAFETY_MSG_REPORT_ID" ]; then
    echo "safety-fixture: report_message failed: $(printf '%s' "$report_resp" | head -c 160)" >&2
    return 1
  fi

  local photo_report
  photo_report="$(curl -sS -X POST "$SAFETY_URL/rest/v1/reports" \
    -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $SAFETY_TOKEN_B" \
    -H 'Content-Type: application/json' -H 'Prefer: return=minimal' \
    -d "{\"reporter_id\":\"$SAFETY_USER_B\",\"target_type\":\"photo\",\"target_id\":\"$SAFETY_PHOTO_ID\",\"reason\":\"abuse\",\"status\":\"pending\"}")"
  if [ -n "$photo_report" ]; then
    echo "safety-fixture: photo report failed: $(printf '%s' "$photo_report" | head -c 160)" >&2
    return 1
  fi
  SAFETY_PHOTO_REPORT_ID="$(safety_psql -c "SELECT id FROM public.reports WHERE reporter_id='$SAFETY_USER_B' AND target_id='$SAFETY_PHOTO_ID' ORDER BY created_at DESC LIMIT 1;")"
  if [ -z "$SAFETY_PHOTO_REPORT_ID" ]; then
    echo "safety-fixture: photo report row not found" >&2
    return 1
  fi
}

safety_fixture_print() {
  printf 'SAFETY_URL=%s\n' "$SAFETY_URL"
  printf 'SAFETY_USER_A=%s\n' "$SAFETY_USER_A"
  printf 'SAFETY_USER_B=%s\n' "$SAFETY_USER_B"
  printf 'SAFETY_CHAT_ID=%s\n' "$SAFETY_CHAT_ID"
  printf 'SAFETY_MESSAGE_ID=%s\n' "$SAFETY_MESSAGE_ID"
  printf 'SAFETY_EVENT_ID=%s\n' "$SAFETY_EVENT_ID"
  printf 'SAFETY_PHOTO_ID=%s\n' "$SAFETY_PHOTO_ID"
  printf 'SAFETY_STORAGE_PATH=%s\n' "$SAFETY_STORAGE_PATH"
  printf 'SAFETY_MSG_REPORT_ID=%s\n' "$SAFETY_MSG_REPORT_ID"
  printf 'SAFETY_PHOTO_REPORT_ID=%s\n' "$SAFETY_PHOTO_REPORT_ID"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    setup) safety_fixture_setup ;;
    cleanup) safety_fixture_cleanup ;;
    print) safety_fixture_print ;;
    *)
      echo "usage: STACK_ENV=/path/to/stack.env $0 setup|cleanup|print" >&2
      exit 2
      ;;
  esac
fi
