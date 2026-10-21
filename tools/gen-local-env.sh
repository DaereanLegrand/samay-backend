#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
MODE="${2:-generate}"
[ -n "$TARGET" ] || { echo "usage: tools/gen-local-env.sh <env-file> [--fill]" >&2; exit 1; }

case "$TARGET" in
  /*) ;;
  *) TARGET="$PWD/$TARGET" ;;
esac

if [ "$MODE" != "--fill" ]; then
  cp "$ROOT/supabase/.env.example" "$TARGET"
elif [ ! -f "$TARGET" ]; then
  echo "gen-local-env: $TARGET does not exist (omit --fill to create it)" >&2
  exit 1
fi
chmod 600 "$TARGET"

read_key() {
  sed -n "s/^${1}=//p" "$TARGET" | head -1 | tr -d '"'
}

is_placeholder() {
  case "$1" in
    '' | your-* | *change-in-production* | *changeme* | *placeholder*) return 0 ;;
    *) return 1 ;;
  esac
}

upsert() {
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    $0 ~ "^" k "=" { print k "=" v; done=1; next } { print }
    END { if (!done) print k "=" v }
  ' "$TARGET" > "$tmp"
  mv "$tmp" "$TARGET"
  chmod 600 "$TARGET"
}

mint() {
  python3 - "$1" "$2" <<'PY'
import base64, hashlib, hmac, json, sys, time
secret, role = sys.argv[1], sys.argv[2]
def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
now = int(time.time())
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload = b64(json.dumps({
    "role": role,
    "iss": "supabase",
    "iat": now,
    "exp": now + 365 * 24 * 3600,
}, separators=(",", ":")).encode())
signed = f"{header}.{payload}".encode()
print(f"{header}.{payload}.{b64(hmac.new(secret.encode(), signed, hashlib.sha256).digest())}")
PY
}

secret="$(read_key JWT_SECRET)"
if is_placeholder "$secret"; then
  secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  upsert JWT_SECRET "$secret"
fi

upsert AUTH_JWT_SECRET "$secret"
upsert REALTIME_JWT_SECRET "$secret"

anon="$(read_key SUPABASE_ANON_KEY)"
if is_placeholder "$anon"; then
  upsert SUPABASE_ANON_KEY "$(mint "$secret" anon)"
fi

service="$(read_key SUPABASE_SERVICE_ROLE_KEY)"
if is_placeholder "$service"; then
  upsert SUPABASE_SERVICE_ROLE_KEY "$(mint "$secret" service_role)"
fi

echo "gen-local-env: $TARGET ready (JWT_SECRET generated locally, keys minted)" >&2
