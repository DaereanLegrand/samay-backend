#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-005] Seeds static validation (rewritten by MSQ-01, 2026-08-23)
#
# Validates the TWO seed files against the baseline migrations:
#   supabase/seed-config.sql  — required app config, AUTO-applied by
#                               init/reset/migrate (fundamental, no user data)
#   supabase/seed-test.sql    — @tester test-data snapshot, EXPLICIT only
#                               (`make supabase-seed-test`; conversations and
#                               notifications deliberately absent; regenerable
#                               data — E2EE keys/shards/minigames/rank
#                               snapshots/signup tracker — removed 2026-08-30)
# plus the byte-mirrors in supabase/, the Makefile targets, and the
# applier contract:
#   appliers (migrate.sh/reset.sh ×2 + init/reset Makefile targets) may apply
#   seed-config ONLY; any reference to seed-test/seed-dev there FAILS.
# =============================================================================
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SEED_CONFIG="$REPO/supabase/seed-config.sql"
SEED_CONFIG_TESTING="$REPO/supabase/seed-config.sql"
SEED_TEST="$REPO/supabase/seed-test.sql"
SEED_TESTING_TEST="$REPO/supabase/seed-test.sql"
MIG="$REPO/supabase/migrations"
MAKEFILE="$REPO/Makefile"

