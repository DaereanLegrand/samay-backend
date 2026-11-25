#!/usr/bin/env bash
# =============================================================================
# Samay — seed-feed-test.sh
#
# BIG, configurable @tester seed for the LOCAL supabase stack:
#   * N numbered accounts (tester2..testerN) + tester1@tester.com, password
#     tester123 — created through the GoTrue admin API.
#   * realistic colorful profile pictures for EVERY account (randomuser.me
#     portraits), plus event banners + group covers + event photos (Lorem
#     Picsum), downloaded and uploaded to the avatars/events/groups buckets.
#   * groups, events, minigames, invites, friendships, chats and notifications
#     across all of their states (data lives in
#     supabase/seed/seed-feed-test.sql).
#
# This is INDEPENDENT from `seed-test.sql` (the small @tester snapshot) which
# is left untouched.
#
# SAFETY: only ever talks to the local testing stack (127.0.0.1:54396 Kong /
# 127.0.0.1:54392 Postgres). Refuses any other host; never reads root .env.
#
# Usage:
#   bash tools/seed-feed-test.sh            # N=100 (default)
#   N=40  bash tools/seed-feed-test.sh      # tester2..tester40
#   bash tools/seed-feed-test.sh 40         # same, positional
#
#   PUBLIC_BASE_URL=http://<host>:54396 bash tools/seed-feed-test.sh
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

N="${N:-${1:-100}}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "❌ N must be an integer (got '$N')"; exit 1; }
(( N >= 2 ))   || { echo "❌ N must be >= 2 (got $N)"; exit 1; }
(( N <= 100 )) || echo "⚠️  N=$N > 100: randomuser.me has 100 portraits per gender; faces will repeat."

BASE="${PUBLIC_BASE_URL:-http://127.0.0.1:54396}"
if [[ "$BASE" != *"127.0.0.1:54396"* && "$BASE" != *"localhost:54396"* ]]; then
  echo "❌ refusing to run: PUBLIC_BASE_URL/$BASE is not the local testing Kong (expected 127.0.0.1:54396)"
  exit 1
fi

# shellcheck disable=SC1091
set -a; . .env/testing-local.env; set +a

SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
[[ -n "$SERVICE_KEY" ]] || { echo "❌ SUPABASE_SERVICE_ROLE_KEY missing from .env/testing-local.env"; exit 1; }

DB_HOST=127.0.0.1
DB_PORT="${POSTGRES_PORT:-54392}"
DB_NAME="${SEED_DB:-postgres}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PASS="${POSTGRES_PASSWORD:-postgres}"
PASSWORD='tester123'

