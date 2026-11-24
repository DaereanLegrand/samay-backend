# Samay — backend

Backend for Samay, a party/minigames app: a self-hosted Supabase stack that
serves prompt packs and multi-device game sessions, plus a Go CLI/API for admin
and operational tasks.

- Client: <https://github.com/DaereanLegrand/samay-frontend>
- Backend: <https://github.com/DaereanLegrand/samay-backend>

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

Env files live in `.env/` at the repo root. `testing-local` mints its own secrets into
`.env/testing-local.env` (Postgres 54392, Kong 54396). `testing` reads
`.env/testing.env` for deployment facts only (Postgres 54382, Kong 54386) and
takes public URLs, client ids and every secret from the vault.

```sh
make init                       # interactive; writes .env/testing-local.env
make start                      # compose up + migrations + seed config

make start ENV=testing          # fetches the vault profile (RAM only)
```

Then connect a client to the stack's Kong port using the anon key from that
stack's env file (or the vault, for `testing`). Other lifecycle verbs:
`make stop`, `make restart`, `make status`, `make reset`, `make seed`.

`make regen` replaces the generated values (all units, or
`REGEN_UNITS="rustfs realtime"`). It confirms first, writes only the env file for
`ENV=testing-local`, and writes the vault for `testing|staging|prod`. Credentials
it cannot generate are listed at the end, so nothing is silently skipped.

## Project layout

| Path | What lives there |
|---|---|
| `supabase/migrations/` | one ordered migration tree; `300_slim/` is this branch's layer |
| `supabase/tests/` | pgTAP suites (`schema_test.sql`, `slim_test.sql`) |
| `supabase/` | compose stack, `config.toml`, seed SQL, edge functions |
| `cmd/` | Go entrypoints (admin, api-server, workers, loadtest) |
| `internal/` | Go packages (auth, billing, push, storage, contracts) |
| `test/` | `opt-*.sh` end-to-end scripts and fixtures |
| `docs/` | architecture and deployment diagrams |

The app itself (Flutter, iOS + Android) lives in the
[client repo](https://github.com/DaereanLegrand/samay-frontend).

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

## Branch notes

This is the `slim-prod` branch. What it is, what was changed on both the client
and the backend, and why: [SLIM-PROD.md](https://github.com/DaereanLegrand/samay-frontend/blob/slim-prod/docs/SLIM-PROD.md).

## License

Samay is released under the **GNU Affero General Public License, version 3**
(AGPL-3.0). The full text is in [`LICENSE`](LICENSE); third-party components and
disclosures are listed in [`NOTICE`](NOTICE). AGPL-3.0 requires that anyone who
runs a modified version of this software as a network service offers its
corresponding source to the users of that service.
