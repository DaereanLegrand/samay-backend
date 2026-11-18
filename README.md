# Samay backend — slim build

Self-hosted Supabase stack (Postgres 17 + GoTrue + PostgREST + Realtime +
Storage + Kong) plus a Go admin CLI/API (`github.com/samay-app/samay`). The Go
layer never touches Postgres — it uses PostgREST via Kong with the
`service_role` key.

## Make

- `make init APP=samay ENV=testing-local` → `make start APP=samay ENV=testing-local` — dev/testing (local Docker stack, `543xx`); `make tunnel` to expose it.
- `make init APP=samay ENV=staging|prod` — reconcile the env vault profile (Reuse/Re-generate) + clone its VM; then `make start APP=samay ENV=staging|prod`.
- `make start APP=samay ENV=staging|prod` · `make deploy APP=samay ENV=staging|prod` — VM + vault (Admin-only, vault passphrase).
- `make start APP=samay ENV=testing-local` — local Docker; `ENV=testing` adds the free Cloudflare tunnel (`TUNNEL=named` needs `CLOUDFLARE_TUNNEL_TOKEN`; `TUNNEL=quick` gives a random trycloudflare URL).
- `make test` · `make test db` (pgTAP) · `make test api` (curl) · `make check` · `make secrets|migrate|hooks`.
- `make build-cli|build-linux|build-api|build-loadtest` · `make loadtest [smoke]`.

## Testing config

The testing feed comes from the single **`supabase/.env`** (one `.env` per
project; `supabase/.env.example` is the committed template, bootstrapped by
`make init`). The **only** testing-time vault fetches are opt-in on the
CLI/shell, honored by `start` **and** `reset`:

- `FCM=true` → `tools/<fetch-fcm-secret>.sh` (the push worker's FCM key).
- `RC=true` → `tools/<fetch-rc-secret>.sh` (RevenueCat server secrets; `RC_ENV` selects
  `testing` (default) or `staging`).

There is no other edge case. `make start APP=samay ENV=staging|prod` is vault-gated
(everything from the vault); testing is not.


## Slim layer (this branch)

The slim app keeps games, auth, profile, settings, notifications, friends,
groups and prompt packs. Two deliberate choices:

- **Forward-fix, not a squashed baseline.** `supabase/migrations/300_slim/`
  sits after `970` and is the only place this branch changes the schema. It is
  fully idempotent, so it applies cleanly to a fresh stack and to an existing
  one.
- **Removed features keep their tables; clients lose the grants.** That makes a
  progressive re-add a GRANT plus feature code instead of a schema rebuild.

| File | What it does |
|---|---|
| `300_slim/01_onboarding.sql` | guest columns (`is_guest`, `age_confirmed_at`, `terms_accepted_at`, `terms_version`), `is_onboarded()`, `bootstrap_profile()`, `confirm_my_account()` |
| `300_slim/02_prompt_packs.sql` | `prompt_packs` + `minigame_prompts.pack_id`, seeded free/paid packs, `list_prompt_packs()`, `get_prompt_pack()`; prompts no longer client-readable |
| `300_slim/03_remove_wagers.sql` | wager-free `create_minigame_session`; escrow/ledger writes neutralised across the play RPCs |
| `300_slim/04_leave_session.sql` | `leave_minigame_session()` (participant leave, host transfer) |
| `300_slim/05_revoke_removed.sql` | revokes client grants on every removed-feature relation |

Anonymous sign-ins and manual identity linking are enabled in
`supabase/config.toml`, `supabase/.env.example` and `supabase/docker-compose.yml`
(`GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED`, `GOTRUE_SECURITY_MANUAL_LINKING_ENABLED`).

Tests: `supabase/tests/schema_test.sql` (kept surface) and
`supabase/tests/slim_test.sql` (the slim contracts). Go: `go test ./...`.
Shell: `make test api`.

## Docs

`<private-ops-repo>/SELFHOSTING.md` (compose stack) · `BACKEND.md` (Go surface) ·
`DATABASE.md` (schema) · `BACKEND-SERVER-VM.md` (VM) · `DEPLOYMENT-PLACEHOLDER.md`.

## Architecture

![Architecture](docs/diagrams/architecture.svg)

## Deployment

![Deployment](docs/diagrams/deployment.svg)
