#!/usr/bin/env bash
# Samay — Kong startup wrapper for the pinned kong/kong:3.9.3 image.
#
# Why this wrapper exists (M-09, 2026-08-10 — DKR-06):
#   1. Bounded wait for the Postgres dependency (compose service `db`) before
#      Kong starts, so upstream services (auth/rest/realtime/storage/meta)
#      resolve on the first request. Compose `depends_on: db: service_healthy`
#      already gates startup; this loop is belt-and-braces for manual
#      `docker compose restart kong` and `docker run` invocations.
#   2. The declarative config is STATIC (volumes/api/kong.yml mounted at
#      $KONG_DECLARATIVE_CONFIG) — no templating is needed here. key-auth
#      credentials keep their placeholders (your-anon-key /
#      your-service-role-key); aligning them with .env / opt-test keys is the
#      MKE/S-10 handoff (see docs/development/phase-00-foundation/
#      2026-08-10_M09-kong.md) — real keys are never embedded in this repo.
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

echo "[kong-entrypoint] declarative config is static at ${KONG_DECLARATIVE_CONFIG:-/api/kong.yml}; no templating."
exec /entrypoint.sh kong docker-start
