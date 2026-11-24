#!/usr/bin/env bash
# =============================================================================
# start-stack.sh — bring up the local Supabase stack for one environment.
#
# ENV=testing-local
#   Everything comes from .env/testing-local.env (locally minted JWT_SECRET
#   + keys). No vault is contacted. This is the only file-fed environment.
#
# ENV=testing
#   .env/testing.env is a secret-free LAYOUT (ports, stack identity, toggles),
#   provider client ids). The FULL testing/server/* vault profile is fetched and
#   overlaid on it, so the stack runs on the environment's real secrets. The
#   merged file lives ONLY on the RAM disk.
#
# RAM DISCIPLINE (absolute):
#   The RAM disk is created for this operation and REMOVED on every exit path —
#   success, failure, Ctrl-C, SIGTERM, SIGHUP. A trap is installed before the
#   first byte is materialized and there is no branch that skips the wipe. The
#   disk must never outlive this script.
#
# Usage: bash tools/start-stack.sh <testing-local|testing>
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_KIND="${1:?usage: start-stack.sh <testing-local|testing>}"
case "$ENV_KIND" in
  testing-local|testing) ;;
  *) echo "start-stack: ENV must be testing-local or testing (got '$ENV_KIND')" >&2; exit 2 ;;
esac

# One env file per stack, both under .env/ at the repo root (see the Makefile's
# ENV_STACK_ENV_*). They are never interchangeable: testing.env is a secret-free
# LAYOUT, testing-local.env carries the locally minted secrets, and the two
# stacks run side by side.
SAMAY_ENV_DIR="$(cd "$ROOT/.." && pwd)/.env"
case "$ENV_KIND" in
  testing)       BASE_ENV="$SAMAY_ENV_DIR/testing.env" ;;
  testing-local) BASE_ENV="$SAMAY_ENV_DIR/testing-local.env" ;;
esac
[ -r "$BASE_ENV" ] || {
  if [ "$ENV_KIND" = "testing-local" ]; then
    echo "start-stack: $BASE_ENV missing — run 'make init APP=samay ENV=testing-local'" >&2
  else
    echo "start-stack: $BASE_ENV missing (tracked layout)" >&2
  fi
  exit 2
}

RELEASE_SECRETS="${RELEASE_SECRETS:-$ROOT/../../Admin/infra/tools/release-secrets.sh}"
# One disk per verb, inherited from the Makefile (which exports RAM_TAG), so a
# concurrent `make dev ENV=testing` in another terminal never shares — or
# ejects — this one. Fallback keeps standalone runs working.
RAM_DIR="${RAM_DIR:-/Volumes/SamayRAM-$$-$(od -An -N3 -tu4 /dev/urandom | tr -d ' ')}"

STACK_PREFIX="$(sed -n 's/^STACK_PREFIX=\([A-Za-z0-9_-]*\).*/\1/p' "$BASE_ENV" | head -1)"
[ -n "$STACK_PREFIX" ] || STACK_PREFIX=samay
POSTGRES_PORT="$(sed -n 's/^POSTGRES_PORT=\([0-9]*\).*/\1/p' "$BASE_ENV" | head -1)"
[ -n "$POSTGRES_PORT" ] || POSTGRES_PORT=54382
KONG_HTTP_PORT="$(sed -n 's/^KONG_HTTP_PORT=\([0-9]*\).*/\1/p' "$BASE_ENV" | head -1)"
[ -n "$KONG_HTTP_PORT" ] || KONG_HTTP_PORT=54386
STORAGE_DIR="$(sed -n 's/^STORAGE_DIR=\([^[:space:]]*\).*/\1/p' "$BASE_ENV" | head -1)"
[ -n "$STORAGE_DIR" ] || STORAGE_DIR=./volumes/storage

VAULT_FETCHED=0

