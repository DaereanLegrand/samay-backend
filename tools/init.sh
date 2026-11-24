#!/usr/bin/env bash
# =============================================================================
# init.sh — first-run setup for the local stack (ENV=testing-local).
#
# This is a THIN wrapper: `make init` and `make regen` share one implementation
# of "which values are generated and how" (tools/secrets.sh → the backend's
# gen-local-env.sh), so the two verbs can never drift.
#
# It does three things:
#   1. check the toolchain,
#   2. create .env/testing-local.env from the tracked .env/example.env when absent,
#   3. point the URLs at the local Kong port, then let the shared engine fill
#      any missing generated value.
#
# ENV=testing is vault-fed: `make init ENV=testing` goes straight to the vault
# engine and never runs this script.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

STACK_ENV=".env/testing-local.env"
STACK_EXAMPLE=".env/example.env"
# One engine for init and regen; it lives in this repo (tools/secrets.sh).

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -t 0 ] || { echo "make init requires an interactive terminal"; exit 1; }

clear
bold "== samay backend setup (testing-local) =="
echo
bold "Requirements"
ok=1
for t in docker gum make openssl uuidgen; do
  if have "$t"; then echo "  ok   $t"; else echo "  MISS $t (required)"; ok=0; fi
done
if docker info >/dev/null 2>&1; then echo "  ok   docker daemon"; else echo "  warn docker daemon not running"; ok=0; fi
echo
[ "$ok" -eq 1 ] || { echo "Install the required tools, then re-run 'make init'."; exit 1; }

if [ ! -f "$STACK_ENV" ]; then
  [ -f "$STACK_EXAMPLE" ] || { echo "MISS $STACK_EXAMPLE — cannot bootstrap $STACK_ENV"; exit 1; }
  mkdir -p "$(dirname "$STACK_ENV")"
  cp "$STACK_EXAMPLE" "$STACK_ENV"
  chmod 600 "$STACK_ENV"
  echo "created $STACK_ENV from $STACK_EXAMPLE"
fi

KONG_PORT="$(sed -n 's/^KONG_HTTP_PORT=\([0-9]*\).*/\1/p' "$STACK_ENV" | head -1)"
KONG_PORT="${KONG_PORT:-54396}"

upsert() { # upsert KEY VALUE
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    $0 ~ "^" k "=" { print k "=" v; done=1; next } { print }
    END { if (!done) print k "=" v }
  ' "$STACK_ENV" > "$tmp"
  mv "$tmp" "$STACK_ENV"
  chmod 600 "$STACK_ENV"
}

# testing-local is reached directly on the host (no tunnel): every URL points at
# the local Kong port so confirmation/recovery links land where Mailpit is.
upsert SUPABASE_URL    "http://127.0.0.1:$KONG_PORT"
upsert SITE_URL        "http://127.0.0.1:$KONG_PORT"
upsert API_EXTERNAL_URL "http://127.0.0.1:$KONG_PORT"

echo
# Same engine, same unit vocabulary, same report as `make regen`.
bash tools/secrets.sh init --file "$STACK_ENV"

echo
echo "next: make start"
