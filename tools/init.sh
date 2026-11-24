#!/usr/bin/env bash
# Interactive local setup for the Samay backend (Docker). gum-driven; every
# menu has a back/quit.
#
# ONE env per project: supabase/.env (gitignored), bootstrapped from the tracked
# supabase/.env.example. Release credentials are never handled here.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="samay"
KONG_PORT="${KONG_PORT:-54386}"
TESTING_URL="samay-api-testing.qallariy.lat"
PROD_URL="samay-api.qallariy.lat"
STACK_ENV="supabase/.env"
STACK_EXAMPLE="supabase/.env.example"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -t 0 ] || { echo "make init requires an interactive terminal"; exit 1; }

clear
bold "== $APP backend setup =="
echo

bold "Requirements"
ok=1
for t in docker gum make python3; do
  if have "$t"; then echo "  ok   $t"; else echo "  MISS $t (required)"; ok=0; fi
done
if docker info >/dev/null 2>&1; then echo "  ok   docker daemon"; else echo "  warn docker daemon not running"; fi
echo
[ "$ok" -eq 1 ] || { echo "Install the required tools, then re-run 'make init'."; exit 1; }

# ONE env per project: bootstrap supabase/.env from the tracked example.
if [ ! -f "$STACK_ENV" ]; then
  [ -f "$STACK_EXAMPLE" ] || { echo "MISS $STACK_EXAMPLE — cannot bootstrap $STACK_ENV"; exit 1; }
  cp "$STACK_EXAMPLE" "$STACK_ENV"
  echo "created $STACK_ENV from $STACK_EXAMPLE"
fi
chmod 600 "$STACK_ENV"
bash tools/gen-local-env.sh "$STACK_ENV" --fill
echo "ok   $STACK_ENV present (local JWT secret + keys ready)"
if [ -f "$STACK_ENV" ]; then
  KONG_PORT="$(sed -n 's/^KONG_HTTP_PORT=\([0-9]*\).*/\1/p' "$STACK_ENV" | head -1)"
  KONG_PORT="${KONG_PORT:-54386}"
fi
echo

# ONE mode: Docker on this host. The Cloudflare tunnel is configured in the
# Cloudflare dashboard (public hostname -> http://localhost:$KONG_PORT); no
# tunnel client is started from this repo, and no token is needed here.
#
# ENV only decides which URL is written into supabase/.env:
#   testing-local — the app talks to Docker directly (127.0.0.1)
#   testing       — the app talks through the public tunnel hostname, so auth
#                   links (SITE_URL / API_EXTERNAL_URL) must carry that host or
#                   confirm/recovery emails point somewhere unreachable.
INIT_ENV="${ENV:-testing-local}"
case "$INIT_ENV" in
  testing-local) SUPABASE_URL="http://127.0.0.1:$KONG_PORT" ;;
  testing)       SUPABASE_URL="https://$TESTING_URL" ;;
  staging|prod)  echo "ENV=$INIT_ENV: staging/prod are provisioned outside this repository." >&2; exit 1 ;;
  *)             echo "unknown ENV=$INIT_ENV" >&2; exit 1 ;;
esac

# Upsert the app-level URL into the single stack env (public; no secret).
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
upsert SUPABASE_URL "$SUPABASE_URL"
upsert API_TESTING_URL "https://$TESTING_URL"
upsert API_PROD_URL "https://$PROD_URL"
# Auth link targets must follow the selected mode, not linger on whichever
# environment last wrote them. `SITE_URL` is what GoTrue stamps into confirm /
# recovery emails; `API_EXTERNAL_URL` is what it reports as its public base.
upsert SITE_URL "$SUPABASE_URL"
upsert API_EXTERNAL_URL "$SUPABASE_URL"

echo
echo "wrote $STACK_ENV (mode=$mode, url=$SUPABASE_URL)"
echo "next: make start                 # local testing stack"
echo "      (staging/prod are provisioned outside this repository)"
