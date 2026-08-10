#!/usr/bin/env bash
# =============================================================================
# Samay — STATIC gate for the base docker-compose overhaul
# (agents M-01, M-09, M-06).
#
# Stack-free verification of the compose target state (SELFHOSTING.md §2,
# DKR-04/DKR-09/DKR-06/DKR-02/DKR-08) — no containers are started, no Docker
# daemon is required (the `docker compose config` parse checks SKIP with a note
# when docker is unavailable; every other assertion is pure text on the compose
# files):
#   1. No obsolete `version:` key in any of the 7 compose files.
#   2. Every service image is pinned to the exact SELFHOSTING.md §2.2 tag
#      (verified against supabase/supabase master 2026-08-10); no `:latest`.
#   3. Every base service has a `healthcheck:` block, `restart: unless-stopped`
#      and the approved `depends_on` chain (db service_healthy; storage also
#      rest service_started; studio also meta service_started; testing auth
#      also mailpit service_started).
#   4. Env compatibility for the pinned tags (realtime v2.102.3 contract,
#      storage-api v1.60.4 DATABASE_URL, postgres-meta v0.96.6 PG_META_DB_*,
#      postgrest v14.12 admin server, gotrue v2.189.0 GOTRUE_JWT_EXP).
#   5. Approved host port map present (54382/54386/54381/54384/54443) and NO
#      Juega host mappings (5432/54321/54323/8443) nor any non-approved host
#      port binding.
#   6. If docker is available: `docker compose config --quiet` passes on the
#      base + every override combo in BOTH stacks.
#   7. Kong (DKR-06, M-09): entrypoint wrappers exec the image's real
#      /entrypoint.sh (no self-exec over /docker-entrypoint.sh, no
#      never-passing `until kong health` loop, bounded DB wait), kong.yml
#      upstream URLs reference only compose service hostnames, kong service
#      mounts the wrapper at /home/kong/kong-entrypoint.sh.
#   9. Stack parity (M-10): supabase/ vs supabase-testing/ are byte-for-byte
#      behaviorally identical — migration count + per-file byte identity,
#      seed.sql/seed-dev.sql byte identity, config.toml identity after
#      testing-token normalization, script normalized diffs (container
#      prefixes `samay-testing-` + prose stack name `Samay Testing` are the
#      ONLY permitted script differences; any other line = semantic drift),
#      script approved-port defaults pinned, and a whole-tree `diff -rq`
#      allowlist (any file pair outside the documented intentional set fails).
#  10. Override semantics (M-06, DKR-02/DKR-08): the pg17 override pins a
#      17.x image (not :latest, not 18+) byte-identically in both stacks; the
#      s3 override REALLY configures the S3 backend (minio service with
#      pinned RELEASE tag + `mc ready local` healthcheck, minio-createbucket
#      one-shot, storage env contract GLOBAL_S3_ENDPOINT/GLOBAL_S3_PROTOCOL/
#      GLOBAL_S3_FORCE_PATH_STYLE/AWS_* that storage-api v1.60.4 actually
#      reads — no dead AWS_ENDPOINT/AWS_DEFAULT_REGION vars, minio-data
#      volume), s3 overrides identical across stacks after testing-token
#      normalization, and the mailpit override (testing-only) pins its image
#      and wires auth SMTP to mailpit:1025; when docker is available the
#      merged `docker compose config` output is asserted to contain each
#      override's key vars.
#
# No stack, no DB required. Exit 0 = all static checks pass.
# Usage: bash test/opt-007-compose-static.sh
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE=("$REPO/supabase/docker-compose.yml" "$REPO/supabase-testing/docker-compose.yml")
PG17=("$REPO/supabase/docker-compose.pg17.yml" "$REPO/supabase-testing/docker-compose.pg17.yml")
S3=("$REPO/supabase/docker-compose.s3.yml" "$REPO/supabase-testing/docker-compose.s3.yml")
MAILPIT="$REPO/supabase-testing/docker-compose.mailpit.yml"
ALL_FILES=("${BASE[@]}" "${PG17[@]}" "${S3[@]}" "$MAILPIT")

