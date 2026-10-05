# Samay backend — agent rules

The Go CLI/API (`github.com/samay-app/samay`) plus one self-hosted Supabase
stack (`supabase/`).

## Commands
- Setup: `make init` (gum; writes `.env`, picks local/tunnel).
- Stack: `make start` (local Docker) · `make start PROD=true` (VM + vault).
- Lifecycle: `make stop|status|reset|seed|db-test|backend-tests` · `make tunnel`.
- Go: `make build-cli|build-linux|build-api|build-loadtest` · `make test` · `make check`.

## Rules
- One stack `supabase/`; migrations single tree `supabase/migrations/**`.
- Ports 543xx (unique to this app).
- Never `make reset` the prod VM stack.
- No secrets in the repo; local `.env` (mode 600) from `make init`, prod from vault.

## Layout
`cmd/`, `internal/`, `supabase/`, `test/opt-*.sh`, `<private-ops-repo>/`, `tools/`, `Makefile`.
