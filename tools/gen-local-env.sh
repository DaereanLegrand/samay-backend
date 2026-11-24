#!/usr/bin/env bash
# =============================================================================
# gen-local-env.sh — mint the GENERATED values of a local stack env file.
#
# This is the file-side counterpart of the vault broker's `regen` verb, and it
# produces the SAME key shapes the broker does for ENV=testing:
#
#   unit            keys
#   supabase-jwt    JWT_SECRET + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY
#                   (one generation: the keys are HS256-minted from the secret)
#   rustfs          RUSTFS_ACCESS_KEY + RUSTFS_SECRET_KEY
#   realtime        REALTIME_SECRET_KEY_BASE
#   admin-uuid      SYSTEM_ADMIN_USER_ID
#
# Everything else in the file is a DEPLOYMENT FACT (ports, URLs, toggles) or a
# FIXED credential (Google/Apple client ids and secrets, SMTP password, FCM and
# RevenueCat keys). Those are never generated here and are reported as skipped.
#
# Usage:
#   gen-local-env.sh <env-file>                 create from .env/example.env
#   gen-local-env.sh <env-file> --fill          fill only missing/placeholder
#   gen-local-env.sh <env-file> --fill <units>  fill only the named units
#   gen-local-env.sh <env-file> --force         regenerate every generated unit
#   gen-local-env.sh <env-file> --force <units> regenerate the named units
#
# Prints one line per generated key and one per skipped unit, then a summary.
# Exit 1 when a generated unit could not be produced.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
[ $# -gt 0 ] && shift
# Default: create the file if absent, then fill what is missing. An explicit
# --fill/--force applies to an existing file.
MODE="--fill"
if [ "${1:-}" = "--fill" ] || [ "${1:-}" = "--force" ]; then
  MODE="$1"; shift
fi
UNITS=("$@")

[ -n "$TARGET" ] || {
  echo "usage: gen-local-env.sh <env-file> [--fill|--force] [unit...]" >&2
  echo "units: supabase-jwt rustfs realtime admin-uuid" >&2
  exit 1
}

case "$TARGET" in
  /*) ;;
  *) TARGET="$PWD/$TARGET" ;;
esac

ALL_UNITS=(supabase-jwt rustfs realtime admin-uuid)

case "$MODE" in
  --fill|--force) ;;
  *) echo "gen-local-env: unknown mode '$MODE' (use --fill or --force)" >&2; exit 1 ;;
esac

if [ "$MODE" = "--force" ]; then
  FORCE=1
elif [ -f "$TARGET" ]; then
  FORCE=0
else
  mkdir -p "$(dirname "$TARGET")"
  cp "$ROOT/.env/example.env" "$TARGET"
  echo "created $TARGET from .env/example.env"
  FORCE=0
fi
chmod 600 "$TARGET"

# No units named ⇒ all of them.
if [ "${#UNITS[@]}" -eq 0 ]; then
  UNITS=("${ALL_UNITS[@]}")
else
  for u in "${UNITS[@]}"; do
    case " ${ALL_UNITS[*]} " in
      *" $u "*) ;;
      *) echo "gen-local-env: unknown unit '$u' (known: ${ALL_UNITS[*]})" >&2; exit 2 ;;
    esac
  done
fi
want() { case " ${UNITS[*]} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

read_key() { sed -n "s/^${1}=//p" "$TARGET" | head -1 | tr -d '"'; }

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

# need <KEY> → 0 when this key must be written (forced, or absent/placeholder).
need() {
  if [ "$FORCE" = "1" ]; then return 0; fi
  is_placeholder "$(read_key "$1")"
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# HS256 JWT with the Supabase shape, signed by <secret> (long-lived: no exp).
mint_jwt() { # <secret> <role>
  local secret="$1" role="$2" h p s
  h="$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)"
  p="$(printf '{"role":"%s","iss":"supabase"}' "$role" | b64url)"
  s="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)"
  printf '%s.%s.%s' "$h" "$p" "$s"
}

reg_hex()   { openssl rand -hex "$1"; }
reg_alnum() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }
reg_uuid()  { uuidgen | tr 'A-Z' 'a-z'; }

printed=()
print_gen() { printed+=("$1"); }

# ── supabase-jwt: secret + both derived keys, always one generation ──────────
if want supabase-jwt; then
  if [ "$FORCE" = "1" ] || need JWT_SECRET \
     || need SUPABASE_ANON_KEY || need SUPABASE_SERVICE_ROLE_KEY; then
    secret="$(reg_hex 32)"
    upsert JWT_SECRET "$secret"
    print_gen JWT_SECRET
    # The anon/service keys MUST be re-derived whenever the secret changes, even
    # in --fill, or the file ships a key that no longer validates.
    upsert SUPABASE_ANON_KEY      "$(mint_jwt "$secret" anon)"
    upsert SUPABASE_SERVICE_ROLE_KEY "$(mint_jwt "$secret" service_role)"
    print_gen SUPABASE_ANON_KEY
    print_gen SUPABASE_SERVICE_ROLE_KEY
  fi
fi

# ── rustfs ──────────────────────────────────────────────────────────────────
if want rustfs; then
  if need RUSTFS_ACCESS_KEY; then
    upsert RUSTFS_ACCESS_KEY "$(reg_alnum 20)"; print_gen RUSTFS_ACCESS_KEY
  fi
  if need RUSTFS_SECRET_KEY; then
    upsert RUSTFS_SECRET_KEY "$(reg_alnum 40)"; print_gen RUSTFS_SECRET_KEY
  fi
fi

# ── realtime ────────────────────────────────────────────────────────────────
if want realtime && need REALTIME_SECRET_KEY_BASE; then
  upsert REALTIME_SECRET_KEY_BASE "$(reg_hex 32)"; print_gen REALTIME_SECRET_KEY_BASE
fi

# ── admin-uuid ──────────────────────────────────────────────────────────────
if want admin-uuid && need SYSTEM_ADMIN_USER_ID; then
  upsert SYSTEM_ADMIN_USER_ID "$(reg_uuid)"; print_gen SYSTEM_ADMIN_USER_ID
fi

# ── Report ──────────────────────────────────────────────────────────────────
if [ "${#printed[@]}" -gt 0 ]; then
  printf 'generated %s\n' "${printed[@]}"
else
  echo "no generated value was written (nothing missing; use --force to replace)"
fi

# Every unit that was asked for but produced nothing is named, never silent.
skipped=()
for u in "${UNITS[@]}"; do
  case "$u" in
    supabase-jwt) keys="JWT_SECRET SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY" ;;
    rustfs)       keys="RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY" ;;
    realtime)     keys="REALTIME_SECRET_KEY_BASE" ;;
    admin-uuid)   keys="SYSTEM_ADMIN_USER_ID" ;;
  esac
  wrote=0
  for k in $keys; do
    case " ${printed[*]:-} " in *" $k "*) wrote=1 ;; esac
  done
  [ "$wrote" = "1" ] || skipped+=("$u")
done
if [ "${#skipped[@]}" -gt 0 ]; then
  printf 'not regenerated (already present) %s\n' "${skipped[@]}"
fi

echo "gen-local-env: $TARGET ready" >&2
