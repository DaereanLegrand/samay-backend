#!/usr/bin/env bash
# Cloudflare tunnel for the local testing stack.
#   quick — ephemeral, random trycloudflare.com URL (no domain needed)
#   named — the pre-provisioned testing hostname (needs CLOUDFLARE_TUNNEL_TOKEN)
set -euo pipefail
cd "$(dirname "$0")/.."

KONG_PORT="${KONG_PORT:-${KONG_HTTP_PORT:-54386}}"
TESTING_URL="samay-api-testing.qallariy.lat"

case "${1:-quick}" in
  named)
    : "${CLOUDFLARE_TUNNEL_TOKEN:?set CLOUDFLARE_TUNNEL_TOKEN (vault) for the named tunnel}"
    exec cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN"
    ;;
  quick)
    rm -f .tunnel-url
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
    [ -f .tunnel.pid ] && kill "$(cat .tunnel.pid)" 2>/dev/null || true
    rm -f .tunnel.pid .tunnel.log .tunnel-url
    echo "tunnel stopped"
    ;;
  *)
    echo "usage: tunnel.sh [quick|named|stop]" >&2; exit 2
    ;;
esac
