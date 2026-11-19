#!/usr/bin/env bash
# Cloudflare tunnel for the local testing stack.
#   quick — ephemeral, random trycloudflare.com URL (no domain needed)
#   named — the pre-provisioned testing hostname (needs CLOUDFLARE_TUNNEL_TOKEN)
set -euo pipefail
cd "$(dirname "$0")/.."

KONG_PORT="${KONG_PORT:-${KONG_HTTP_PORT:-54386}}"
TESTING_URL="samay-api-testing.qallariy.lat"

stop_existing() {
  if [ -f .tunnel.pid ]; then
    pid="$(cat .tunnel.pid 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  rm -f .tunnel.pid .tunnel.log .tunnel-url
}

case "${1:-quick}" in
  named)
    : "${CLOUDFLARE_TUNNEL_TOKEN:?set CLOUDFLARE_TUNNEL_TOKEN for the named tunnel}"
    stop_existing
    TUNNEL_TOKEN="$CLOUDFLARE_TUNNEL_TOKEN" cloudflared tunnel --no-autoupdate run > .tunnel.log 2>&1 &
    echo $! > .tunnel.pid
    printf 'https://%s\n' "$TESTING_URL" > .tunnel-url
    echo "tunnel: https://$TESTING_URL"
    ;;
  quick)
    stop_existing
    cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$KONG_PORT" > .tunnel.log 2>&1 &
    echo $! > .tunnel.pid
    for _ in $(seq 1 40); do
      url="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' .tunnel.log | head -1 || true)"
      [ -n "$url" ] && { printf '%s\n' "$url" > .tunnel-url; echo "tunnel: $url"; exit 0; }
      sleep 1
    done
    echo "no trycloudflare URL captured (see .tunnel.log)"; exit 1
    ;;
  stop)
    stop_existing
    echo "tunnel stopped"
    ;;
  *)
    echo "usage: tunnel.sh [quick|named|stop]" >&2; exit 2
    ;;
esac