FAILURES=0
fail() { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  M-01/M-09/M-06 — docker-compose static verification (DKR-04/DKR-09/DKR-06/DKR-02/DKR-08)"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. bash -n on this script ────────────────────────────────────────────────
echo ""
echo "━━━ 1. bash -n ━━━"
if bash -n "$0" 2>/dev/null; then pass "bash -n $0"; else fail "bash -n $0"; fi

# ── 2. No obsolete `version:` key ─────────────────────────────────────────────
echo ""
echo "━━━ 2. No obsolete version: key ━━━"
for f in "${ALL_FILES[@]}"; do
  if grep -qE "^version:" "$f"; then
    fail "$(basename "$f") still has version:"
  else
    pass "$(basename "$f") has no version: key"
  fi
done

# ── 3. Image pinning (SELFHOSTING.md §2.2 official tags) + no :latest ────────
echo ""
echo "━━━ 3. Pinned image tags + no :latest ━━━"
# service -> pinned tag contract (verified against supabase/supabase master
# docker/docker-compose.yml, 2026-08-10 — matches SELFHOSTING.md §2.2).
# Flat "svc=image" list (macOS bash 3.2 — no associative arrays).
PIN_LIST="db=supabase/postgres:17.6.1.136 kong=kong/kong:3.9.3 auth=supabase/gotrue:v2.189.0 rest=postgrest/postgrest:v14.12 realtime=supabase/realtime:v2.102.3 storage=supabase/storage-api:v1.60.4 meta=supabase/postgres-meta:v0.96.6 studio=supabase/studio:2026.08.03-sha-022b374 mailpit=axllent/mailpit:v1.30.7"
pinned_for() { # pinned_for <service> — prints the pinned tag, or nothing
  printf '%s\n' "$PIN_LIST" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2-
}
SERVICE_RE='^  [a-z][a-z0-9]*:'
IMAGE_RE='^    image: (.+)$'
for f in "${BASE[@]}"; do
  svc=""
  while IFS= read -r line; do
    if [[ "$line" =~ $SERVICE_RE ]]; then
      svc="${line%%:*}"; svc="${svc//[[:space:]]/}"
    elif [[ "$line" =~ $IMAGE_RE ]]; then
      img="${BASH_REMATCH[1]}"
      expected="$(pinned_for "$svc")"
      if [ -n "$expected" ] && [ "$expected" = "$img" ]; then
        pass "$(basename "$f") [$svc] image $img"
      else
        fail "$(basename "$f") [$svc] image '$img' != pinned '${expected:-UNKNOWN}'"
      fi
    fi
  done < "$f"
done
if [ "$(grep -oE 'image: [^ ]*:latest' "$MAILPIT" | wc -l | tr -d ' ')" = "0" ]; then
  pass "mailpit override pinned (no :latest)"
else
  fail "mailpit override still uses :latest"
fi
LATEST_HITS=$(grep -rnE 'image: [^ ]*:latest' "${ALL_FILES[@]}" | wc -l | tr -d ' ')
if [ "$LATEST_HITS" = "0" ]; then
  pass "no :latest image reference in any compose file"
else
  fail "found :latest image reference(s): $(grep -rnE 'image: [^ ]*:latest' "${ALL_FILES[@]}" | tr '\n' ';')"
fi

# ── 4. Healthchecks + restart + depends_on chains (base services) ─────────────
echo ""
echo "━━━ 4. healthcheck / restart / depends_on per service ━━━"
block_of() { # block_of <file> <service> — prints the service block
  # Service keys may contain hyphens (minio-createbucket) and the volume
  # declarations (db-config, minio-data) must not be mistaken for services —
  # but for any queried service the exit fires at the NEXT service line, so
  # volume names never leak into a block.
  awk -v s="$2" '
    $0 ~ "^  [a-z][a-z0-9-]*:" { if (block == s) exit; block = substr($0, 3, index($0, ":") - 3) }
    block == s { print }
  ' "$1"
}
for f in "${BASE[@]}"; do
  for svc in db kong auth rest realtime storage meta studio; do
    b="$(block_of "$f" "$svc")"
    [ -z "$b" ] && { fail "$(basename "$f") [$svc] service block missing"; continue; }
    printf '%s' "$b" | grep -q "healthcheck:" && pass "$(basename "$f") [$svc] healthcheck" || fail "$(basename "$f") [$svc] MISSING healthcheck"
    printf '%s' "$b" | grep -q "restart: unless-stopped" && pass "$(basename "$f") [$svc] restart: unless-stopped" || fail "$(basename "$f") [$svc] missing restart: unless-stopped"
  done
  for svc in kong auth rest realtime storage meta studio; do
    b="$(block_of "$f" "$svc")"
    printf '%s' "$b" | grep -q "condition: service_healthy" || fail "$(basename "$f") [$svc] missing depends_on db: service_healthy"
  done
  b="$(block_of "$f" storage)"
  printf '%s' "$b" | grep -q "condition: service_started" && pass "$(basename "$f") [storage] depends_on rest: service_started" || fail "$(basename "$f") [storage] missing rest service_started"
  b="$(block_of "$f" studio)"
  printf '%s' "$b" | grep -q "condition: service_started" && pass "$(basename "$f") [studio] depends_on meta: service_started" || fail "$(basename "$f") [studio] missing meta service_started"
done
# testing-only: auth depends on mailpit (service_started)
b="$(block_of "$MAILPIT" auth)"
printf '%s' "$b" | grep -q "condition: service_started" && pass "mailpit override [auth] depends_on mailpit: service_started" || fail "mailpit override [auth] missing mailpit service_started"

# ── 5. Env compatibility for the pinned tags ──────────────────────────────────
echo ""
echo "━━━ 5. Env contract for pinned image tags ━━━"
for f in "${BASE[@]}"; do
  r="$(block_of "$f" realtime)"
  for k in "API_JWT_SECRET" "SECRET_KEY_BASE" "METRICS_JWT_SECRET" "APP_NAME: realtime" "SEED_SELF_HOST"; do
    printf '%s' "$r" | grep -q "$k" && pass "$(basename "$f") [realtime] env $k (v2.102.3 contract)" || fail "$(basename "$f") [realtime] MISSING env $k"
  done
  s="$(block_of "$f" storage)"
  printf '%s' "$s" | grep -q "DATABASE_URL:" && pass "$(basename "$f") [storage] env DATABASE_URL (v1.60.4)" || fail "$(basename "$f") [storage] MISSING DATABASE_URL"
  printf '%s' "$s" | grep -q "PG_DATABASE_URL" && fail "$(basename "$f") [storage] obsolete PG_DATABASE_URL still present" || pass "$(basename "$f") [storage] no obsolete PG_DATABASE_URL"
  m="$(block_of "$f" meta)"
  printf '%s' "$m" | grep -q "PG_META_DB_HOST:" && pass "$(basename "$f") [meta] env PG_META_DB_HOST (v0.96.6)" || fail "$(basename "$f") [meta] MISSING PG_META_DB_HOST"
  printf '%s' "$m" | grep -q "PG_META_PG_" && fail "$(basename "$f") [meta] obsolete PG_META_PG_* still present" || pass "$(basename "$f") [meta] no obsolete PG_META_PG_*"
  st="$(block_of "$f" rest)"
  printf '%s' "$st" | grep -q "PGRST_ADMIN_SERVER_PORT: 3001" && pass "$(basename "$f") [rest] env PGRST_ADMIN_SERVER_PORT (postgrest --ready)" || fail "$(basename "$f") [rest] MISSING PGRST_ADMIN_SERVER_PORT"
  a="$(block_of "$f" auth)"
  printf '%s' "$a" | grep -q "GOTRUE_JWT_EXP:" && pass "$(basename "$f") [auth] env GOTRUE_JWT_EXP (v2.189.0)" || fail "$(basename "$f") [auth] MISSING GOTRUE_JWT_EXP"
  printf '%s' "$a" | grep -q "GOTRUE_JWT_DEFAULT_EXP" && fail "$(basename "$f") [auth] obsolete GOTRUE_JWT_DEFAULT_EXP still present" || pass "$(basename "$f") [auth] no obsolete GOTRUE_JWT_DEFAULT_EXP"
done

# ── 6. Approved port map; no Juega / non-approved host bindings ──────────────
echo ""
echo "━━━ 6. Port map (host bindings) ━━━"
APPROVED_HOST_PORTS="54381 54382 54384 54386 54388 54443"
for f in "${ALL_FILES[@]}"; do
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"([0-9]+):([0-9]+)\" ]]; then
      host="${BASH_REMATCH[1]}"; container="${BASH_REMATCH[2]}"
      if [[ " $APPROVED_HOST_PORTS " != *" $host "* ]]; then
        fail "$(basename "$f") host binding $host:$container NOT in approved set ($APPROVED_HOST_PORTS)"
      else
        pass "$(basename "$f") host binding $host -> $container approved"
      fi
    fi
  done < "$f"
done
# Required host bindings present in the right files
for req in \
  "$REPO/supabase/docker-compose.yml|54382:5432" \
  "$REPO/supabase/docker-compose.yml|54386:8000" \
  "$REPO/supabase/docker-compose.yml|54443:8443" \
  "$REPO/supabase/docker-compose.yml|54381:3000" \
  "$REPO/supabase-testing/docker-compose.yml|54382:5432" \
  "$REPO/supabase-testing/docker-compose.yml|54386:8000" \
  "$REPO/supabase-testing/docker-compose.yml|54443:8443" \
  "$REPO/supabase-testing/docker-compose.yml|54381:3000" \
  "$REPO/supabase-testing/docker-compose.mailpit.yml|54384:8025"; do
  file="${req%%|*}"; port="${req#*|}"
  if grep -q "\"$port\"" "$file"; then
    pass "$(basename "$file") has $port"
  else
    fail "$(basename "$file") MISSING $port"
  fi
done

# ── 7. docker compose config --quiet on base + every combo (both stacks) ─────
echo ""
echo "━━━ 7. docker compose config --quiet (parse gate) ━━━"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  run_cfg() { # run_cfg <dir> [compose -f flags...] — -f must precede `config`
    local dir="$1"; shift
    (cd "$dir" && docker compose "$@" config --quiet 2>/dev/null)
  }
  run_cfg "$REPO/supabase" && pass "supabase default (.env COMPOSE_FILE)" || fail "supabase default parse FAILED"
  run_cfg "$REPO/supabase" -f docker-compose.yml -f docker-compose.pg17.yml && pass "supabase base+pg17" || fail "supabase base+pg17 parse FAILED"
  run_cfg "$REPO/supabase" -f docker-compose.yml -f docker-compose.s3.yml && pass "supabase base+s3" || fail "supabase base+s3 parse FAILED"
  run_cfg "$REPO/supabase" -f docker-compose.yml -f docker-compose.pg17.yml -f docker-compose.s3.yml && pass "supabase base+pg17+s3" || fail "supabase base+pg17+s3 parse FAILED"
  run_cfg "$REPO/supabase-testing" && pass "testing default (.env COMPOSE_FILE)" || fail "testing default parse FAILED"
  run_cfg "$REPO/supabase-testing" -f docker-compose.yml -f docker-compose.pg17.yml && pass "testing base+pg17" || fail "testing base+pg17 parse FAILED"
  run_cfg "$REPO/supabase-testing" -f docker-compose.yml -f docker-compose.s3.yml && pass "testing base+s3" || fail "testing base+s3 parse FAILED"
  run_cfg "$REPO/supabase-testing" -f docker-compose.yml -f docker-compose.mailpit.yml && pass "testing base+mailpit" || fail "testing base+mailpit parse FAILED"
  run_cfg "$REPO/supabase-testing" -f docker-compose.yml -f docker-compose.pg17.yml -f docker-compose.s3.yml -f docker-compose.mailpit.yml && pass "testing base+pg17+s3+mailpit" || fail "testing base+pg17+s3+mailpit parse FAILED"
else
  echo "  (docker not available — parse gate skipped)"
fi

# ── 8. Kong: entrypoint wrapper + kong.yml + compose wiring (DKR-06, M-09) ────
echo ""
echo "━━━ 8. Kong entrypoint / kong.yml / compose wiring (DKR-06) ━━━"
# 8.1 Entrypoint wrappers: bash -n, pipefail, REAL image entrypoint exec
#     (`/entrypoint.sh` — verified in the published kong/kong:3.9.3 image
#     config), no self-exec over `/docker-entrypoint.sh`, no never-passing
#     `until kong health` loop, bounded DB wait loop.
KONG_EP=("$REPO/supabase/volumes/api/kong-entrypoint.sh" "$REPO/supabase-testing/volumes/api/kong-entrypoint.sh")
for f in "${KONG_EP[@]}"; do
  n="$(basename "$f")"
  if bash -n "$f" 2>/dev/null; then pass "$n bash -n"; else fail "$n bash -n FAILED"; fi
  if grep -Fq 'set -Eeuo pipefail' "$f"; then pass "$n set -Eeuo pipefail"; else fail "$n MISSING set -Eeuo pipefail"; fi
  if grep -Fq 'exec /entrypoint.sh kong docker-start' "$f"; then pass "$n execs real image entrypoint (/entrypoint.sh kong docker-start)"; else fail "$n MISSING exec /entrypoint.sh kong docker-start"; fi
  if grep -Fq 'exec /docker-entrypoint.sh' "$f"; then fail "$n SELF-EXEC /docker-entrypoint.sh (recursion bug)"; else pass "$n no self-exec over /docker-entrypoint.sh"; fi
  if grep -Fq 'until kong health' "$f"; then fail "$n still has never-passing 'until kong health' loop"; else pass "$n no 'until kong health' loop"; fi
  if grep -Fq 'DB_WAIT_ATTEMPTS' "$f" && grep -Fq 'DB_WAIT_INTERVAL' "$f"; then pass "$n bounded DB wait loop (DB_WAIT_ATTEMPTS/DB_WAIT_INTERVAL)"; else fail "$n MISSING bounded DB wait loop"; fi
done
if cmp -s "${KONG_EP[0]}" "${KONG_EP[1]}"; then
  pass "both kong-entrypoint.sh byte-identical"
else
  fail "kong-entrypoint.sh files DIVERGE between stacks"
fi

# 8.2 kong.yml: upstream URLs only ever point at compose service hostnames
#     (samay-* / samay-testing-* + the pinned internal ports), all expected
#     routes present, key-auth keys stay placeholders (MKE/S-10 handoff).
check_kongyml() { # check_kongyml <file> <service-prefix>
  local f="$1" pre="$2" n urls_other
  n="$(basename "$f")"
  local expected=(
    "url: http://${pre}-auth:9999"
    "url: http://${pre}-rest:3000"
    "url: http://${pre}-realtime:4000/socket"
    "url: http://${pre}-storage:5000"
    "url: http://${pre}-meta:8080"
  )
  local u
  for u in "${expected[@]}"; do
    if grep -Fq "$u" "$f"; then pass "$n has $u"; else fail "$n MISSING $u"; fi
  done
  urls_other="$(grep -E '^[[:space:]]*url:' "$f" | grep -vE "url: http://${pre}-(auth|rest|realtime|storage|meta):(9999|3000|4000|5000|8080)(/socket)?$" | wc -l | tr -d ' ')"
  if [ "$urls_other" = "0" ]; then
    pass "$n no foreign/absolute upstream url refs"
  else
    fail "$n has non-compose url refs ($(grep -E '^[[:space:]]*url:' "$f" | grep -vE "url: http://${pre}-(auth|rest|realtime|storage|meta):(9999|3000|4000|5000|8080)(/socket)?$" | tr '\n' ';'))"
  fi
  local svc
  for svc in auth-v1 rest-v1 rest-admin realtime-v1 storage-v1 storage-admin meta-v1; do
    if grep -Fq "name: $svc" "$f"; then pass "$n route service $svc"; else fail "$n MISSING route service $svc"; fi
  done
  if grep -Fq 'key: your-anon-key' "$f" && grep -Fq 'key: your-service-role-key' "$f"; then
    pass "$n key-auth placeholders kept (MKE/S-10 handoff pinned)"
  else
    fail "$n key-auth placeholder keys changed — re-read the MKE/S-10 handoff"
  fi
  if grep -Eq 'sb_publishable|sb_secret|your-jwt-secret' "$f"; then
    fail "$n contains real/secret key material — DO NOT COMMIT"
  else
    pass "$n no real key material"
  fi
}
check_kongyml "$REPO/supabase/volumes/api/kong.yml" samay
check_kongyml "$REPO/supabase-testing/volumes/api/kong.yml" samay-testing

# 8.3 Compose kong service: wrapper mounted OUT of the image's entrypoint path,
#     /bin/bash + wrapper as entrypoint, no `command:` override, and the old
#     over-/docker-entrypoint.sh mount is gone.
for f in "${BASE[@]}"; do
  b="$(block_of "$f" kong)"
  n="$(basename "$f")"
  if printf '%s' "$b" | grep -Fq 'kong-entrypoint.sh:/home/kong/kong-entrypoint.sh'; then
    pass "$n [kong] wrapper mounted at /home/kong/kong-entrypoint.sh"
  else
    fail "$n [kong] wrapper NOT mounted at /home/kong/kong-entrypoint.sh"
  fi
  if printf '%s' "$b" | grep -Fq ':/docker-entrypoint.sh'; then
    fail "$n [kong] still mounts over /docker-entrypoint.sh"
  else
    pass "$n [kong] image /entrypoint.sh left intact (no /docker-entrypoint.sh mount)"
  fi
  if printf '%s' "$b" | grep -Fq 'entrypoint: ["/bin/bash", "/home/kong/kong-entrypoint.sh"]'; then
    pass "$n [kong] entrypoint /bin/bash + wrapper"
  else
    fail "$n [kong] entrypoint not /bin/bash + wrapper"
  fi
  if printf '%s' "$b" | grep -Fq 'command: /docker-entrypoint.sh'; then
    fail "$n [kong] obsolete command: /docker-entrypoint.sh still present"
  else
    pass "$n [kong] no command: /docker-entrypoint.sh"
  fi
done

# ── 9. Stack parity: supabase/ vs supabase-testing/ (M-10) ────────────────────
# Byte-for-byte behavioral parity between the two stacks. The ONLY permitted
# differences are testing identity tokens (container prefixes `samay-testing-`,
# the prose stack name `Samay Testing`, per-stack domains/buckets/SMTP values,
# and the mailpit-only override) — SELFHOSTING.md §6 rows 6-14 document the
# table. Everything else must be byte-identical or the gate fails.
echo ""
echo "━━━ 9. supabase/ vs supabase-testing/ parity (M-10) ━━━"

# 9.1 Migration count equality + per-file byte identity
MIG_A=$(ls "$REPO/supabase/migrations"/*.sql 2>/dev/null | wc -l | tr -d ' ')
MIG_B=$(ls "$REPO/supabase-testing/migrations"/*.sql 2>/dev/null | wc -l | tr -d ' ')
if [ "$MIG_A" = "$MIG_B" ]; then
  pass "migration count equal ($MIG_A)"
else
  fail "migration count differs: supabase=$MIG_A vs supabase-testing=$MIG_B"
fi
if diff -rq "$REPO/supabase/migrations" "$REPO/supabase-testing/migrations" >/dev/null 2>&1; then
  pass "migrations dirs byte-identical"
else
  fail "migrations dirs DIFFER: $(diff -rq "$REPO/supabase/migrations" "$REPO/supabase-testing/migrations" | tr '\n' ';')"
fi

# 9.2 Seed files byte-identical
for s in seed.sql seed-dev.sql; do
  if cmp -s "$REPO/supabase/$s" "$REPO/supabase-testing/$s"; then
    pass "$s byte-identical"
  else
    fail "$s DIFFERS between stacks"
  fi
done

# 9.3 config.toml identity after testing-token normalization
if cmp -s "$REPO/supabase/config.toml" "$REPO/supabase-testing/config.toml"; then
  pass "config.toml byte-identical"
else
  if diff <(sed 's/samay-testing/samay/g' "$REPO/supabase/config.toml") \
          <(sed 's/samay-testing/samay/g' "$REPO/supabase-testing/config.toml") >/dev/null 2>&1; then
    pass "config.toml identical after testing-token normalization"
  else
    fail "config.toml SEMANTIC DRIFT: $(diff "$REPO/supabase/config.toml" "$REPO/supabase-testing/config.toml" | head -6 | tr '\n' ';')"
  fi
fi

# 9.4 Script normalized diffs — migrate.sh/reset.sh/run.sh may differ ONLY by
#     testing identity tokens (`samay-testing-` prefixes + `Samay Testing`
#     prose name). Any other remaining line = semantic drift = FAIL.
for s in migrate.sh reset.sh run.sh; do
  if diff <(sed -E 's/samay-testing-/samay-/g; s/Samay Testing/Samay/g' "$REPO/supabase/$s") \
          <(sed -E 's/samay-testing-/samay-/g; s/Samay Testing/Samay/g' "$REPO/supabase-testing/$s") >/dev/null 2>&1; then
    pass "$s identical after testing-token normalization"
  else
    fail "$s SEMANTIC DRIFT: $(diff <(sed -E 's/samay-testing-/samay-/g; s/Samay Testing/Samay/g' "$REPO/supabase/$s") <(sed -E 's/samay-testing-/samay-/g; s/Samay Testing/Samay/g' "$REPO/supabase-testing/$s") | head -6 | tr '\n' ';')"
  fi
done

# 9.5 Approved DB port pinned in the scripts (rows 9/10/11 regression guard)
for s in migrate.sh reset.sh run.sh; do
  if grep -q '54382' "$REPO/supabase/$s" && grep -q '54382' "$REPO/supabase-testing/$s"; then
    pass "$s references approved DB port 54382 in both stacks"
  else
    fail "$s MISSING 54382 in one or both stacks"
  fi
done

# 9.6 Whole-tree diff allowlist: `diff -rq` may list ONLY the documented
#     intentional differences (per-stack .env keys, domains/buckets/SMTP in
#     compose + volumes configs, identity tokens in scripts, mailpit-only
#     override). Any other line = an undocumented parity gap = FAIL.
PARITY_ALLOW=$(cat <<'EOF'
Files supabase/.env and supabase-testing/.env differ
Files supabase/.env.local and supabase-testing/.env.local differ
Only in supabase-testing: docker-compose.mailpit.yml
Files supabase/docker-compose.s3.yml and supabase-testing/docker-compose.s3.yml differ
Files supabase/docker-compose.yml and supabase-testing/docker-compose.yml differ
Files supabase/migrate.sh and supabase-testing/migrate.sh differ
Files supabase/reset.sh and supabase-testing/reset.sh differ
Files supabase/run.sh and supabase-testing/run.sh differ
Files supabase/volumes/api/kong.yml and supabase-testing/volumes/api/kong.yml differ
Files supabase/volumes/proxy/caddy/Caddyfile and supabase-testing/volumes/proxy/caddy/Caddyfile differ
Files supabase/volumes/proxy/nginx/supabase-nginx.conf.tpl and supabase-testing/volumes/proxy/nginx/supabase-nginx.conf.tpl differ
EOF
)
PARITY_DIFF="$(cd "$REPO" && diff -rq supabase supabase-testing 2>/dev/null || true)"
PARITY_TOTAL="$(printf '%s\n' "$PARITY_DIFF" | grep -v '^$' | wc -l | tr -d ' ')"
PARITY_EXTRA="$(printf '%s\n' "$PARITY_DIFF" | grep -vxFf <(printf '%s\n' "$PARITY_ALLOW") | grep -v '^$')"
if [ -z "$PARITY_EXTRA" ]; then
  pass "diff -rq clean modulo documented intentional diffs ($PARITY_TOTAL line(s))"
else
  fail "UNDOCUMENTED parity gaps: $(printf '%s\n' "$PARITY_EXTRA" | tr '\n' ';')"
fi

# ── 10. Override semantics (M-06, DKR-02/DKR-08): pg17 / s3 / mailpit ────────
# The override layer must ACTUALLY configure its feature: pg17 pins a 17.x
# db image, s3 configures the storage backend + MinIO services with the env
# contract storage-api v1.60.4 reads, mailpit (testing-only) wires auth SMTP
# to the dev sink. Verified against the official supabase/supabase docker/
# overrides + storage-api v1.60.4 src/config.ts + src/storage/backend/s3/
# adapter.ts (2026-08-10).
echo ""
echo "━━━ 10. Override semantics: pg17 / s3 / mailpit (M-06) ━━━"

# 10.1 pg17: byte-identical across stacks, image pinned to 17.x (never
#     :latest, never 18+), self-documenting header present.
if cmp -s "${PG17[0]}" "${PG17[1]}"; then
  pass "pg17 overrides byte-identical across stacks"
else
  fail "pg17 overrides DIVERGE between stacks"
fi
PG17_IMG="$(grep -E '^[[:space:]]{4}image: ' "${PG17[0]}" | head -1 | sed 's/.*image: //')"
if [ -n "$PG17_IMG" ] && [[ "$PG17_IMG" =~ ^supabase/postgres:17\.[0-9]+(\.[0-9]+)*$ ]]; then
  pass "pg17 override pins $PG17_IMG (17.x, not :latest/18+)"
else
  fail "pg17 override image '$PG17_IMG' is not a pinned 17.x tag"
fi
if grep -q "Postgres 17" "${PG17[0]}"; then
  pass "pg17 override has self-documenting header"
else
  fail "pg17 override missing header comment"
fi

# 10.2 s3 (both stacks): minio + minio-createbucket services + the storage
#     env contract the image reads; dead vars must be absent.
check_s3() { # check_s3 <file> <minio-container-name>
  local f="$1" cname="$2" n mb cb sb
  n="$(basename "$f")"
  mb="$(block_of "$f" minio)"
  cb="$(block_of "$f" minio-createbucket)"
  sb="$(block_of "$f" storage)"
  [ -n "$mb" ] && pass "$n [minio] service present" || fail "$n [minio] service MISSING"
  printf '%s' "$mb" | grep -Eq 'image: minio/minio:RELEASE\.' && pass "$n [minio] image pinned to a RELEASE tag (no :latest)" || fail "$n [minio] image NOT a pinned RELEASE tag"
  printf '%s' "$mb" | grep -Fq '"mc", "ready", "local"' && pass "$n [minio] healthcheck mc ready local" || fail "$n [minio] MISSING mc ready local healthcheck"
  printf '%s' "$mb" | grep -q 'MINIO_ROOT_USER:' && printf '%s' "$mb" | grep -q 'MINIO_ROOT_PASSWORD:' && pass "$n [minio] MINIO_ROOT_USER/PASSWORD set" || fail "$n [minio] MISSING MINIO_ROOT_* env"
  printf '%s' "$mb" | grep -q 'minio-data:/data' && pass "$n [minio] minio-data volume mounted" || fail "$n [minio] minio-data mount MISSING"
  printf '%s' "$mb" | grep -q 'restart: unless-stopped' && pass "$n [minio] restart: unless-stopped" || fail "$n [minio] missing restart: unless-stopped"
  [ -n "$cb" ] && pass "$n [minio-createbucket] service present" || fail "$n [minio-createbucket] service MISSING"
  printf '%s' "$cb" | grep -Eq 'image: minio/mc:RELEASE\.' && pass "$n [minio-createbucket] image pinned (minio/mc RELEASE tag)" || fail "$n [minio-createbucket] image NOT pinned"
  printf '%s' "$cb" | grep -q 'condition: service_healthy' && pass "$n [minio-createbucket] depends_on minio: service_healthy" || fail "$n [minio-createbucket] missing minio service_healthy"
  printf '%s' "$cb" | grep -Fq 'mc alias set' && printf '%s' "$cb" | grep -Fq 'mc mb --ignore-existing' && pass "$n [minio-createbucket] alias set + idempotent bucket create" || fail "$n [minio-createbucket] entrypoint missing alias/bucket create"
  printf '%s' "$sb" | grep -q 'STORAGE_BACKEND: s3' && pass "$n [storage] STORAGE_BACKEND: s3" || fail "$n [storage] MISSING STORAGE_BACKEND: s3"
  printf '%s' "$sb" | grep -q 'GLOBAL_S3_ENDPOINT: http://minio:9000' && pass "$n [storage] GLOBAL_S3_ENDPOINT -> minio:9000" || fail "$n [storage] MISSING GLOBAL_S3_ENDPOINT"
  printf '%s' "$sb" | grep -q 'GLOBAL_S3_PROTOCOL: http' && pass "$n [storage] GLOBAL_S3_PROTOCOL: http" || fail "$n [storage] MISSING GLOBAL_S3_PROTOCOL"
  printf '%s' "$sb" | grep -q 'GLOBAL_S3_FORCE_PATH_STYLE: "true"' && pass "$n [storage] GLOBAL_S3_FORCE_PATH_STYLE: true" || fail "$n [storage] MISSING GLOBAL_S3_FORCE_PATH_STYLE"
  printf '%s' "$sb" | grep -q 'AWS_ACCESS_KEY_ID:' && printf '%s' "$sb" | grep -q 'AWS_SECRET_ACCESS_KEY:' && pass "$n [storage] AWS_ACCESS_KEY_ID/SECRET set (SDK credential chain)" || fail "$n [storage] MISSING AWS creds"
  printf '%s' "$sb" | grep -q 'condition: service_healthy' && printf '%s' "$sb" | grep -q 'service_completed_successfully' && pass "$n [storage] depends_on minio(healthy) + minio-createbucket(completed)" || fail "$n [storage] missing minio depends_on chain"
  if printf '%s' "$sb" | grep -q 'AWS_ENDPOINT\|AWS_DEFAULT_REGION'; then
    fail "$n [storage] dead AWS_ENDPOINT/AWS_DEFAULT_REGION vars still present (storage-api reads GLOBAL_S3_ENDPOINT/REGION)"
  else
    pass "$n [storage] no dead AWS_ENDPOINT/AWS_DEFAULT_REGION vars"
  fi
  if grep -q '^  minio-data:' "$f"; then
    pass "$n minio-data volume declared"
  else
    fail "$n MISSING minio-data volume"
  fi
}
check_s3 "${S3[0]}" "samay-minio"
check_s3 "${S3[1]}" "samay-testing-minio"

# 10.3 s3 parity: overrides identical across stacks after testing-token
#     normalization (container names + bucket defaults normalize identically).
if diff <(sed 's/samay-testing-/samay-/g' "${S3[0]}") <(sed 's/samay-testing-/samay-/g' "${S3[1]}") >/dev/null 2>&1; then
  pass "s3 overrides identical after testing-token normalization"
else
  fail "s3 overrides SEMANTIC DRIFT: $(diff <(sed 's/samay-testing-/samay-/g' "${S3[0]}") <(sed 's/samay-testing-/samay-/g' "${S3[1]}") | head -6 | tr '\n' ';')"
fi

# 10.4 mailpit (testing-only): pinned image, approved UI port, auth SMTP
#     wiring to the dev sink, SMTP 1025 NOT host-published.
mp="$(block_of "$MAILPIT" mailpit)"
a="$(block_of "$MAILPIT" auth)"
printf '%s' "$mp" | grep -q 'image: axllent/mailpit:v1.30.7' && pass "mailpit image pinned to v1.30.7 (no :latest)" || fail "mailpit image NOT pinned to v1.30.7"
printf '%s' "$mp" | grep -q '54384:8025' && pass "mailpit UI published on 54384:8025" || fail "mailpit MISSING 54384:8025"
if printf '%s' "$mp" | grep -Eq '"[0-9]+:1025"|1025:1025'; then
  fail "mailpit publishes SMTP 1025 on the host (must stay internal)"
else
  pass "mailpit SMTP 1025 not host-published (internal only)"
fi
printf '%s' "$a" | grep -q 'GOTRUE_SMTP_HOST: mailpit' && pass "mailpit override wires auth SMTP host -> mailpit" || fail "mailpit override MISSING GOTRUE_SMTP_HOST: mailpit"
printf '%s' "$a" | grep -q 'GOTRUE_SMTP_PORT: 1025' && pass "mailpit override wires auth SMTP port -> 1025" || fail "mailpit override MISSING GOTRUE_SMTP_PORT: 1025"
printf '%s' "$a" | grep -q 'GOTRUE_SMTP_USER: ""' && pass "mailpit override SMTP user empty (no-auth sink)" || fail "mailpit override SMTP user not empty"
printf '%s' "$a" | grep -q 'condition: service_started' && pass "mailpit override auth depends_on mailpit: service_started" || fail "mailpit override MISSING auth depends_on mailpit"

# 10.5 Merged-config assertions (docker only): the MERGED `docker compose
#     config` output must carry each override's key vars — proof the override
#     survives layering, not just that the file is well-formed.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  merged_has() { # merged_has <dir> <flags...> -- <patterns...> (grep -E)
    local dir="$1"; shift
    local flags=() pats=() in_pat=0 arg
    for arg in "$@"; do
      if [ "$in_pat" = "1" ]; then
        pats+=("$arg")
      elif [ "$arg" = "--" ]; then
        in_pat=1
      else
        flags+=("$arg")
      fi
    done
    local out rc
    out="$(cd "$dir" && docker compose "${flags[@]}" config 2>/dev/null)"
    rc=$?
    [ "$rc" -ne 0 ] && { fail "$(basename "$dir") merged config FAILED to render"; return; }
    local p
    for p in "${pats[@]}"; do
      if printf '%s\n' "$out" | grep -Eq "$p"; then
        pass "$(basename "$dir") merged config has $p"
      else
        fail "$(basename "$dir") merged config MISSING $p"
      fi
    done
  }
  merged_has "$REPO/supabase" -f docker-compose.yml -f docker-compose.pg17.yml -f docker-compose.s3.yml -- \
    "image: supabase/postgres:17.6.1.136" \
    "image: minio/minio:RELEASE.2025-09-07T16-13-09Z" \
    "image: minio/mc:RELEASE.2025-08-13T08-35-41Z" \
    "STORAGE_BACKEND: s3" \
    "GLOBAL_S3_ENDPOINT: http://minio:9000" \
    "GLOBAL_S3_FORCE_PATH_STYLE: \"true\"" \
    "GLOBAL_S3_BUCKET: samay-storage" \
    "AWS_ACCESS_KEY_ID: supa-storage" \
    "service_completed_successfully"
  merged_has "$REPO/supabase-testing" -f docker-compose.yml -f docker-compose.pg17.yml -f docker-compose.s3.yml -f docker-compose.mailpit.yml -- \
    "image: axllent/mailpit:v1.30.7" \
    "GOTRUE_SMTP_HOST: mailpit" \
    "GOTRUE_SMTP_PORT: \"?1025\"?\$" \
    "GLOBAL_S3_BUCKET: samay-testing-storage" \
    "container_name: samay-testing-minio"
else
  echo "  (docker not available — merged-config override assertions skipped)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$FAILURES" -eq 0 ]; then
  echo "  ✅ All compose static checks passed."
  exit 0
else
  echo "  ❌ $FAILURES compose static check(s) FAILED."
  exit 1
fi
echo "═══════════════════════════════════════════════════════════════"
