# Supabase Edge Functions (M-07, 2026-08-10)

> `main/index.ts` is still the **boot placeholder** the pinned
> `supabase/edge-runtime:v1.74.0` image requires; real business functions are
> served from their own directories (the runtime loads `/<name>/index.ts`).

## What lives here today

| Path | Purpose |
|---|---|
| `.gitkeep` | keeps the directory in git |
| `main/index.ts` | **boot placeholder** — required main-service entrypoint. |
| `revenuecat-webhook/index.ts` | **RevenueCat webhook handler (RCBH)** — idempotent subscription sync. Requires `REVENUECAT_WEBHOOK_SECRET` (inert/fail-closed without it). Local: `make start RC=true`; staging/prod: the vault `server.env` + the `functions` compose override. |
| `README.md` | this file |

## EEDG workflow (when functions land)

1. Create a function directory: `supabase/functions/<function-name>/index.ts`
   (e.g. `event-status-poll`, `shard-distribution`,
   `push-notifier`, `revenuecat-webhook`).
2. Deploy from the stack root with the Supabase CLI:
   ```bash
   cd supabase
   supabase functions deploy <function-name> \
     --project-ref <placeholder-project-ref>
   ```
   The self-hosted runtime serves functions at the Kong gateway under
   `/functions/v1/<function-name>` — see `<private-ops-repo>/DEPLOYMENT-PLACEHOLDER.md`
   §1.2 (`https://supabase.samay.example.com/functions/v1/*` is the
   placeholder API base; no real deployment URL is committed).
3. Runtime env (SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY /
   JWT_SECRET / SUPABASE_DB_URL / VERIFY_JWT) is wired in the compose
   `functions` service and passed through to the Deno runtime — do NOT commit
   real keys (`docs/security/SECURITY.md` §2.8; `DEPLOYMENT-PLACEHOLDER.md` §2.3).

## Testing stack

`supabase/functions/` mirrors this directory byte-for-byte (the
`functions` service mounts `./functions:/home/deno/functions` in both stacks;
`test/opt-007-compose-static.sh` §9 pins stack parity).
