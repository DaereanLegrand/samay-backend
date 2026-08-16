#!/usr/bin/env bash
# =============================================================================
# Samay — STATIC verification for the dev/demo seed (agent I-75).
#
# The live application of seed-dev.sql needs the stack (blocked until the
# checkpoint with the remapped stack — per I-75 mission), so this test is the
# repeatable static gate instead:
#   1. Files exist (seed-dev.sql ×2, tools/seed_dev_data.sh).
#   2. `bash -n` on every touched shell script.
#   3. UUID literals in seed-dev.sql are unique (idempotency contract).
#   4. Every table referenced by INSERT INTO exists in supabase/migrations/.
#   5. Every column referenced by INSERT exists in that table (CREATE TABLE
#      block OR ALTER TABLE ADD COLUMN).
#   6. Every ON CONFLICT target matches a real PK/UNIQUE constraint in the
#      table's definition.
#   7. Enum/CHECK literals used in seed-dev.sql exist in migrations.
#   8. Makefile `supabase-seed-dev` target mirrors reset.sh's psql pattern
#      (host port 54382, never Juega's 5432/54321) and `make -n` resolves.
#   9. migrate.sh/reset.sh (both stacks) apply seed-dev.sql ONLY behind
#      SEED_DEV=1 (default off), AFTER seed.sql.
#  10. supabase/seed-dev.sql and supabase-testing/seed-dev.sql are identical.
#
# No stack, no docker, no DB required. Exit 0 = all static checks pass.
# Usage: bash test/opt-005-seed-dev-static.sh
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MIG="$REPO/supabase/migrations"
SEED="$REPO/supabase/seed-dev.sql"
SEED_TESTING="$REPO/supabase-testing/seed-dev.sql"
TOOL="$REPO/tools/seed_dev_data.sh"

