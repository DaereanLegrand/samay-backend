# Samay backend

Self-hosted Supabase stack (Postgres 17 + GoTrue + PostgREST + Realtime +
Storage + Kong) plus a Go admin CLI/API (`github.com/samay-app/samay`). The Go
layer never touches Postgres — it uses PostgREST via Kong with the
`service_role` key.

## Make

- `make init` → `make start` — dev/testing (local Docker stack, `543xx`); `make tunnel` to expose it.
- `make start PROD=true` · `make deploy PROD=true` — prod VM + vault (Admin-only, vault passphrase).
- `make test` · `make test db` (pgTAP) · `make test api` (curl) · `make check` · `make secrets|migrate|hooks`.
- `make build-cli|build-linux|build-api|build-loadtest` · `make loadtest [smoke]`.

## Docs

`<private-ops-repo>/SELFHOSTING.md` (compose stack) · `BACKEND.md` (Go surface) ·
`DATABASE.md` (schema) · `BACKEND-SERVER-VM.md` (VM) · `DEPLOYMENT-PLACEHOLDER.md`.

## Architecture

![Architecture](docs/diagrams/architecture.svg)

## Deployment

![Deployment](docs/diagrams/deployment.svg)
