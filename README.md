# Samay — backend

Backend for Samay, a party/minigames app: a self-hosted Supabase stack that
serves prompt packs and multi-device game sessions, plus a Go CLI/API for admin
and operational tasks.

## What this is

- **Self-hosted Supabase.** Postgres 17, GoTrue, PostgREST, Realtime, Storage and
  Kong run from `supabase/docker-compose.yml`.
- **Go CLI/API** (`github.com/samay-app/samay`) for admin and service tasks. It
  reads and writes through PostgREST (via Kong, `service_role`), never Postgres
  directly.
- **Guest-first auth.** Anonymous sign-ins and manual identity linking (guest →
  Apple/Google, same uid) are enabled in `supabase/config.toml` and
  `supabase/docker-compose.yml`.
- **Games-only schema.** `supabase/migrations/300_slim/` is a forward-fix layer
  after the existing tree: guest onboarding, prompt packs, wager removal,
  participant leave, and revoked client grants for removed features. Tables for
  removed features are kept so they can be re-added with a grant plus feature
  code rather than a schema rebuild.
- **This is a slim build.** Events, chat, feed, photos, rankings, shards/wagers
  and cosmetics are not exposed. They will be re-added progressively.

## Requirements

- Docker with Compose v2
- Go 1.26+ (`go.mod`)
- `make`, `gum` and `python3` (used by `make init`)
- Supabase CLI for the pgTAP suite (`make test db`)

## Quick start

The local stack publishes Postgres on 54382 and Kong on 54386.

```sh
make init APP=samay ENV=testing-local    # interactive; writes supabase/.env
make start APP=samay ENV=testing-local   # compose up + migrations + seed config
```

Then connect a client to `http://127.0.0.1:54386` using the anon key from
`supabase/.env`. Other lifecycle verbs: `make stop`, `make restart`,
`make status`, `make reset`, `make seed`.

## Project layout

| Path | What lives there |
|---|---|
| `supabase/migrations/` | one ordered migration tree; `300_slim/` is this branch's layer |
| `supabase/tests/` | pgTAP suites (`schema_test.sql`, `slim_test.sql`) |
| `supabase/` | compose stack, `config.toml`, seed SQL, edge functions |
| `cmd/` | Go entrypoints (admin, api-server, workers, loadtest) |
| `internal/` | Go packages (auth, billing, push, storage, contracts) |
| `test/` | `opt-*.sh` end-to-end scripts and fixtures |
| `docs/` | infra and database notes |

## Testing

```sh
make test db    # pgTAP via supabase db test (runs schema_test.sql)
make test api   # curl opt-tests (test/opt-*.sh, 34 scripts)
make test       # go test ./... plus static seed/Makefile checks
make check      # secret scan, go vet, gofmt
make migrate    # migration ordering/ledger check
```

`schema_test.sql` holds 901 assertions for the kept surface; the slim contracts
in `supabase/tests/slim_test.sql` (52) run with the same tool by naming the file
(`supabase db test --db-url … -- supabase/tests/slim_test.sql`).
