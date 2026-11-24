#!/usr/bin/env bash
# =============================================================================
# check-stack-env.sh — pre-boot validation for one stack env file.
#
# Two file classes:
#   LAYOUT  (ENV=testing)       non-secret. Validated: readable, carries stack
#                               identity/ports, and contains NO secret. The
#                               secrets arrive later from the vault.
#   SECRETS (ENV=testing-local) minted locally. Validated: readable, JWT_SECRET
#                               present and not a placeholder.
#
# Usage: bash tools/check-stack-env.sh <env-file> [testing-local|testing]
# Aborts (exit 1) on any violation — no fallback.
# =============================================================================
set -euo pipefail

ENV_FILE="${1:?usage: check-stack-env.sh <env-file> [testing-local|testing]}"
KIND="${2:-}"

if [ ! -r "$ENV_FILE" ]; then
  echo "check-stack-env: env file not readable: $ENV_FILE" >&2
  echo "check-stack-env: run 'make init' or tools/gen-local-env.sh <file>" >&2
  exit 1
fi

# Infer the class from the file name when the caller did not say.
if [ -z "$KIND" ]; then
  case "$(basename "$ENV_FILE")" in
    testing-local.env) KIND=testing-local ;;
    testing.env)       KIND=testing ;;
    *)                 KIND=testing-local ;;
  esac
fi

read_key() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1 | tr -d '"'; }

case "$KIND" in
  testing)
    # Layout: must carry identity and ports, must NOT carry a credential.
    for k in STACK_PREFIX POSTGRES_PORT KONG_HTTP_PORT COMPOSE_FILE; do
      [ -n "$(read_key "$k")" ] || { echo "check-stack-env: $ENV_FILE ($KIND) missing $k" >&2; exit 1; }
    done
    if grep -qE '^[A-Z_0-9_]*(SECRET|_KEY|_PASS)[A-Z_0-9_]*=.+' "$ENV_FILE"; then
      echo "check-stack-env: $ENV_FILE ($KIND) must not carry secrets:" >&2
      grep -nE '^[A-Z_0-9_]*(SECRET|_KEY|_PASS)[A-Z_0-9_]*=.+' "$ENV_FILE" | sed 's/=.*/=<redacted>/' >&2
      exit 1
    fi
    echo "check-stack-env: layout accepted ($ENV_FILE)"
    ;;
  testing-local)
    secret="$(read_key JWT_SECRET)"
    if [ -z "$secret" ]; then
      echo "check-stack-env: JWT_SECRET is required in $ENV_FILE" >&2
      exit 1
    fi
    case "$secret" in
      your-* | *change-in-production* | *changeme* | *placeholder*)
        echo "check-stack-env: refusing placeholder JWT_SECRET in $ENV_FILE" >&2
        exit 1
        ;;
    esac
    if [ "${#secret}" -lt 32 ]; then
      echo "check-stack-env: JWT_SECRET must be at least 32 characters" >&2
      exit 1
    fi
    for k in SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY REALTIME_SECRET_KEY_BASE; do
      [ -n "$(read_key "$k")" ] || { echo "check-stack-env: $ENV_FILE ($KIND) missing $k" >&2; exit 1; }
    done
    echo "check-stack-env: secrets accepted ($ENV_FILE)"
    ;;
  *)
    echo "check-stack-env: unknown kind '$KIND'" >&2
    exit 1
    ;;
esac
