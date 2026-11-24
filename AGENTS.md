# Samay backend — agent rules

The Go CLI/API (`github.com/samay-app/samay`) plus one self-hosted Supabase
stack (`supabase/`).

## Commands
- Setup: `make init APP=samay ENV=testing-local|testing` (gum; bootstraps `supabase/.env`, mints the local JWT + keys).
- Stack: `make start APP=samay ENV=testing-local|testing` (Docker; Kong on
  `localhost:54386`). `testing-local` runs on `supabase/.env` alone;
  `testing` fetches the FULL `testing/server/*` profile from the vault and runs
  on those secrets. The Cloudflare tunnel is configured in the Cloudflare
  dashboard and points at that port — no tunnel client runs here. staging/prod
  are provisioned outside this repository.
- RAM disk: `tools/start-stack.sh` and `release-secrets.sh` wipe
  `/Volumes/SamayRAM` on EVERY exit path (success, failure, signal). It must
  never outlive a `make <verb>`. A caller that needs several steps in one verb
  passes `RAM_KEEP=1` and installs its own trap — the disk still dies with the
  command.
- Lifecycle: `make stop|restart|status|reset|seed APP=samay ENV=…` · `make test db|api`.
- Gates: `make check` · `make secrets` · `make migrate` · `make hooks`.
- Go: `make build-cli|build-linux|build-api|build-loadtest` · `make test`.

## Rules
- One stack `supabase/`; migrations single tree `supabase/migrations/**`.
- Ports 543xx (unique to this app).
- Testing is fed from the single `supabase/.env` (via `supabase/.env.example`); `FCM=true` and `RC=true` opt the push worker and the RevenueCat webhook in.
- No secrets in the repo; `supabase/.env` (mode 600) from `make init`.

## Layout
`cmd/`, `internal/`, `supabase/`, `test/opt-*.sh`, `docs/`, `tools/`, `Makefile`.
