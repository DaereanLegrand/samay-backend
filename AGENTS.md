# Samay backend — agent rules

The Go CLI/API (`github.com/samay-app/samay`) plus one self-hosted Supabase
stack (`supabase/`).

## Commands
- Setup: `make init` (gum; bootstraps `supabase/.env`, picks local/tunnel) · `make init ENV=staging|prod` (vault gate + VM clone).
- Stack: `make start` (local Docker) · `make start ENV=staging|prod` (VM + vault).
- Lifecycle: `make stop|status|reset|seed` · `make test db|api` · `make tunnel`.
- Gates: `make check` · `make secrets` · `make migrate` · `make hooks`.
- Go: `make build-cli|build-linux|build-api|build-loadtest` · `make test`.

## Rules
- One stack `supabase/`; migrations single tree `supabase/migrations/**`.
- Ports 543xx (unique to this app).
- Testing is fed from the single `supabase/.env` (via `supabase/.env.example`); the only testing-time vault fetches are `FCM=true` and `RC=true` (on `start` **and** `reset`).
- Never `make reset` the prod VM stack.
- No secrets in the repo; local `supabase/.env` (mode 600) from `make init`, prod from vault.

## Layout
`cmd/`, `internal/`, `supabase/`, `test/opt-*.sh`, `<private-ops-repo>/`, `tools/`, `Makefile`.
