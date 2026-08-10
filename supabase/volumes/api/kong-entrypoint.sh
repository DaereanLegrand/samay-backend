#!/usr/bin/env bash
# Samay — Kong startup wrapper for the pinned kong/kong:3.9.3 image.
#
# Why this wrapper exists (M-09, 2026-08-10 — DKR-06):
#   1. Bounded wait for the Postgres dependency (compose service `db`) before
#      Kong starts, so upstream services (auth/rest/realtime/storage/meta)
#      resolve on the first request. Compose `depends_on: db: service_healthy`
#      already gates startup; this loop is belt-and-braces for manual
#      `docker compose restart kong` and `docker run` invocations.
#   2. The declarative config is TEMPLATED here (M-03, 2026-08-10 — closes the
#      MKE/S-10 handoff, SELFHOSTING.md row 22): Kong 3.9 does NOT expand
#      environment variables in declarative config natively (verified against
#      kong/db/declarative at the 3.9.0 tag — no env handling), so this
#      wrapper substitutes the $VAR references in the mounted template
#      (volumes/api/kong.yml -> /api/kong.yml) into $KONG_DECLARATIVE_CONFIG
#      before exec'ing the image entrypoint — the official supabase pattern
#      (docker/volumes/api/kong-entrypoint.sh, kong/kong:3.9.3). awk is used
#      instead of eval/echo on purpose: eval strips double quotes and breaks
#      YAML "Header: value" mappings.
#   3. `exec` the image's REAL entrypoint. The published kong/kong:3.9.x
#      image uses the legacy layout (verified via the image's registry config
#      blob, 2026-08-10): ENTRYPOINT ["/entrypoint.sh"], CMD ["kong",
#      "docker-start"]. This wrapper is mounted at /home/kong/kong-entrypoint.sh
#      (NOT over /entrypoint.sh) so the image entrypoint stays intact.
#
# Idempotent: no temp files, no state; safe to re-run. LF line endings only
# (CRLF in mounted scripts is a known Kong Docker failure mode).
set -Eeuo pipefail

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_WAIT_ATTEMPTS="${DB_WAIT_ATTEMPTS:-60}"
DB_WAIT_INTERVAL="${DB_WAIT_INTERVAL:-2}"
KONG_DECLARATIVE_CONFIG="${KONG_DECLARATIVE_CONFIG:-/usr/local/kong/kong.yml}"
KONG_DECLARATIVE_TEMPLATE="${KONG_DECLARATIVE_TEMPLATE:-/api/kong.yml}"

echo "[kong-entrypoint] waiting for Postgres at ${DB_HOST}:${DB_PORT} (max ${DB_WAIT_ATTEMPTS} x ${DB_WAIT_INTERVAL}s)"
attempt=0
while [ "${attempt}" -lt "${DB_WAIT_ATTEMPTS}" ]; do
  if (exec 3<>"/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; then
    exec 3>&- 3<&-
    echo "[kong-entrypoint] Postgres is reachable."
    break
  fi
  attempt=$((attempt + 1))
  sleep "${DB_WAIT_INTERVAL}"
done

if [ "${attempt}" -ge "${DB_WAIT_ATTEMPTS}" ]; then
  echo "[kong-entrypoint] ERROR: Postgres not reachable after ${DB_WAIT_ATTEMPTS} x ${DB_WAIT_INTERVAL}s; aborting (restart policy will retry)." >&2
  exit 1
fi

# Substitute $VAR references in the declarative template (M-03): Kong does
# not expand env vars natively, so keyauth_credentials keys (ANON_KEY /
# SERVICE_ROLE_KEY) are resolved here before Kong starts. awk (the official
# supabase pattern) preserves YAML quoting — do NOT replace with
# eval/echo/sed.
awk '{
  result = ""
  rest = $0
  while (match(rest, /\$[A-Za-z_][A-Za-z_0-9]*/)) {
    varname = substr(rest, RSTART + 1, RLENGTH - 1)
    if (varname in ENVIRON) {
      result = result substr(rest, 1, RSTART - 1) ENVIRON[varname]
    } else {
      result = result substr(rest, 1, RSTART + RLENGTH - 1)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  print result rest
}' "${KONG_DECLARATIVE_TEMPLATE}" > "${KONG_DECLARATIVE_CONFIG}"
echo "[kong-entrypoint] declarative config resolved from ${KONG_DECLARATIVE_TEMPLATE} into ${KONG_DECLARATIVE_CONFIG}."

exec /entrypoint.sh kong docker-start
