# Samay backend — agent rules

The Go CLI/API (`github.com/samay-app/samay`) plus one self-hosted Supabase
stack (`supabase/`).

## Commands
- `ENV` defaults to `testing-local`, so the everyday verbs need no flags.
- Setup: `make init` (gum; creates `.env/testing-local.env` from the tracked
  `.env/example.env` and mints the generated values). `make init ENV=testing`
  fills missing vault entries instead — `.env/testing.env` is a secret-free
  layout, not a secret store.
- Stack: `make start` (Docker, `.env/testing-local.env`, Kong `:54396`, no
  vault) · `make start ENV=testing` (fetches the
  `testing` vault profile into a RAM disk, overlays it on the tracked layout,
  Kong `:54386`). The Cloudflare tunnel is configured in the Cloudflare
  dashboard and points at that port — no tunnel client runs here. staging/prod
  are provisioned outside this repository.
- RAM disk: `tools/start-stack.sh` and `release-secrets.sh` wipe
  `/Volumes/SamayRAM-<tag>` on EVERY exit path (success, failure, signal). It
  must never outlive a `make <verb>`. A caller that needs several steps in one
  verb passes `RAM_KEEP=1` and installs its own trap — the disk still dies with
  the command.
- Lifecycle: `make stop|restart|status|reset|seed` · `make test db|api`.
- Gates: `make check` · `make secrets` · `make migrate` · `make hooks`.
- Values: `make regen` (all units) or `make regen REGEN_UNITS="rustfs realtime"`.
  It asks before writing, and with `ENV=testing-local` it touches ONLY the env
  file; with `testing|staging|prod` it writes the vault. Values that cannot be
  generated are listed, never silently skipped.
- Go: `make build-cli|build-linux|build-api|build-loadtest` · `make test`.

## Rules
- One stack `supabase/`; migrations single tree `supabase/migrations/**`.
- Ports 543xx (unique to this app).
- Env files live in `.env/` at this repo root, so a standalone clone is
  self-contained. Two classes, never mixed:
  `testing-local.env` holds the secrets the local stack runs on (gitignored,
  mode 600, from `make init`); `testing.env` is a tracked layout of deployment
  facts only — ports, stack identity, toggles. A secret in it fails the gate.
- `ENV=testing` reads the vault for everything but deployment facts: public
  URLs, provider client ids and every secret come from `fetch testing`. No
  fallback — a missing value aborts the verb.
- `FCM=true` starts the push worker (`fcm` compose profile). The
  revenuecat-webhook service always runs and fails closed without
  `REVENUECAT_WEBHOOK_SECRET`; `RC=true` is inert in this repo (the `server`
  vault profile never reaches the RC key emission) — export the secret.

## Layout
`cmd/`, `internal/`, `supabase/`, `test/opt-*.sh`, `docs/`, `tools/`, `Makefile`.