psql_db() { PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"; }

uid_user() {  # uid_user <k>  (k=1 → tester, k>=2 → deterministic)
  if (( $1 == 1 )); then echo "6f8108f5-3964-45df-82a1-76a5d9185c10";
  else printf '00000000-0000-0000-0000-%012d' "$1"; fi
}
uid_kind() { printf '00000000-0000-0000-%s-%012d' "$1" "$2"; }   # uid_kind <kind> <i>

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "═══════════════════════════════════════════════════════════════"
echo "  seed-feed-test → $BASE   (N = $N accounts + tester1)"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Clean the previous @tester auth universe ─────────────────────────────
echo "→ 1/6 Clearing previous @tester auth rows…"
psql_db -q <<'SQL'
SET session_replication_role = replica;
DELETE FROM auth.identities
 WHERE identity_data->>'email' LIKE '%@tester.com'
    OR user_id IN (SELECT id FROM auth.users WHERE email LIKE '%@tester.com');
DELETE FROM auth.users WHERE email LIKE '%@tester.com';
SQL

# ── 2. Create auth users (password tester123) ───────────────────────────────
echo "→ 2/6 Creating $N accounts via the admin API…"
create_or_update_user() {
  local uid="$1" email="$2"
  local resp code body
  resp=$(curl -sS -w $'\n%{http_code}' -X POST "$BASE/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$uid\",\"email\":\"$email\",\"password\":\"$PASSWORD\",\"email_confirm\":true}" || true)
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [[ "$code" != "200" && "$code" != "201" && "$code" != "422" ]]; then
    echo "❌ admin create failed for $email (HTTP $code): $body"; exit 1
  fi
  # Re-assert the password so login is guaranteed on re-runs.
  local put
  put=$(curl -sS -w $'\n%{http_code}' -X PUT "$BASE/auth/v1/admin/users/$uid" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$PASSWORD\"}" || true)
  local pcode="${put##*$'\n'}"
  [[ "$pcode" == "200" ]] || { echo "❌ admin password update failed for $email (HTTP $pcode)"; exit 1; }
}

for k in $(seq 1 "$N"); do
  if (( k == 1 )); then email="tester1@tester.com"; else email="tester${k}@tester.com"; fi
  create_or_update_user "$(uid_user "$k")" "$email"
done

# ── 3. Download + upload profile pictures (randomuser.me) ───────────────────
echo "→ 3/6 Uploading $N realistic profile pictures…"
upload_object() { # upload_object <bucket> <path> <file> <content-type>
  local up up_code up_body
  up=$(curl -sS -w $'\n%{http_code}' -X POST "$BASE/storage/v1/object/$1/$2" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "x-upsert: true" -H "Content-Type: $4" \
    --data-binary "@$3" || true)
  up_code="${up##*$'\n'}"; up_body="${up%$'\n'*}"
  if [[ "$up_code" != "200" && "$up_code" != "201" ]]; then
    echo "❌ upload failed for $1/$2 (HTTP $up_code): $up_body"; exit 1
  fi
}

fetch_image() { # fetch_image <url> <file>
  local attempt
  for attempt in 1 2 3; do
    if curl -fsSL --max-time 25 "$1" -o "$2" && [[ -s "$2" ]]; then return 0; fi
    echo "   … retry $attempt downloading $1"; sleep 2
  done
  echo "❌ image download failed: $1"; return 1
}

for k in $(seq 1 "$N"); do
  uid="$(uid_user "$k")"
  if (( k % 2 == 0 )); then gender=men; else gender=women; fi
  idx=$(( (k - 1) % 100 ))
  png="$TMP/avatar-$uid.jpg"
  fetch_image "https://randomuser.me/api/portraits/${gender}/${idx}.jpg" "$png"
  upload_object "avatars" "$uid/avatar.jpg" "$png" "image/jpeg"
done

# ── 4. Apply the graph data ─────────────────────────────────────────────────
echo "→ 4/6 Applying seed-feed-test.sql (n=$N)…"
psql_db -q -v "n=$N" -v "base_url=$BASE" -f supabase/seed/seed-feed-test.sql

# ── 5. Event banners + group covers + event photos (Lorem Picsum) ───────────
echo "→ 5/6 Uploading event banners, group covers and photos…"
for i in $(seq 1 15); do
  eid="$(uid_kind 0002 "$i")"
  img="$TMP/ev-$i.jpg"
  fetch_image "https://picsum.photos/seed/samay-ev-${i}/1200/600" "$img"
  # Event covers live in the public `groups` bucket under `event_covers/`
  # (the app's uploadEventCover contract); the `events` bucket is private.
  upload_object "groups" "event_covers/$eid.jpg" "$img" "image/jpeg"
done
for g in $(seq 1 8); do
  gid="$(uid_kind 0001 "$g")"
  img="$TMP/gr-$g.jpg"
  fetch_image "https://picsum.photos/seed/samay-gr-${g}/1200/600" "$img"
  upload_object "groups" "$gid/cover.jpg" "$img" "image/jpeg"
done
for i in 4 9 14; do
  eid="$(uid_kind 0002 "$i")"
  for j in 1 2 3; do
    img="$TMP/ph-$i-$j.jpg"
    fetch_image "https://picsum.photos/seed/samay-ph-${i}-${j}/800/800" "$img"
    upload_object "events" "$eid/photos/photo-$j.jpg" "$img" "image/jpeg"
  done
done

# ── 6. Summary ──────────────────────────────────────────────────────────────
echo "→ 6/6 Verifying…"
psql_db -At -c "
SELECT 'accounts=' || count(*) FROM public.users WHERE username LIKE 'tester%'
UNION ALL SELECT 'with_avatar=' || count(*) FROM public.users WHERE username LIKE 'tester%' AND avatar_url IS NOT NULL
UNION ALL SELECT 'auth_users=' || count(*) FROM auth.users WHERE email LIKE '%@tester.com'
UNION ALL SELECT 'groups=' || count(*) FROM public.groups WHERE id::text LIKE '00000000-0000-0000-0001-%'
UNION ALL SELECT 'events=' || count(*) FROM public.events WHERE id::text LIKE '00000000-0000-0000-0002-%'
UNION ALL SELECT 'event_banners=' || count(*) FROM public.events WHERE id::text LIKE '00000000-0000-0000-0002-%' AND cover_url IS NOT NULL
UNION ALL SELECT 'sessions=' || count(*) FROM public.minigame_sessions WHERE id::text LIKE '00000000-0000-0000-0003-%'
UNION ALL SELECT 'minigame_invites=' || count(*) FROM public.minigame_invites WHERE session_id::text LIKE '00000000-0000-0000-0003-%'
UNION ALL SELECT 'notifications=' || count(*) FROM public.notifications WHERE id::text LIKE '00000000-0000-0000-0008-%';
" | sed 's/^/      /'

echo ""
echo "  ✅ seeded the @tester universe (N=$N)"
echo "  ─────────────────────────────────────────────────────────"
echo "      email:    tester1@tester.com  (or tester2..tester${N}@tester.com)"
echo "      password: $PASSWORD"
echo "  (point the app at the testing-local stack: bash tools/start-stack.sh testing-local)"
echo "═══════════════════════════════════════════════════════════════"
