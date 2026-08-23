#!/usr/bin/env bash
# =============================================================================
# dev_env.sh — shared key loader for backend curl opt-tests. Sourced, not run.
#
# Resolves SUPABASE_URL / ANON_KEY / SERVICE_KEY with this precedence:
#   1. explicit environment variables (ANON_KEY / SERVICE_KEY / SUPABASE_URL)
#   2. gitignored stack env files: supabase-testing/.env, supabase/.env,
#      supabase-testing/.env.local, supabase/.env.local
#
# This file contains NO secrets and must never gain any: real keys live only
# in the gitignored env files above (enforced by tools/check_secrets.sh,
# which fails if any local value appears in a tracked file).
#
# Kong key-auth compares literal key strings — using the RUNNING stack's keys
# avoids silently testing against stale defaults after a rotation.
# =============================================================================
_samay_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_samay_root="$(dirname "$_samay_test_dir")"

load_stack_key() { # load_stack_key <ENV_NAME>
  local name="$1" val="" f
  if [ -n "${!name:-}" ]; then printf '%s' "${!name}"; return 0; fi
  for f in \
    "$_samay_root/supabase-testing/.env" \
    "$_samay_root/supabase/.env" \
    "$_samay_root/supabase-testing/.env.local" \
    "$_samay_root/supabase/.env.local"; do
    if [ -r "$f" ]; then
      val="$(grep -E "^${name}=" "$f" | head -1 | cut -d= -f2- | tr -d '"')"
      [ -n "$val" ] && { printf '%s' "$val"; return 0; }
    fi
  done
  return 1
}

export SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
ANON_KEY="$(load_stack_key SUPABASE_ANON_KEY)" || {
  echo "dev_env: SUPABASE_ANON_KEY not set — export it or fill a gitignored" \
       "supabase*/.env[.local] file" >&2
  exit 1
}
SERVICE_KEY="$(load_stack_key SUPABASE_SERVICE_ROLE_KEY)" || {
  echo "dev_env: SERVICE_KEY not set — export SUPABASE_SERVICE_ROLE_KEY or" \
       "fill a gitignored supabase*/.env[.local] file" >&2
  exit 1
}
export ANON_KEY SERVICE_KEY

unset _samay_test_dir _samay_root