FAILURES=0
fail() { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  I-75 — seed-dev.sql static verification"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Files exist ───────────────────────────────────────────────────────────
echo ""
echo "━━━ 1. Files present ━━━"
for f in "$SEED" "$SEED_TESTING" "$TOOL"; do
  if [ -f "$f" ]; then pass "$(basename "$f") exists"; else fail "$f missing"; fi
done

# ── 2. bash -n on all touched scripts ────────────────────────────────────────
echo ""
echo "━━━ 2. bash -n syntax ━━━"
for f in \
  "$REPO/supabase/migrate.sh" "$REPO/supabase/reset.sh" \
  "$REPO/supabase-testing/migrate.sh" "$REPO/supabase-testing/reset.sh" \
  "$TOOL" "$0"; do
  if bash -n "$f" 2>/dev/null; then pass "bash -n $f"; else fail "bash -n $f"; fi
done

# ── 3. UUID uniqueness in seed-dev.sql ───────────────────────────────────────
# Only the row-id position (first value of every VALUES tuple: `    ('uuid',`)
# counts as a PK definition; repeated FK references are expected and ignored.
echo ""
echo "━━━ 3. Row-id UUIDs unique (PK idempotency contract) ━━━"
PK_IDS=$(grep -oE "^    \('[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'" "$SEED" | sed "s/^    ('//; s/'$//")
PK_TOTAL=$(printf '%s\n' "$PK_IDS" | grep -c .)
PK_DUPES=$(printf '%s\n' "$PK_IDS" | sort | uniq -d)
# >= 40: the demo chat section (1 chat + 5 participants + 2 messages = 8
# rows) was removed 2026-08-16 — an E2EE app cannot seed decryptable chat
# content, and plaintext demo rows would be deleted by the undecryptable
# cleanup. 40 row-ids remain (users, groups, events, cosmetics, …).
if [ -z "$PK_DUPES" ] && [ "$PK_TOTAL" -ge 40 ]; then
  pass "$PK_TOTAL row-id UUIDs, all unique (>=40 seeded rows)"
else
  fail "row-id UUID duplicates found: $(printf '%s ' $PK_DUPES) (total=$PK_TOTAL)"
fi

# ── 4/5/6. Tables, columns, ON CONFLICT targets vs migrations ────────────────
echo ""
echo "━━━ 4. INSERT INTO tables exist in migrations ━━━"
echo "━━━ 5. INSERT columns exist (CREATE TABLE block or ADD COLUMN) ━━━"
echo "━━━ 6. ON CONFLICT targets match real PK/UNIQUE constraints ━━━"

table_block() {
  # Extracts the CREATE TABLE block for a table (all migration files).
  awk -v t="$1" '
    /^CREATE TABLE / {
      name = $3; sub(/\(.*/, "", name); sub(/^public\./, "", name)
      if (name == t) inblock = 1
    }
    inblock { print; if ($0 ~ /^\);/) exit }
  ' "$MIG"/*.sql
}

insert_columns() {
  # Extracts the column list of the FIRST `INSERT INTO <table> (` statement.
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
  # Prints "table|col1,col2" for every ON CONFLICT (...) clause.
  awk '
    /^INSERT INTO / { table = $3; gsub(/\(.*/, "", table) }
    /^ON CONFLICT \(/ {
      sub(/^ON CONFLICT \(/, ""); sub(/\).*/, ""); print table "|" $0
    }
  ' "$1"
}

# Parse INSERT tables from the seed file (in order, deduped).
INSERT_TABLES=$(awk '/^INSERT INTO / { t = $3; gsub(/\(.*/, "", t); print t }' "$SEED" | sort -u)

for t in $INSERT_TABLES; do
  block="$(table_block "$t")"
  if [ -z "$block" ]; then
    fail "table '$t' has no CREATE TABLE in migrations"
    continue
  fi
  pass "table '$t' exists in migrations"

  cols="$(insert_columns "$t" "$SEED")"
  for c in $(echo "$cols" | tr ',' '\n' | sed 's/^ *//; s/ *$//'); do
    [ -z "$c" ] && continue
    in_block=$(printf '%s\n' "$block" | grep -E "(^|[^a-z_])$c([^a-z_]|$)" || true)
    # ALTER TABLE ADD COLUMN may be on the SAME line as `ALTER TABLE <t>`
    # (e.g. 20260512000011_group_members_status.sql) or on the NEXT line
    # (e.g. 20260809000004_users_discovery.sql).
    if awk -v t="$t" -v c="$c" '
        /^ALTER TABLE (public\.)?/ {
          name = $0; sub(/^ALTER TABLE (public\.)?/, "", name); sub(/ .*/, "", name)
          pending = (name == t)
          rest = $0; sub(/^.*ADD COLUMN /, "", rest)
          sub(/^IF NOT EXISTS /, "", rest); sub(/ .*/, "", rest)
          if (pending && rest == c) found = 1
          next
        }
        pending && $0 ~ "^    ADD COLUMN (IF NOT EXISTS )?" c "( |,|$)" { found = 1 }
        END { if (found) exit 0; exit 1 }
      ' "$MIG"/*.sql; then
      in_alter=1
    else
      in_alter=""
    fi
    if [ -n "$in_block" ] || [ -n "$in_alter" ]; then
      pass "column '$t.$c' exists"
    else
      fail "column '$t.$c' NOT found in migrations"
    fi
  done

  target="$(on_conflict_target "$SEED" | awk -F'|' -v t="$t" '$1 == t { print $2 }' | head -1)"
  if [ -n "$target" ]; then
    # Exact UNIQUE (a, b) for compound targets; PRIMARY KEY for the (id) case.
    if printf '%s\n' "$block" | grep -qE "UNIQUE \($target\)|PRIMARY KEY"; then
      pass "ON CONFLICT ($target) on '$t' matches a real constraint"
    else
      fail "ON CONFLICT ($target) on '$t' has NO matching UNIQUE/PRIMARY KEY in migrations"
    fi
  fi
done

# ── 7. Enum / CHECK literals used by the seed exist in migrations ───────────
echo ""
echo "━━━ 7. Enum + CHECK literals ━━━"

enum_values() {
  # Prints values of `CREATE TYPE <name> AS ENUM (...)` (single-line defs).
  grep -h "^CREATE TYPE " "$MIG"/*.sql |
    sed -n "s/^CREATE TYPE \([a-z_]*\) AS ENUM (\(.*\));/\1|\2/p"
}

enum_has() {
  local type="$1" value="$2"
  enum_values | awk -F'|' -v t="$type" -v v="'$value'" '$1 == t && $2 ~ v { found = 1 } END { exit !found }'
}

# Contract: (enum-or-constraint-kind, table.column, values) — the values a
# seed-dev.sql row is allowed to use, verified against the migrations' types.
ENUM_CONTRACT=(
  "subscription_tier|users.subscription_tier|free pro vip"
  "friendship_status|friendships.status|pending accepted blocked"
  "group_role|group_members.role|member promotor co_promotor"
  "size_tier|group_rank_snapshots.size_tier|micro small medium large"
  "rank_bracket|groups.rank_bracket|b0_20 b20_40 b40_60 b60_80 b80_90 b90_100"
  "rank_bracket|group_rank_snapshots.rank_bracket|b0_20 b20_40 b40_60 b60_80 b80_90 b90_100"
  "event_type|events.type|casual juerga tono"
  "event_status|events.status|draft upcoming live ended cancelled"
  "join_mode|events.join_mode|open approval"
  "event_role|event_promotores.role|promotor co_promotor"
  "invite_status|event_invites.status|pending accepted declined attended"
  "chat_type|chats.type|event group direct"
  "cosmetic_type|cosmetics.type|avatar_frame profile_bg badge group_cover group_badge"
  "preshard_remainder_action|events.preshards_remainder_action|return redistribute"
)
for entry in "${ENUM_CONTRACT[@]}"; do
  type="${entry%%|*}"; rest="${entry#*|}"; column="${rest%%|*}"; values="${rest#*|}"
  for v in $values; do
    if enum_has "$type" "$v"; then
      pass "enum literal '$v' ($type, $column) exists in migrations"
    else
      fail "enum literal '$v' NOT in CREATE TYPE $type ($column)"
    fi
  done
done

# group_members.status is a CHECK constraint (20260512000011), not an enum.
for v in active invited; do
  if grep -q "status IN ('active', 'invited')" "$MIG/20260512000011_group_members_status.sql"; then
    pass "group_members.status literal '$v' allowed by CHECK constraint"
  else
    fail "group_members.status CHECK constraint not found in migrations"
  fi
done

# ── 8. Makefile target matches reset.sh psql pattern + resolves ─────────────
echo ""
echo "━━━ 8. Makefile supabase-seed-dev ━━━"
TARGET_BLOCK=$(awk '/^supabase-seed-dev:/{p=1} p{print} p && /^$/{exit}' "$REPO/Makefile")
if printf '%s' "$TARGET_BLOCK" | grep -q -- "-p 54382" \
   && printf '%s' "$TARGET_BLOCK" | grep -q -- "-f seed-dev.sql" \
   && printf '%s' "$TARGET_BLOCK" | grep -q "PGPASSWORD=postgres psql -h localhost"; then
  pass "target uses reset.sh psql pattern (host psql, -p 54382, seed-dev.sql)"
else
  fail "target does not match reset.sh psql pattern (-p 54382 / PGPASSWORD=postgres psql -h localhost / -f seed-dev.sql)"
fi
if grep -q "supabase-seed-dev" "$REPO/Makefile"; then
  if awk '/^\.PHONY:/{p=1} p && /supabase-seed-dev/{found=1} END{exit !found}' "$REPO/Makefile"; then
    pass "supabase-seed-dev listed in .PHONY"
  else
    fail "supabase-seed-dev missing from .PHONY"
  fi
fi
MAKE_OUT="$(cd "$REPO" && make -n supabase-seed-dev 2>&1)"
if [ $? -eq 0 ] && printf '%s' "$MAKE_OUT" | grep -q -- "-p 54382"; then
  pass "make -n supabase-seed-dev resolves (dry-run OK, port 54382)"
else
  fail "make -n supabase-seed-dev failed: $MAKE_OUT"
fi

# ── 9. SEED_DEV toggle (default off) in migrate.sh/reset.sh ×2 ──────────────
echo ""
echo "━━━ 9. SEED_DEV toggle ━━━"
for f in "$REPO/supabase/migrate.sh" "$REPO/supabase/reset.sh" \
         "$REPO/supabase-testing/migrate.sh" "$REPO/supabase-testing/reset.sh"; do
  if grep -q 'SEED_DEV="${SEED_DEV:-0}"' "$f" \
     && grep -q -- '-f seed-dev.sql' "$f" \
     && grep -q -- '-f seed.sql' "$f"; then
    seed_line=$(grep -n -- '-f seed.sql' "$f" | head -1 | cut -d: -f1)
    dev_line=$(grep -n -- '-f seed-dev.sql' "$f" | head -1 | cut -d: -f1)
    if [ -n "$seed_line" ] && [ -n "$dev_line" ] && [ "$seed_line" -lt "$dev_line" ]; then
      pass "$(basename "$f"): SEED_DEV default-off, seed-dev.sql after seed.sql"
    else
      fail "$f: seed-dev.sql not applied after seed.sql"
    fi
  else
    fail "$f: missing SEED_DEV default or seed-dev.sql application"
  fi
done
# SEED_DEV guard must be inside `[ "$SEED_DEV" = "1" ]` (never unconditional).
for f in "$REPO/supabase/migrate.sh" "$REPO/supabase/reset.sh"; do
  if grep -q '\[ "$SEED_DEV" = "1" \]' "$f"; then
    pass "$(basename "$f"): seed-dev.sql guarded by SEED_DEV=1"
  else
    fail "$f: seed-dev.sql application not guarded by [ \"\$SEED_DEV\" = \"1\" ]"
  fi
done

# ── 10. Mirrors identical ────────────────────────────────────────────────────
echo ""
echo "━━━ 10. supabase-testing/ mirror ━━━"
if diff -q "$SEED" "$SEED_TESTING" >/dev/null; then
  pass "seed-dev.sql mirrors are byte-identical"
else
  fail "seed-dev.sql mirrors differ (diff supabase/seed-dev.sql supabase-testing/seed-dev.sql)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$FAILURES" -eq 0 ]; then
  echo "  ✅ All static seed-dev checks passed."
  exit 0
else
  echo "  ❌ $FAILURES static check(s) FAILED."
  exit 1
fi
echo "═══════════════════════════════════════════════════════════════"