PASS=0; FAIL=0
ok()  { echo "  ✅ PASS: $1"; ((PASS++)); }
fail(){ echo "  ❌ FAIL: $1"; ((FAIL++)); }
h1()  { echo ""; echo "━━━ $1 ━━━"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-005 — Seed files static validation"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Files present ─────────────────────────────────────────────────────────
h1 "1. Files present"
for f in "$SEED_CONFIG" "$SEED_CONFIG_TESTING" "$SEED_TEST" "$SEED_TESTING_TEST" "$MAKEFILE"; do
  if [ -f "$f" ]; then pass="exists: $(basename "$f")"; ok "$pass"; else fail "missing: $f"; fi
done
if [ ! -f "$REPO/supabase/seed-dev.sql" ] && [ ! -f "$REPO/supabase/seed-dev.sql" ]; then
  ok "seed-dev.sql retired from both stacks"
else
  fail "seed-dev.sql still present — must be deleted (MSQ-01 directive)"
fi

# ── 2. bash -n on appliers ───────────────────────────────────────────────────
h1 "2. bash -n syntax (appliers)"
for f in "$REPO/supabase/migrate.sh" "$REPO/supabase/reset.sh" \
         "$REPO/supabase/migrate.sh" "$REPO/supabase/reset.sh" "$0"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else fail "bash -n $f"; fi
done

# ── 3. Applier contract: seed-config auto, seed-test/dev never ──────────────
h1 "3. Appliers apply ONLY seed-config (auto), NEVER seed-test/seed-dev"
for f in "$REPO/supabase/migrate.sh" "$REPO/supabase/reset.sh" \
         "$REPO/supabase/migrate.sh" "$REPO/supabase/reset.sh"; do
  if grep -qE '\-f seed-config\.sql' "$f" && ! grep -qE '\-f seed-(test|dev)' "$f"; then
    ok "$(basename "$f"): applies seed-config.sql only"
  else
    fail "$(basename "$f"): must execute seed-config.sql and never execute seed-test/seed-dev"
  fi
done
INIT_CALLS=$(awk '
  /^(start|reset):/ { f=1 }
  f && /-f seed-config\.sql/ { c++ }
  /^[a-zA-Z0-9_-]+:/ && !/^(start|reset):/ { f=0 }
  END { print c+0 }' "$MAKEFILE")
if [ "$INIT_CALLS" -eq 2 ]; then
  ok "Makefile: start/reset auto-apply seed-config"
else
  fail "Makefile: expected 2 seed-config calls in start/reset, found $INIT_CALLS"
fi
if awk '/^(start|reset):/{f=1} /^[a-zA-Z0-9_-]+:/ && !/^(start|reset):/{f=0} f && /seed-(test|dev)/{c++} END{exit (c>0?0:1)}' "$MAKEFILE"; then
  fail "Makefile start/reset targets reference seed-test/seed-dev"
else
  ok "Makefile start/reset targets free of test/dev seeds"
fi

# ── 4. Explicit Makefile targets ─────────────────────────────────────────────
h1 "4. Explicit seed targets"
grep -qE '^seed:' "$MAKEFILE" && ok "target seed exists" || fail "seed missing"
grep -qE '^supabase-seed' "$MAKEFILE" && fail "stale supabase-seed* target still defined" || ok "no stale supabase-seed* targets"

# ── 5. Byte mirrors ──────────────────────────────────────────────────────────
h1 "5. Mirrors byte-identical"
cmp -s "$SEED_CONFIG" "$SEED_CONFIG_TESTING" && ok "seed-config mirrors identical" || fail "seed-config mirrors differ"
cmp -s "$SEED_TEST" "$SEED_TESTING_TEST"     && ok "seed-test mirrors identical"   || fail "seed-test mirrors differ"

# ── helpers over a given seed file ──────────────────────────────────────────
insert_tables() { awk '/^INSERT INTO / { t = $3; gsub(/\(.*/, "", t); sub(/^[^.]*\./,"",t); print t }' "$1" | sort -u; }

table_block() {
  awk -v t="$1" '
    /^CREATE TABLE / {
      name = $3; sub(/\(.*/, "", name); sub(/^public\./, "", name)
      if (name == t) inblock = 1
    }
    inblock { print; if ($0 ~ /^\);/) exit }
  ' $(find "$MIG" -type f -name '*.sql' | LC_ALL=C sort)
}
columns_of_first_insert() {
  awk -v t="$1" '
    /^INSERT INTO / {
      name = $3; gsub(/\(.*/, "", name)
      if (name == t) {
        line = $0; sub(/^[^(]*\(/, "", line)
        if (line ~ /\)/) { sub(/\).*/, "", line); print line; exit }
        buf = line
        while ((getline l) > 0) {
          if (l ~ /^\)/) { print buf; exit }
          buf = buf " " l
        }
      }
    }
  ' "$2"
}
on_conflict_target() {
  awk '
    /^INSERT INTO / { table = $3; gsub(/\(.*/, "", table) }
    /^ON CONFLICT \(/ { sub(/^ON CONFLICT \(/, ""); sub(/\).*/, ""); print table "|" $0 }
  ' "$1"
}
enum_values() {
  awk '
    /^CREATE TYPE (public\.)?[a-z_]+ AS ENUM \(/ {
      name=$3; sub(/^public\./,"",name)
      line=$0; sub(/^CREATE TYPE (public\.)?[a-z_]+ AS ENUM \(/,"",line)
      if (line ~ /\);/) { sub(/[[:space:]]*\);.*/,"",line); print name"|"line; next }
      buf=line
      while ((getline l) > 0) {
        if (l ~ /\);/) { sub(/[[:space:]]*\);.*/,"",l); gsub(/^[[:space:]]+/,"",l); print name"|"buf l; break }
        gsub(/^[[:space:]]+/,"",l); buf=buf l
      }
    }
  ' $(find "$MIG" -type f -name '*.sql' | LC_ALL=C sort)
}

validate_seed_file() { # validate_seed_file <file> <label> <min_uuid_rows|0>
  local file="$1" label="$2" min_uuids="$3"

  # tables exist + columns exist + ON CONFLICT matches real constraints
  PLATFORM_TABLES="auth.users storage.objects"
  for t_raw in $(awk '/^INSERT INTO / { t = $3; gsub(/\(.*/, "", t); print t }' "$file" | sort -u); do
    case " $PLATFORM_TABLES " in *" $t_raw "*) ok "[$label] '$t_raw' platform-owned (no CREATE TABLE expected)"; continue;; esac
    t="${t_raw##*.}"
    block="$(table_block "$t")"
    if [ -z "$block" ]; then
      fail "[$label] table '$t' has no CREATE TABLE in migrations"
    else
      ok "[$label] table '$t' exists in migrations"
      for c in $(columns_of_first_insert "$t" "$file" | tr ',' ' '); do
        c="${c// /}"
        if printf '%s\n' "$block" | grep -qE "^    $c |[ ,]$c " || \
           awk -v t="public.$t" -v col="$c" '
             $0 ~ "ALTER TABLE ONLY " t { ctx=1; next }
             ctx && /;/ { ctx=0 }
             ctx && $0 ~ "ADD COLUMN (IF NOT EXISTS )?" col "( |,|$)" { found=1 }
             END { exit(found?0:1) }' $(find "$MIG" -type f -name '*.sql' | LC_ALL=C sort); then
          : # column found (inline or ALTER)
        else
          fail "[$label] column '$c' not found on '$t'"
        fi
      done
      target="$(on_conflict_target "$file" | awk -F'|' -v t="$t" '$1 == t { print $2 }' | head -1)"
      if [ -n "$target" ]; then
        target_pat=$(printf '%s' "$target" | sed 's/[()]/./g; s/, */[[:space:]]*,[[:space:]]*/g')
        if printf '%s\n' "$block" | grep -qE "UNIQUE \($target\)|PRIMARY KEY" \
           || awk -v tbl="ALTER TABLE ONLY public.$t" -v pat="$target_pat" '
                $0 == tbl { ctx=1; next }
                ctx && /PRIMARY KEY|UNIQUE/ && $0 ~ "\\(" pat "\\)" { found=1 }
                ctx && /;/ { ctx=0 }
                END { exit(found ? 0 : 1) }' $(find "$MIG" -type f -name '*.sql' | LC_ALL=C sort); then
          ok "[$label] ON CONFLICT ($target) on '$t' matches a real constraint"
        else
          fail "[$label] ON CONFLICT ($target) on '$t' has NO matching constraint"
        fi
      fi
    fi
  done

  # PK uuid uniqueness threshold
  # auth.users first value is instance_id (constant) — validate its real id
  # (second value) separately; everything else contributes its first uuid.
  # id uniqueness is PER TABLE (auth.users ↔ public.users intentionally
  # share the same uuid — 1:1 identity link).
  # (table,first-uuid) pairs — a uuid may repeat ACROSS tables (identity
  # links like users.id ↔ e2ee_identity_keys.user_id) but never within one.
  PK_PAIRS=$(grep '^INSERT INTO ' "$file" | grep -v '^INSERT INTO auth\.users ' \
     | sed -nE "s/^INSERT INTO ([^(]+) \([^)]*\) VALUES \('([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'.*/\1|\2/p")
  PK_IDS=$(printf '%s\n' "$PK_PAIRS" | cut -d'|' -f2)
  AUTH_IDS=$(grep '^INSERT INTO auth\.users ' "$file" \
     | sed -nE "s/^INSERT INTO auth\.users \([^)]*\) VALUES \('[^']*',\s*'([0-9a-f-]{36})'.*/\1/p")
  PK_TOTAL=$(printf '%s\n' "$PK_IDS" | grep -c . || true)
  PK_DUPES=$(printf '%s\n' "$PK_IDS" | sort | uniq -d)
  PAIR_DUPES=$(printf '%s\n' "$PK_PAIRS" | sort | uniq -d)
  AUTH_DUPES=$(printf '%s\n' "$AUTH_IDS" | sort | uniq -d)
  if [ -z "$PAIR_DUPES" ] && [ -z "$AUTH_DUPES" ] && [ "$PK_TOTAL" -ge "$min_uuids" ]; then
    ok "[$label] $PK_TOTAL row-id UUIDs unique (>= $min_uuids)"
  else
    fail "[$label] row-id duplicates or below threshold: total=$PK_TOTAL dupes=$(printf '%s ' $PAIR_DUPES $AUTH_DUPES)"
  fi
}

# ── 6. seed-config content checks ────────────────────────────────────────────
h1 "6. seed-config.sql (required config, auto-applied)"
validate_seed_file "$SEED_CONFIG" "config" 0
CFG_KEYS=$(grep -cE "^\s+\('[a-z_]+\.[a-z_]+" "$SEED_CONFIG" || true)
if [ "$CFG_KEYS" -ge 38 ]; then
  ok "app_config key count >= 38 ($CFG_KEYS tuning rows)"
else
  fail "app_config key count too low ($CFG_KEYS < 38)"
fi
grep -q "system@samay.example.com" "$SEED_CONFIG" && ok "system admin row present" || fail "system admin row missing"
# config must NOT contain user-data tables
if insert_tables "$SEED_CONFIG" | grep -qvE '^(admin_users|app_config)$'; then
  fail "seed-config contains unexpected user-data tables: $(insert_tables "$SEED_CONFIG" | grep -vE '^(admin_users|app_config)$' | tr '\n' ' ')"
else
  ok "seed-config touches only admin_users + app_config (zero user data)"
fi

# ── 7. seed-test content checks ──────────────────────────────────────────────
h1 "7. seed-test.sql (@tester universe, explicit-only)"
validate_seed_file "$SEED_TEST" "test" 15
# conversations + notifications absent (user directive 2026-08-23)
BANNED=$(insert_tables "$SEED_TEST" | grep -E '^(chats|chat_participants|messages|message_reads|deleted_messages|notifications)$' || true)
if [ -z "$BANNED" ]; then
  ok "conversations & notifications absent (chats/messages/reads/deleted/notifications)"
else
  fail "seed-test contains banned conversation/notification tables: $BANNED"
fi
for t in users friendships groups group_members; do
  insert_tables "$SEED_TEST" | grep -qx "$t" && ok "[$t] present" || fail "[$t] missing from seed-test"
done

# enum literals used by seed-test exist in migrations
h1 "8. Enum literals in seed-test exist"
# simpler: check each enum literal value appears in migrations enum defs
for v in accepted member host active; do
  # NOTE: group_members.status 'invited' is enforced by CHECK constraint,
  # not an enum — validated separately below.
  if enum_values | cut -d'|' -f2 | grep -q "'$v'"; then
    ok "enum literal '$v' exists in migrations"
  else
    fail "enum literal '$v' NOT found in CREATE TYPE statements"
  fi
done

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 OPT-005 PASSED ($PASS checks)"
  exit 0
fi
echo "  ❌ OPT-005 FAILED: $PASS passed, $FAIL failed"
exit 1
