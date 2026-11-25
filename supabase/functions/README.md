# Supabase Edge Functions (M-07, 2026-08-10)

> `main/index.ts` is the **boot placeholder** the pinned
> `supabase/edge-runtime:v1.74.0` image requires. That version serves only its
> `--main-service` entrypoint, so the RevenueCat webhook runs in its own
> `revenuecat-webhook` compose service with that directory as its main service.

## What lives here today

| Path | Purpose |
|---|---|
| `.gitkeep` | keeps the directory in git |
| `main/index.ts` | **boot placeholder** — required main-service entrypoint. |
| `revenuecat-webhook/index.ts` | **RevenueCat webhook handler (RCBH)** — idempotent subscription sync. Requires `REVENUECAT_WEBHOOK_SECRET` (inert/fail-closed without it). Runs in the dedicated `revenuecat-webhook` compose service. The service always starts; export `REVENUECAT_WEBHOOK_SECRET` (and `REVENUECAT_API_KEY`) before `make start` — `RC=true` has no effect here. |
| `README.md` | this file |

## EEDG workflow (when functions land)

1. Create a function directory: `supabase/functions/<function-name>/index.ts`
   (e.g. `push-notifier`, `revenuecat-webhook`).
2. Deploy from the stack root with the Supabase CLI:
   ```bash
   cd supabase
   supabase functions deploy <function-name> \
     --project-ref <placeholder-project-ref>
   ```
   The self-hosted runtime serves functions at the Kong gateway under
   `/functions/v1/<function-name>` (`https://supabase.samay.example.com/functions/v1/*` is the
   placeholder API base; no real deployment URL is committed).
3. Runtime env (SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY /
   JWT_SECRET / SUPABASE_DB_URL / VERIFY_JWT) is wired in the compose
   `functions` service and passed through to the Deno runtime — do NOT commit
   real keys. The security/deployment notes referenced here
   (`docs/security/SECURITY.md` §2.8, `DEPLOYMENT-PLACEHOLDER.md` §2.3,
   `docs/README.md` §1.2) live in the private ops tree, not this repository.
4. Add a service entry (or router) for the new function. The generic
   `functions` service only serves `main/`; `revenuecat-webhook` is the one
   self-authenticated exception.

## Auth contract (SEC-012)

- Kong protects `/functions/v1/*` with the `jwt` plugin (`key_claim_name:
  role`) plus an ACL allowing only `authenticated` and `service_role`.
  Anonymous tokens are verified then denied. Default is deny: a new function
  route must opt into anything else explicitly.
- `/functions/v1/revenuecat-webhook` is a separate, longer Kong route with no
  JWT gate; the handler authenticates RevenueCat with
  `REVENUECAT_WEBHOOK_SECRET` and fails closed when it is missing or wrong.
- `FUNCTIONS_VERIFY_JWT=true` is passed to the functions runtime for future
  runtimes; edge-runtime v1.74.0 does not consume it, so Kong is the enforcing
  layer. The webhook service sets it to `false`.

## Testing stack

There is one stack (`supabase/`); its `functions` service mounts
`./functions:/home/deno/functions`. `test/opt-062-functions-auth.sh` and
`test/opt-063-compose-secrets.sh` pin the auth/secrets contract.
