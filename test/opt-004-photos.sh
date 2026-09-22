#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-004] Photo Gallery Contract — Integration Test
# Verifies the event_photos surface (I-76, phase 08 PHUP):
#   A) event_photos insert (own row, storage_path) via svc — the storage
#      bucket itself is NOT reachable from curl (no storage API against a
#      bucket without an object; signed URLs are MediaService
#      createSignedUrl client-side) — the DB contract is what is asserted:
#      the row + storage_path round-trip.
#   B) RLS read: event member CAN read event_photos; non-member CANNOT
#      (eph_read_access, migration 20260809000002 §9); anon CANNOT either
#   C) likes: event_photo_likes insert -> photo_likes_count_trigger keeps
#      event_photos.likes_count in sync (2 svc likes -> count=2)
#   D) duplicate like blocked by UNIQUE (photo_id, user_id) -> 23505
#   E) non-member like DENIED by epl_insert_own access check (§10 — a user
#      cannot like photos of events they cannot access)
#
# SELF-CONTAINED: creates its own rows with fixed UUIDs (svc_* setup), exactly
# like opt-001.
#
# STATIC-VERIFIED ONLY (this agent run): the stack is not started until the
# checkpoint (AGENT-RULES / port map). Live run: make supabase-docker-start &&
# make supabase-docker-reset && bash test/opt-004-photos.sh
#
# Usage: bash test/opt-004-photos.sh
#
# Keys (M-03 alignment): resolved at runtime by test/dev_env.sh from the
# gitignored stack .env (supabase-testing/ then supabase/) — dev-only; CI
# overrides them via env vars.
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

# Fixed IDs (unique to this file — opt-001/002/003 use 1111.../4444.../5555...).
UUID_A="66666666-6666-6666-6666-666666666666"
UUID_B="66666666-6666-6666-6666-666666666667"
EMAIL_A="user_a_opt004@samay.test"
EMAIL_B="user_b_opt004@samay.test"
PW="Pass1234!"
GROUP_ID="66666666-6666-6666-6666-666666666101"
EVENT_ID="66666666-6666-6666-6666-666666666201"
PHOTO_ID="66666666-6666-6666-6666-666666666301"
LIKE_A="66666666-6666-6666-6666-666666666401"
LIKE_B="66666666-6666-6666-6666-666666666402"
STORAGE_PATH="events/$EVENT_ID/photos/opt004.jpg"

cleanup() {
  svc_delete_quiet "event_photos?id=eq.$PHOTO_ID"
  svc_delete_quiet "events?id=eq.$EVENT_ID"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B)"
  for uid in $UUID_A $UUID_B; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" > /dev/null 2>&1 || true
  done
}

ok()   { echo "  ✅ PASS: $1"; ((PASS++)); }
nok()  { echo "  ❌ FAIL: $1"; ((FAIL++)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

anon_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY"
}
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t"
}
auth_post() {
  local t=$1; shift
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
}
svc_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
}
svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2" 2>/dev/null
}
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Setup: users A (member) / B (outsider), group-scoped event
# ---------------------------------------------------------------------------
h1 "SETUP: users + group-scoped event"

trap cleanup EXIT
cleanup

resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID_A\"}")
if echo "$resp" | grep -q '"id"'; then ok "Created auth user A ($UUID_A)"; else nok "Create user A: $(echo "$resp" | head -c 80)"; fi

resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$UUID_B\"}")
if echo "$resp" | grep -q '"id"'; then ok "Created auth user B ($UUID_B)"; else nok "Create user B: $(echo "$resp" | head -c 80)"; fi

svc_post "users" "{\"id\":\"$UUID_A\",\"username\":\"user_a_opt004\",\"personal_shards\":1000}" > /dev/null
svc_post "users" "{\"id\":\"$UUID_B\",\"username\":\"user_b_opt004\",\"personal_shards\":1000}" > /dev/null
ok "Inserted user rows in public.users"

TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_B=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ]; then
  ok "Obtained auth tokens for both users"
else
  nok "Failed to get auth tokens"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Opt004 Group\",\"created_by_user_id\":\"$UUID_A\"}" > /dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" > /dev/null
svc_post "events" "{\"id\":\"$EVENT_ID\",\"name\":\"Opt004 Event\",\"type\":\"casual\",\
\"created_by_user_id\":\"$UUID_A\",\"group_id\":\"$GROUP_ID\",\"join_mode\":\"approval\",\
\"starts_at\":\"2026-12-31T23:00:00Z\",\"ends_at\":\"2027-01-01T02:00:00Z\",\
\"preshards_pool\":0,\"status\":\"upcoming\"}" > /dev/null
ok "Group-scoped event seeded (A member, B outsider)"

# =========================================================================
# TEST A — event_photos insert (own row with storage_path)
# =========================================================================
h1 "TEST A — event_photos insert + storage_path round-trip"

resp=$(svc_post "event_photos" "{\"id\":\"$PHOTO_ID\",\"event_id\":\"$EVENT_ID\",\
\"uploaded_by_user_id\":\"$UUID_A\",\"storage_path\":\"$STORAGE_PATH\",\"likes_count\":0}")
if [ -z "$resp" ]; then
  ok "event_photos insert accepted (svc setup)"
