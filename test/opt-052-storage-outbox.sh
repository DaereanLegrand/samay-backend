#!/usr/bin/env bash
# [OPT-052] storage outbox drainer.
#
# Exercises cmd/samay-storage-drainer --once against the live storage API:
#   * an existing object is deleted and its outbox row is marked processed;
#   * a row whose object is already gone (NoSuchKey/not_found) is treated as
#     success and marked processed;
#   * a row pointing at a missing bucket is NOT marked processed.
#
# Usage: STACK_ENV=/tmp/samay-c.env bash test/opt-052-storage-outbox.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STACK_ENV="${STACK_ENV:-$ROOT/supabase/.env}"

read_env() {
  sed -n "s/^${1}=\([^[:space:]#]*\).*/\1/p" "$STACK_ENV" | head -1
}

DB_PORT="$(read_env POSTGRES_PORT)"; DB_PORT="${DB_PORT:-54382}"
KONG_PORT="$(read_env KONG_HTTP_PORT)"; KONG_PORT="${KONG_PORT:-54386}"
ANON_KEY="$(read_env SUPABASE_ANON_KEY)"
SERVICE_KEY="$(read_env SUPABASE_SERVICE_ROLE_KEY)"
URL="http://127.0.0.1:${KONG_PORT}"

[ -n "$ANON_KEY" ] && [ -n "$SERVICE_KEY" ] || {
  echo "missing keys in $STACK_ENV" >&2
  exit 1
}

EXISTING_PATH="safety-outbox/existing.bin"
MISSING_PATH="safety-outbox/missing.bin"
POISON_BUCKET="safety-missing-bucket"
POISON_PATH="safety-outbox/poison.bin"

psql_db() {
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$DB_PORT" -U postgres \
    -d postgres -v ON_ERROR_STOP=1 -tAq "$@"
}

svc() {
  curl -sS -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" "$@"
}

object_code() {
  local bucket="$1" path="$2"
  curl -sS -o /dev/null -w '%{http_code}' \
    "$URL/storage/v1/object/$bucket/$path" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY"
}

cleanup() {
  svc -o /dev/null -X DELETE "$URL/storage/v1/object/events/$EXISTING_PATH" >/dev/null 2>&1 || true
  svc -o /dev/null -X DELETE "$URL/storage/v1/object/events/$MISSING_PATH" >/dev/null 2>&1 || true
  psql_db -c "DELETE FROM public.pending_object_deletions
              WHERE object_name IN ('$EXISTING_PATH','$MISSING_PATH','$POISON_PATH');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { echo "PASS  $1"; PASS=$((PASS + 1)); }
nok() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }
expect_code() {
  local name="$1" expected="$2" actual="$3"
  if [[ " $expected " == *" $actual "* ]]; then ok "$name ($actual)"; else
    nok "$name (got $actual, expected $expected)"; fi
}
expect_count() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$name ($actual)"; else
    nok "$name (got $actual, expected $expected)"; fi
}

cleanup

echo "── setup ──"
tmp="$(mktemp "${TMPDIR:-/tmp}/samay-outbox.XXXXXX")"
printf 'outbox fixture bytes\n' >"$tmp"
upload="$(svc -X POST "$URL/storage/v1/object/events/$EXISTING_PATH" \
  -H 'Content-Type: image/jpeg' -H 'x-upsert: true' \
  --data-binary "@$tmp")"
rm -f "$tmp"
if printf '%s' "$upload" | grep -q '"Key"\|"key"\|Successfully'; then
  ok "existing object uploaded"
else
  nok "existing object upload: $(printf '%s' "$upload" | head -c 160)"
fi
expect_code "existing object readable" 200 "$(object_code events "$EXISTING_PATH")"

psql_db -c "INSERT INTO public.pending_object_deletions (bucket, object_name)
            VALUES ('events','$EXISTING_PATH'), ('events','$MISSING_PATH'),
                   ('$POISON_BUCKET','$POISON_PATH');" >/dev/null
expect_count "three unprocessed outbox rows" 3 \
  "$(psql_db -c "SELECT count(*) FROM public.pending_object_deletions
                 WHERE object_name IN ('$EXISTING_PATH','$MISSING_PATH','$POISON_PATH')
                   AND processed_at IS NULL;")"

echo "── drainer --once ──"
out="$(SUPABASE_URL="$URL" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_KEY" \
  OBJECT_DRAIN_BATCH_SIZE=10 OBJECT_DRAIN_MAX_ATTEMPTS=1 \
  go run ./cmd/samay-storage-drainer --once 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "drainer exited 0"; else nok "drainer exited $rc: $out"; fi
printf '%s\n' "$out" | tail -n 5

expect_count "existing row processed" 1 \
  "$(psql_db -c "SELECT count(*) FROM public.pending_object_deletions
                 WHERE object_name='$EXISTING_PATH' AND processed_at IS NOT NULL;")"
expect_count "already-missing object row processed (idempotent)" 1 \
  "$(psql_db -c "SELECT count(*) FROM public.pending_object_deletions
                 WHERE object_name='$MISSING_PATH' AND processed_at IS NOT NULL;")"
expect_count "missing-bucket row NOT processed" 1 \
  "$(psql_db -c "SELECT count(*) FROM public.pending_object_deletions
                 WHERE bucket='$POISON_BUCKET' AND object_name='$POISON_PATH'
                   AND processed_at IS NULL;")"
expect_code "existing object deleted" "400 404" "$(object_code events "$EXISTING_PATH")"

echo "── second --once is idempotent ──"
out2="$(SUPABASE_URL="$URL" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_KEY" \
  OBJECT_DRAIN_BATCH_SIZE=10 OBJECT_DRAIN_MAX_ATTEMPTS=1 \
  go run ./cmd/samay-storage-drainer --once 2>&1)"
rc2=$?
if [ "$rc2" -eq 0 ]; then ok "second drainer exited 0"; else nok "second drainer exited $rc2: $out2"; fi
expect_count "successful rows stay processed" 2 \
  "$(psql_db -c "SELECT count(*) FROM public.pending_object_deletions
                 WHERE object_name IN ('$EXISTING_PATH','$MISSING_PATH')
                   AND processed_at IS NOT NULL;")"
expect_count "poison row still unprocessed" 1 \
  "$(psql_db -c "SELECT count(*) FROM public.pending_object_deletions
                 WHERE object_name='$POISON_PATH' AND processed_at IS NULL;")"

echo
echo "opt-052: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
