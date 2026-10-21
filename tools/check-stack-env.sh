#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-supabase/.env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "check-stack-env: env file not readable: $ENV_FILE" >&2
  echo "check-stack-env: run 'make init' or tools/gen-local-env.sh <file>" >&2
  exit 1
fi

from_file="$(sed -n 's/^JWT_SECRET=//p' "$ENV_FILE" | head -1 | tr -d '"')"
secret="${JWT_SECRET:-$from_file}"

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

echo "check-stack-env: JWT_SECRET accepted ($ENV_FILE)"