# ── RAM lifecycle: installed before anything is materialized ────────────────
# `wipe` is idempotent and safe to call when nothing was fetched. It removes the
# contents FIRST (so a failed eject still leaves no secret) and then detaches.
wipe_ram() {
  gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  if [ -d "$RAM_DIR" ]; then
    find "$RAM_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    diskutil eject "$RAM_DIR" >/dev/null 2>&1 \
      || echo "start-stack: WARN: $RAM_DIR could not be ejected (contents wiped)" >&2
  fi
}
cleanup() {
  local rc=$?
  wipe_ram
  exit "$rc"
}
trap cleanup EXIT
trap 'cleanup' INT TERM HUP

STACK_ENV="$BASE_ENV"

if [ "$ENV_KIND" = "testing" ]; then
  [ -x "$RELEASE_SECRETS" ] || {
    echo "start-stack: ENV=testing needs the vault tooling at $RELEASE_SECRETS" >&2
    echo "             (private ops repo). Use ENV=testing-local to run without it." >&2
    exit 1
  }
  # Fail closed on a leftover disk: any secret still mounted means a previous
  # operation did not clean up, and reusing it would silently mix generations.
  if [ -d "$RAM_DIR" ]; then
    echo "start-stack: $RAM_DIR already mounted — a previous operation did not wipe it." >&2
    echo "             removing it now, then re-fetching from the vault." >&2
    wipe_ram
  fi

  echo "start-stack: fetching the full testing profile from the vault"
  echo "             (one GPG passphrase prompt — it must stay attached to this terminal)"
  # RAM_KEEP=1: this script owns the whole verb (fetch -> merge -> compose up ->
  # migrate) and its own trap wipes the disk on exit. Without the flag the fetch
  # would eject the disk before we could read server.env.
  #
  # NOTE: stdout/stderr are NOT redirected. `release-secrets.sh` runs
  # `ssh -t vault unlock`, whose pinentry prompt is written to this terminal;
  # redirecting it hides the prompt and the verb looks hung while it waits for
  # a passphrase that is never shown.
  RAM_KEEP=1 RC="${RC:-false}" IOS_EXPORT_METHOD="${IOS_EXPORT_METHOD:-app-store-connect}" \
    "$RELEASE_SECRETS" fetch server "$ENV_KIND"
  VAULT_FETCHED=1

  [ -s "$RAM_DIR/server.env" ] || {
    echo "start-stack: vault served no server.env for the testing profile" >&2
    exit 1
  }

  # Merge: the non-secret LAYOUT first (ports, prefix, public URLs, public
  # client ids, feature flags), then the vault's server profile over it. Secrets
  # come ONLY from the vault; there is no in-repo secret file for this env.
  MERGED="$RAM_DIR/stack.env"
  cp "$BASE_ENV" "$MERGED"
  chmod 600 "$MERGED"

  # Reject a layout that carries a secret: a credential in a tracked file is a
  # bug, not a convenience.
  if grep -qE '^[A-Z_0-9_]*(SECRET|_KEY|PASS)[A-Z_0-9_]*=.+' "$BASE_ENV"; then
    echo "start-stack: $BASE_ENV must not carry secrets (layout only):" >&2
    grep -nE '^[A-Z_0-9_]*(SECRET|_KEY|PASS)[A-Z_0-9_]*=.+' "$BASE_ENV" | sed 's/=.*/=<redacted>/' >&2
    exit 1
  fi

  sv() { sed -n "s/^$1=//p" "$RAM_DIR/server.env" | head -1; }
  # Upsert in place: a duplicate key would rely on compose's last-wins ordering,
  # which is not a contract worth leaning on for secrets.
  put() { # put <compose-key> <value>
    local k="$1" v="$2" tmp
    tmp="$(mktemp "$RAM_DIR/.merge.XXXXXX")"
    awk -v k="$k" -v v="$v" '
      $0 ~ "^" k "=" { print k "=" v; done=1; next } { print }
      END { if (!done) print k "=" v }
    ' "$MERGED" > "$tmp"
    mv "$tmp" "$MERGED"
    chmod 600 "$MERGED"
  }

  # Public URL + provider client ids are VAULT values for this env (same source
  # staging uses), not layout facts. SUPABASE_URL derives SITE_URL and the auth
  # link targets so the stack's emails point at the public host.
  PUB_URL="$(sv SUPABASE_URL)"
  put SUPABASE_URL              "$PUB_URL"
  put SITE_URL                  "$PUB_URL"
  put API_EXTERNAL_URL          "$PUB_URL"
  GID="$(sv GOOGLE_OAUTH_CLIENT_ID)"
  GIOS="$(sv GOOGLE_OAUTH_IOS_CLIENT_ID)"
  put GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID "$GID${GIOS:+,$GIOS}"
  put GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI "$PUB_URL/auth/v1/callback"
  put GOTRUE_EXTERNAL_APPLE_REDIRECT_URI  "$PUB_URL/auth/v1/callback"

  JWT="$(sv SUPABASE_JWT_SECRET)"
  put JWT_SECRET                "$JWT"
  put SUPABASE_ANON_KEY         "$(sv SUPABASE_ANON_KEY)"
  put SUPABASE_SERVICE_ROLE_KEY "$(sv SUPABASE_SERVICE_ROLE_KEY)"
  put SYSTEM_ADMIN_USER_ID      "$(sv SUPABASE_ADMIN_USER_ID)"
  put REALTIME_SECRET_KEY_BASE  "$(sv REALTIME_SECRET_KEY_BASE)"
  put RUSTFS_ACCESS_KEY         "$(sv RUSTFS_ACCESS_KEY)"
  put RUSTFS_SECRET_KEY         "$(sv RUSTFS_SECRET_KEY)"
  put GOTRUE_EXTERNAL_GOOGLE_SECRET "$(sv GOOGLE_OAUTH_CLIENT_SECRET)"
  put REVENUECAT_API_KEY        "$(sv REVENUECAT_API_KEY)"
  put REVENUECAT_PROJECT_ID     "$(sv REVENUECAT_PROJECT_ID)"
  put REVENUECAT_WEBHOOK_SECRET "$(sv REVENUECAT_WEBHOOK_SECRET)"
  put ADMIN_API_KEY             "$(sv ADMIN_API_KEY)"

  # Every secret compose consumes, required. Abort — never boot on a partial
  # generation.
  missing=""
  for k in SUPABASE_URL JWT_SECRET SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY \
           REALTIME_SECRET_KEY_BASE RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY \
           GOTRUE_EXTERNAL_GOOGLE_SECRET GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID; do
    if [ -z "$(sed -n "s/^$k=//p" "$MERGED" | head -1)" ]; then missing="$missing $k"; fi
  done
  [ -z "$missing" ] || {
    echo "start-stack: vault profile is missing required secret(s):$missing" >&2
    exit 1
  }

  STACK_ENV="$MERGED"
  echo "start-stack: running on the vault's testing secrets (RAM only)"
else
  echo "start-stack: ENV=testing-local — .env/testing-local.env, no vault contact"
fi

COMPOSE=(docker compose -p "$STACK_PREFIX" --env-file "$STACK_ENV")

# Run compose from supabase/ so relative paths (seed, volumes) resolve; the
# seed file itself is in that directory.
cd "$ROOT/supabase"
if [ "${RESET:-false}" = "true" ]; then
  echo "start-stack: RESET=1 — destroying volumes and storage"
  "${COMPOSE[@]}" down -v
  rm -rf "$STORAGE_DIR"
  docker volume rm "${STACK_PREFIX}_db-data" "${STACK_PREFIX}_rustfs-data" >/dev/null 2>&1 || true
fi
"${COMPOSE[@]}" up -d
"${COMPOSE[@]}" up -d --wait db auth
bash "$ROOT/tools/apply_migrations.sh" supabase
PGPASSWORD=postgres psql -h localhost -p "$POSTGRES_PORT" -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f "$ROOT/supabase/seed-config.sql"
cd "$ROOT"

# Kong caches the auth container IP; auth is recreated above, so Kong must be
# restarted or every /auth/v1/* request returns 502 (issue #113, no route).
docker restart "${STACK_PREFIX}-kong" >/dev/null

echo "Kong: http://localhost:$KONG_HTTP_PORT  (container 8000)"
echo "      point the Cloudflare public hostname here — no tunnel client runs in this repo."
