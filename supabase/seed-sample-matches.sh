#!/usr/bin/env bash
# =============================================================================
# Samay — seed-sample-matches.sh
#
# Seeds the LOCAL supabase stack with demo minigame matches so the
# Games-tab deck cards (and the per-game detail lists) show sample data:
#
#   * 20 sample users, each with a downloaded CC0 DiceBear "lorelei" avatar
#     uploaded to the `avatars` storage bucket;
#   * 28 DIRECT minigame sessions — 7 per game x 4 games — with a random-ish
#     (deterministic) player count, near-identical created_at dates, and one
#     designated DEMO HOST who is a participant of every session (log in as
#     that account to see them all).
#
# SAFETY: this script ONLY ever talks to the local testing-local stack
# (127.0.0.1:54396 Kong / 127.0.0.1:54392 Postgres). It refuses to run against
# any other host and reads only `.env/testing-local.env`.
#
# Idempotent: previous sample users/sessions are removed first (matched by the
# @samay.test email domain and the sample user ids), then re-created.
#
# Usage:
#   bash supabase/seed-sample-matches.sh
#
# Override the avatar public base if the app reaches the stack on another
# address (e.g. a device on the LAN):
#   PUBLIC_BASE_URL=http://<host>:54396 bash supabase/seed-sample-matches.sh
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# ── Local only ──────────────────────────────────────────────────────────────
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

