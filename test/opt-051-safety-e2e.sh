#!/usr/bin/env bash
# [OPT-051] Wave 0 / G2 safety E2E.
#
# Scenario: two users, a direct chat, a message report, a photo report, admin
# removal through the local admin API, evidence snapshot, reporter
# notifications, audit rows, photo outbox row, storage drainer --once, object
# gone. Then ban user B and replay the reused access token (read/write/RPC) and
# refresh token.
#
# Usage:
#   STACK_ENV=/tmp/samay-c.env \
#   ADMIN_API_URL=http://127.0.0.1:18090 ADMIN_API_KEY=... \
#   bash test/opt-051-safety-e2e.sh
#
# The admin API portion is skipped cleanly when ADMIN_API_URL/ADMIN_API_KEY are
# unset. Requires the storage drainer (cmd/samay-storage-drainer).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STACK_ENV="${STACK_ENV:-$ROOT/supabase/testing-local.env}"

if [ -z "${ADMIN_API_URL:-}" ] || [ -z "${ADMIN_API_KEY:-}" ]; then
  echo "SKIP opt-051: ADMIN_API_URL/ADMIN_API_KEY unset (admin API not running)"
  exit 0
fi

# shellcheck source=/dev/null
. "$ROOT/test/safety-fixture.sh"

PASS=0
FAIL=0
WARN=0

ok() { echo "PASS  $1"; PASS=$((PASS + 1)); }
nok() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }
warn() { echo "WARN  $1"; WARN=$((WARN + 1)); }
h1() { echo; echo "── $1 ──"; }

expect_code() {
  local name="$1" expected="$2" actual="$3"
  if [[ " $expected " == *" $actual "* ]]; then
    ok "$name ($actual)"
  else
    nok "$name (got $actual, expected $expected)"
  fi
}

expect_count() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$name ($actual)"
  else
    nok "$name (got $actual, expected $expected)"
  fi
}

admin_post() {
  local path="$1" body="$2"
  curl -sS -o /tmp/safety-admin-resp -w '%{http_code}' \
    -X POST "$ADMIN_API_URL$path" \
    -H "Authorization: Bearer $ADMIN_API_KEY" \
    -H 'Content-Type: application/json' -d "$body"
}

storage_code() {
  curl -sS -o /dev/null -w '%{http_code}' \
    "$SAFETY_URL/storage/v1/object/events/$SAFETY_STORAGE_PATH" \
    -H "apikey: $SAFETY_SERVICE_KEY" \
    -H "Authorization: Bearer $SAFETY_SERVICE_KEY"
}

user_get() {
  local token="$1" path="$2"
  curl -sS "$SAFETY_URL/rest/v1/$path" -H "apikey: $SAFETY_ANON_KEY" \
    -H "Authorization: Bearer $token"
}

user_post() {
  local token="$1" path="$2" body="$3"
  curl -sS -o /tmp/safety-user-resp -w '%{http_code}' \
    -X POST "$SAFETY_URL/rest/v1/$path" \
    -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' -d "$body"
}

user_rpc() {
  local token="$1" fn="$2" body="$3"
  curl -sS -o /tmp/safety-user-resp -w '%{http_code}' \
    -X POST "$SAFETY_URL/rest/v1/rpc/$fn" \
    -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' -d "$body"
}

dbq() { safety_psql -c "$1"; }

trap safety_fixture_cleanup EXIT

h1 "fixture"
if ! safety_fixture_setup; then
  nok "fixture setup"
  exit 1
fi
ok "fixture setup (users, chat, message, event, photo, reports)"
echo "  chat=$SAFETY_CHAT_ID message=$SAFETY_MESSAGE_ID photo=$SAFETY_PHOTO_ID"

h1 "preconditions"
expect_code "photo object exists before removal" 200 "$(storage_code)"
expect_count "message report pending" 1 \
  "$(dbq "SELECT count(*) FROM public.reports WHERE id='$SAFETY_MSG_REPORT_ID' AND status='pending';")"
expect_count "photo report pending" 1 \
  "$(dbq "SELECT count(*) FROM public.reports WHERE id='$SAFETY_PHOTO_REPORT_ID' AND status='pending';")"
expect_count "photo outbox empty before removal" 0 \
  "$(dbq "SELECT count(*) FROM public.pending_object_deletions WHERE object_name='$SAFETY_STORAGE_PATH';")"

