#!/usr/bin/env bash
# Interactive local setup for the Samay backend (Docker). gum-driven; every
# menu has a back/quit.
#
# ONE env per project: supabase/.env (gitignored), bootstrapped from the tracked
# supabase/.env.example. Prod credentials are never handled here (VMs + vault).
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
if have cloudflared; then echo "  ok   cloudflared (tunnel mode)"; else echo "  warn cloudflared missing (tunnel mode disabled)"; fi
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

mode="" tunnel_url=""
while :; do
  choice=$(gum choose --header "Backend mode" \
    "local  (docker on 127.0.0.1:$KONG_PORT)" \
    "tunnel (cloudflared)" \
    "quit")
  case "$choice" in
    local*)  mode=local; break ;;
    tunnel*)
      while :; do
        t=$(gum choose --header "Tunnel type" \
          "named (https://$TESTING_URL)" \
          "quick (random trycloudflare.com)" \
          "back")
        case "$t" in
          named*) mode=tunnel; tunnel_url="https://$TESTING_URL"; break 2 ;;
          quick*)
            rm -f .tunnel-url
            echo "starting cloudflared quick tunnel -> http://127.0.0.1:$KONG_PORT"
            bash tools/tunnel.sh quick || { echo "tunnel failed"; continue; }
            tunnel_url="$(cat .tunnel-url 2>/dev/null || true)"
            [ -n "$tunnel_url" ] && { mode=tunnel; break 2; } || continue ;;
          *) break ;;
        esac
      done ;;
    *) echo "aborted"; exit 0 ;;
  esac
done

if [ "$mode" = local ]; then SUPABASE_URL="http://127.0.0.1:$KONG_PORT"; else SUPABASE_URL="$tunnel_url"; fi

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

echo
echo "wrote $STACK_ENV (mode=$mode, url=$SUPABASE_URL)"
echo "next: make start                 # local testing stack"
echo "      make start ENV=staging|prod  # VM + vault"