psql_db() { PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"; }

PASSWORD='SamayDemo#2026'
EMAIL_DOMAIN='samay.test'

# uuid | username | dicebear seed
ROSTER=(
  "0e378f78-a894-5926-b7cf-e5638945724d|demo_ana|ana"
  "8253a247-80a4-5471-92e5-691b74484006|demo_bruno|bruno"
  "1ae247fd-e100-5f43-b28c-44edaf20b7c6|demo_carla|carla"
  "48a00580-d531-5a44-95be-4a44d57ed052|demo_dani|dani"
  "6a3c29af-e080-5fc3-838c-b954b4fe940d|demo_elena|elena"
  "fa41f6d5-d438-5b35-9bc2-9f195678f3f2|demo_fran|fran"
  "0fb6e6b2-15e0-5115-a043-dd7b4795e000|demo_gabi|gabi"
  "9bdf1f1d-47ac-5c01-9997-70a83331e776|demo_hugo|hugo"
  "41ee5872-8f90-5d37-8a34-22365cf2aa21|demo_iris|iris"
  "e22c5be2-5dff-5040-9438-c22bcb7a26cb|demo_javi|javi"
  "ce339abc-6082-5ef1-b85f-01c66e478de7|demo_kira|kira"
  "0873d11a-1b9c-59b4-abff-e7a5b1cb0bf5|demo_lucas|lucas"
  "42df29d8-7b2b-534b-886c-22dddb94e67d|demo_marta|marta"
  "ea5d07d7-9988-5396-ae35-7ab7b731dcd1|demo_nico|nico"
  "c4f24e26-d59b-5617-96af-a77ffe85fc89|demo_olga|olga"
  "df71d4c3-87d0-5bd0-bdfb-3edc52edd2fd|demo_pablo|pablo"
  "0e893274-03d9-5fbf-92d8-ced486c9a4fb|demo_quique|quique"
  "92624d88-21a0-5259-8c78-a1dadfb2280d|demo_rosa|rosa"
  "b42e6477-f337-5c97-b445-78ab00f5d7f0|demo_sergio|sergio"
  "382932ca-7f66-5932-96d6-33ec17364e58|demo_tania|tania"
)

UUIDS=()
for entry in "${ROSTER[@]}"; do
  IFS='|' read -r uid _ _ <<<"$entry"
  UUIDS+=("$uid")
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Join args as a SQL quoted list: 'a','b','c'
join_quoted() { local out; out=$(printf "'%s'," "$@"); echo "${out%,}"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  Seeding sample minigame matches → $BASE"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Cleanup previous sample rows ─────────────────────────────────────────
echo "→ Removing any previous sample users/sessions…"
IN_UUIDS="$(join_quoted "${UUIDS[@]}")"
psql_db -q <<SQL
SET session_replication_role = replica;
DELETE FROM public.minigame_sessions WHERE participants && ARRAY[$IN_UUIDS]::uuid[];
DELETE FROM public.users WHERE id IN ($IN_UUIDS);
-- session_replication_role=replica disables FK cascades, so auth.identities is
-- NOT removed with auth.users — leaving it would make GoTrue reject the email
-- on re-create ("Database error checking email").
DELETE FROM auth.identities WHERE user_id IN ($IN_UUIDS) OR identity_data->>'email' LIKE '%@$EMAIL_DOMAIN';
DELETE FROM auth.users WHERE id IN ($IN_UUIDS) OR email LIKE '%@$EMAIL_DOMAIN';
SQL

# ── 2. Create auth users + download/upload avatars ──────────────────────────
echo "→ Creating ${#ROSTER[@]} users + uploading CC0 avatars…"
AVATAR_URLS=()
for entry in "${ROSTER[@]}"; do
  IFS='|' read -r uid uname seed <<<"$entry"
  email="demo.$seed@$EMAIL_DOMAIN"

  resp=$(curl -sS -w $'\n%{http_code}' -X POST "$BASE/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$uid\",\"email\":\"$email\",\"password\":\"$PASSWORD\",\"email_confirm\":true}" || true)
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [[ "$code" != "200" && "$code" != "201" ]]; then
    echo "❌ admin create failed for $email (HTTP $code): $body"; exit 1
  fi

  png="$TMP/$uid.png"
  for attempt in 1 2 3; do
    if curl -fsSL "https://api.dicebear.com/10.x/lorelei/png?seed=$seed&size=128" -o "$png" \
        && [[ -s "$png" ]]; then
      break
    fi
    echo "   … DiceBear retry $attempt for $seed"; sleep 2
  done
  [[ -s "$png" ]] || { echo "❌ avatar download failed for $seed"; exit 1; }

  up=$(curl -sS -w $'\n%{http_code}' -X POST "$BASE/storage/v1/object/avatars/$uid/avatar.png" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "x-upsert: true" -H "Content-Type: image/png" \
    --data-binary "@$png" || true)
  up_code="${up##*$'\n'}"; up_body="${up%$'\n'*}"
  if [[ "$up_code" != "200" && "$up_code" != "201" ]]; then
    echo "❌ avatar upload failed for $uname (HTTP $up_code): $up_body"; exit 1
  fi

  AVATAR_URLS+=("$BASE/storage/v1/object/public/avatars/$uid/avatar.png")
done

# ── 3. Build + apply the data SQL ───────────────────────────────────────────
echo "→ Inserting public profiles + 28 sessions…"

user_rows=()
for i in "${!ROSTER[@]}"; do
  IFS='|' read -r uid uname _ <<<"${ROSTER[$i]}"
  user_rows+=("('$uid','$uname','${AVATAR_URLS[$i]}','2000-01-01', now(), now())")
done

GAMES=(truth_dare drunk_bottle two_lies_one_truth charades)
session_rows=()
idx=0
for g in 0 1 2 3; do
  for m in 0 1 2 3 4 5 6; do
    count=$(( 2 + (idx * 3) % 7 ))          # 2..8 players
    parts=("${UUIDS[0]}")                    # demo host is always in
    k=0
    # Stride 11 is coprime with the 20-user roster, so the picks cycle through
    # every user before repeating. The previous stride/offset pair advanced by
    # 4 mod 20 (period 5), so it ran out of distinct players and could never
    # reach 7+ — which is why `+N` (totalPlayers > shown) never appeared.
    while [[ "${#parts[@]}" -lt "$count" && "$k" -lt 40 ]]; do
      cand=$(( (idx * 7 + k * 11 + 1) % ${#UUIDS[@]} ))
      cid="${UUIDS[$cand]}"
      skip=0
      for p in "${parts[@]}"; do [[ "$p" == "$cid" ]] && skip=1; done
      if [[ "$skip" -eq 0 ]]; then parts+=("$cid"); fi
      k=$(( k + 1 ))
    done
    arr="$(join_quoted "${parts[@]}")"
    hours=$(( idx * 7 ))                     # 7h apart — minimally different
    session_rows+=("('${GAMES[$g]}','active',0,$count,ARRAY[$arr]::uuid[], now() - interval '$hours hours', 'prueba $((idx + 1))')")
    idx=$(( idx + 1 ))
  done
done

{
  echo "SET session_replication_role = replica;"
  echo "BEGIN;"
  echo "INSERT INTO public.users (id, username, avatar_url, date_of_birth, created_at, updated_at) VALUES"
  IFS=,; echo "${user_rows[*]}"; unset IFS
  echo "ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username, avatar_url = EXCLUDED.avatar_url, updated_at = now();"
  echo "INSERT INTO public.minigame_sessions"
  echo "  (game_type, status, shard_wager, player_limit, participants, created_at, name) VALUES"
  IFS=,; echo "${session_rows[*]}"; unset IFS
  echo ";"
  echo "COMMIT;"
} > "$TMP/seed.sql"

psql_db -q -f "$TMP/seed.sql"

# ── 4. Summary ──────────────────────────────────────────────────────────────
users=$(psql_db -At -c "SELECT count(*) FROM public.users WHERE id IN ($IN_UUIDS);")
sessions=$(psql_db -At -c "SELECT count(*) FROM public.minigame_sessions WHERE participants && ARRAY[$IN_UUIDS]::uuid[];")
host_email="demo.ana@$EMAIL_DOMAIN"

echo ""
echo "  ✅ seeded $users sample users, $sessions sessions"
echo "  ─────────────────────────────────────────────────────────"
echo "  Log in as the demo host to see every match:"
echo "      email:    $host_email"
echo "      password: $PASSWORD"
echo "  (point the app at the testing-local stack: bash tools/start-stack.sh testing-local)"
echo "═══════════════════════════════════════════════════════════════"