else
  nok "event_photos insert: $(echo "$resp" | head -c 80)"
fi

row=$(svc_get "event_photos?id=eq.$PHOTO_ID&select=id,event_id,uploaded_by_user_id,storage_path,likes_count,reported")
if echo "$row" | grep -q "\"storage_path\":\"$STORAGE_PATH\"" && echo "$row" | grep -q '"likes_count":0'; then
  ok "Photo row persisted with storage_path + likes_count=0 (bucket API not reachable from curl — DB contract asserted)"
else
  nok "Photo row wrong: $(echo "$row" | head -c 120)"
fi

# =========================================================================
# TEST B — RLS read: member CAN, non-member CANNOT, anon CANNOT
# =========================================================================
h1 "TEST B — event_photos visibility (eph_read_access)"

resp=$(auth_get "$TOKEN_A" "event_photos?id=eq.$PHOTO_ID&select=id,storage_path")
if echo "$resp" | grep -q "\"storage_path\":\"$STORAGE_PATH\""; then
  ok "Member A CAN read event photo"
else
  nok "Member A CANNOT read photo: $(echo "$resp" | head -c 60)"
fi

resp=$(auth_get "$TOKEN_B" "event_photos?id=eq.$PHOTO_ID&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied|PGRST204)'; then
  ok "Non-member B CANNOT read event photo (RLS)"
else
  nok "Non-member B CAN read event photo: $(echo "$resp" | head -c 60)"
fi

resp=$(anon_get "event_photos?id=eq.$PHOTO_ID&select=id")
if [ "$resp" = "[]" ] || echo "$resp" | grep -qE '(42501|permission denied)'; then
  ok "anon CANNOT read event photo (no anon policy)"
else
  nok "anon CAN read event photo: $(echo "$resp" | head -c 60)"
fi

# =========================================================================
# TEST C — likes via svc -> photo_likes_count_trigger maintains likes_count
# =========================================================================
h1 "TEST C — likes_count maintained by photo_likes_count_trigger"

svc_post "event_photo_likes" "{\"id\":\"$LIKE_A\",\"photo_id\":\"$PHOTO_ID\",\"user_id\":\"$UUID_A\"}" > /dev/null
cnt=$(svc_get "event_photos?id=eq.$PHOTO_ID&select=likes_count" | grep -o '"likes_count":[0-9]*' | grep -o '[0-9]*')
if [ "$cnt" = "1" ]; then
  ok "1 like -> likes_count=1 (trigger)"
else
  nok "likes_count expected 1, got '$cnt'"
fi

svc_post "event_photo_likes" "{\"id\":\"$LIKE_B\",\"photo_id\":\"$PHOTO_ID\",\"user_id\":\"$UUID_B\"}" > /dev/null
cnt=$(svc_get "event_photos?id=eq.$PHOTO_ID&select=likes_count" | grep -o '"likes_count":[0-9]*' | grep -o '[0-9]*')
if [ "$cnt" = "2" ]; then
  ok "2 likes -> likes_count=2 (trigger)"
else
  nok "likes_count expected 2, got '$cnt'"
fi

# =========================================================================
# TEST D — duplicate like blocked by UNIQUE (photo_id, user_id)
# =========================================================================
h1 "TEST D — duplicate like -> UNIQUE violation"

resp=$(svc_post "event_photo_likes" "{\"id\":\"66666666-6666-6666-6666-666666666403\",\"photo_id\":\"$PHOTO_ID\",\"user_id\":\"$UUID_A\"}")
if echo "$resp" | grep -qE '(23505|duplicate key|event_photo_likes_photo_id_user_id_key)'; then
  ok "Duplicate like rejected (UNIQUE (photo_id, user_id))"
else
  nok "Duplicate like NOT rejected: $(echo "$resp" | head -c 80)"
fi
cnt=$(svc_get "event_photo_likes?photo_id=eq.$PHOTO_ID&select=id" | grep -c '"id"' || true)
if [ "$cnt" -eq 2 ]; then
  ok "Still exactly 2 like rows"
else
  nok "Expected 2 like rows, found $cnt"
fi

# =========================================================================
# TEST E — non-member like denied (epl_insert_own access check)
# =========================================================================
h1 "TEST E — epl_insert_own access check (no likes on invisible events)"

resp=$(auth_post "$TOKEN_B" "event_photo_likes" "{\"photo_id\":\"$PHOTO_ID\",\"user_id\":\"$UUID_B\"}")
if echo "$resp" | grep -qE '(42501|violates row-level security|PGRST)'; then
  ok "Non-member B like DENIED (epl_insert_own photo-access check)"
else
  nok "Non-member B like NOT denied: $(echo "$resp" | head -c 80)"
fi
cnt=$(svc_get "event_photos?id=eq.$PHOTO_ID&select=likes_count" | grep -o '"likes_count":[0-9]*' | grep -o '[0-9]*')
if [ "$cnt" = "2" ]; then
  ok "likes_count still 2 after denied like"
else
  nok "likes_count changed after denied like: '$cnt'"
fi

# =========================================================================
# Summary
# =========================================================================
h1 "RESULTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "  🎉 All tests passed!"
  exit 0
else
  echo ""
  echo "  💥 Some tests failed."
  exit 1
fi