h1 "moderator removes reported message"
code="$(admin_post "/api/v1/admin/reports/$SAFETY_MSG_REPORT_ID/action" '{"action":"remove"}')"
expect_code "admin remove message report" 200 "$code"
expect_count "message row deleted" 0 \
  "$(dbq "SELECT count(*) FROM public.messages WHERE id='$SAFETY_MESSAGE_ID';")"
expect_count "message evidence snapshot retained" 1 \
  "$(dbq "SELECT count(*) FROM public.moderation_evidence WHERE report_id='$SAFETY_MSG_REPORT_ID';")"
expect_count "message report actioned" 1 \
  "$(dbq "SELECT count(*) FROM public.reports WHERE id='$SAFETY_MSG_REPORT_ID' AND status='actioned';")"
expect_count "reporter notified for message removal" 1 \
  "$(dbq "SELECT count(*) FROM public.notifications WHERE user_id='$SAFETY_USER_B' AND type='report_outcome' AND data->>'reportId'='$SAFETY_MSG_REPORT_ID';")"
expect_count "message audit row" 1 \
  "$(dbq "SELECT count(*) FROM public.admin_audit_log WHERE action='report_remove' AND target_type='message' AND target_id='$SAFETY_MESSAGE_ID';")"
expect_count "message report snapshot readable to service" 1 \
  "$(dbq "SELECT count(*) FROM public.message_reports WHERE report_id='$SAFETY_MSG_REPORT_ID' AND plaintext='$SAFETY_MSG_PLAINTEXT';")"

h1 "moderator removes reported photo (queues storage object)"
code="$(admin_post "/api/v1/admin/reports/$SAFETY_PHOTO_REPORT_ID/action" '{"action":"remove"}')"
expect_code "admin remove photo report" 200 "$code"
expect_count "photo row deleted" 0 \
  "$(dbq "SELECT count(*) FROM public.event_photos WHERE id='$SAFETY_PHOTO_ID';")"
expect_count "photo evidence snapshot retained" 1 \
  "$(dbq "SELECT count(*) FROM public.moderation_evidence WHERE report_id='$SAFETY_PHOTO_REPORT_ID';")"
expect_count "photo outbox row queued" 1 \
  "$(dbq "SELECT count(*) FROM public.pending_object_deletions WHERE bucket='events' AND object_name='$SAFETY_STORAGE_PATH' AND processed_at IS NULL;")"
expect_count "photo audit row" 1 \
  "$(dbq "SELECT count(*) FROM public.admin_audit_log WHERE action='report_remove' AND target_type='photo' AND target_id='$SAFETY_PHOTO_ID';")"
expect_count "reporter notified for photo removal" 1 \
  "$(dbq "SELECT count(*) FROM public.notifications WHERE user_id='$SAFETY_USER_B' AND type='report_outcome' AND data->>'reportId'='$SAFETY_PHOTO_REPORT_ID';")"
expect_code "object still present before drainer" 200 "$(storage_code)"

h1 "storage drainer --once"
drain_out="$(SUPABASE_URL="$SAFETY_URL" \
  SUPABASE_SERVICE_ROLE_KEY="$SAFETY_SERVICE_KEY" \
  OBJECT_DRAIN_BATCH_SIZE=50 \
  go run ./cmd/samay-storage-drainer --once 2>&1)"
drain_rc=$?
if [ "$drain_rc" -eq 0 ]; then
  ok "drainer --once exited 0"
else
  nok "drainer --once exited $drain_rc: $drain_out"
fi
if printf '%s' "$drain_out" | grep -q 'deleted=1'; then
  ok "drainer reported one deletion"
else
  warn "drainer output: $(printf '%s' "$drain_out" | tail -n 2 | tr '\n' ' ')"
fi
expect_count "outbox row processed_at set" 1 \
  "$(dbq "SELECT count(*) FROM public.pending_object_deletions WHERE bucket='events' AND object_name='$SAFETY_STORAGE_PATH' AND processed_at IS NOT NULL;")"
obj_code="$(storage_code)"
expect_code "storage object gone after drain" "400 404" "$obj_code"

h1 "storage upload baseline (active user A)"
active_upload="$(curl -sS -o /tmp/safety-active-upload -w '%{http_code}' \
  -X POST "$SAFETY_URL/storage/v1/object/events/safety-fixtures/active-upload.txt" \
  -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $SAFETY_TOKEN_A" \
  -H 'Content-Type: text/plain' -H 'x-upsert: true' \
  --data-binary 'active user upload')"
if [[ " 200 201 " == *" $active_upload "* ]]; then
  ok "active user A storage upload works ($active_upload)"
  curl -sS -o /dev/null -X DELETE \
    "$SAFETY_URL/storage/v1/object/events/safety-fixtures/active-upload.txt" \
    -H "apikey: $SAFETY_SERVICE_KEY" \
    -H "Authorization: Bearer $SAFETY_SERVICE_KEY" >/dev/null 2>&1 || true
else
  warn "SEC-030: active user A storage upload denied ($active_upload); authenticated upload path is broken independent of bans"
fi

h1 "ban user B"
code="$(admin_post "/api/v1/admin/users/$SAFETY_USER_B/ban" '{"reason":"safety-e2e"}')"
expect_code "admin ban user B" 200 "$code"
expect_count "users.banned_at set" 1 \
  "$(dbq "SELECT count(*) FROM public.users WHERE id='$SAFETY_USER_B' AND banned_at IS NOT NULL;")"
expect_count "ban audit row" 1 \
  "$(dbq "SELECT count(*) FROM public.admin_audit_log WHERE action='ban_user' AND target_id='$SAFETY_USER_B';")"

h1 "reused access token after ban"
read_body="$(user_get "$SAFETY_TOKEN_B" "events?select=id&id=eq.$SAFETY_EVENT_ID")"
if [ "$read_body" = "[]" ]; then
  ok "banned token read is filtered (events -> [])"
else
  nok "banned token read returned $(printf '%s' "$read_body" | head -c 120)"
fi

code="$(user_post "$SAFETY_TOKEN_B" "messages" \
  "{\"chat_id\":\"$SAFETY_CHAT_ID\",\"sender_id\":\"$SAFETY_USER_B\",\"content\":\"banned write\"}")"
expect_code "banned token direct write denied" "400 403" "$code"

dbq "INSERT INTO public.messages (id, chat_id, sender_id, content)
     VALUES ('c4444444-4444-4444-8444-444444444455', '$SAFETY_CHAT_ID',
             '$SAFETY_USER_A', 'post-ban report target');" >/dev/null
code="$(user_rpc "$SAFETY_TOKEN_B" "report_message" \
  "{\"p_message_id\":\"c4444444-4444-4444-8444-444444444455\",\"p_reason\":\"spam\",\"p_plaintext\":\"x\"}")"
expect_code "banned token RPC write denied" "400 403" "$code"

refresh_code="$(curl -sS -o /tmp/safety-refresh-resp -w '%{http_code}' \
  -X POST "$SAFETY_URL/auth/v1/token?grant_type=refresh_token" \
  -H "apikey: $SAFETY_ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"refresh_token\":\"$SAFETY_REFRESH_B\"}")"
expect_code "banned refresh token denied" "400 401" "$refresh_code"

h1 "out-of-scope gaps (record only)"
profile_code="$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH \
  "$SAFETY_URL/rest/v1/users?id=eq.$SAFETY_USER_B" \
  -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $SAFETY_TOKEN_B" \
  -H 'Content-Type: application/json' -d '{"bio":"banned profile write"}')"
if [[ " 200 204 " == *" $profile_code "* ]]; then
  warn "SEC-008 gap: banned user can still PATCH own users row ($profile_code)"
else
  ok "banned user denied own users PATCH ($profile_code)"
fi

banned_upload="$(curl -sS -o /tmp/safety-upload-resp -w '%{http_code}' \
  -X POST "$SAFETY_URL/storage/v1/object/events/safety-fixtures/banned-upload.txt" \
  -H "apikey: $SAFETY_ANON_KEY" -H "Authorization: Bearer $SAFETY_TOKEN_B" \
  -H 'Content-Type: text/plain' -H 'x-upsert: true' \
  --data-binary 'banned user upload')"
if [[ " 200 201 " == *" $banned_upload "* ]]; then
  warn "SEC-030 gap: banned user still uploads to Storage ($banned_upload)"
  curl -sS -o /dev/null -X DELETE \
    "$SAFETY_URL/storage/v1/object/events/safety-fixtures/banned-upload.txt" \
    -H "apikey: $SAFETY_SERVICE_KEY" \
    -H "Authorization: Bearer $SAFETY_SERVICE_KEY" >/dev/null 2>&1 || true
else
  ok "banned user storage upload denied ($banned_upload)"
fi

echo
echo "opt-051: PASS=$PASS FAIL=$FAIL WARN=$WARN"
[ "$FAIL" -eq 0 ]
