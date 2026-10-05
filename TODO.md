# TODO — samay-backend

## Facts
- Go CLI/API (`github.com/samay-app/samay`) + self-hosted Supabase. Split from `Vive`.
- Makefile is Go/Supabase-only; `supabase-docker-*` removed. `opt-008` split per repo.
- CI: `.gitea/workflows/ci.yml`.

## TODO
- [ ] Align Makefile target names with `<private-ops-repo>/BACKEND-STANDARD.md`.
- [ ] Fix stale `juega` references (`<private-ops-repo>/*`, `tools/check_ports.sh`, `test/opt-007`).
- [ ] Verify `test/<ops-static-check>` against the restored `.gitea` workflow.
- [ ] Decision: tracked `supabase/.env.local` / `supabase-testing/.env.local` (anon key only).
- [ ] Comment prune.
- [ ] TODO(vault): server profile under `qallariy/admin/**` reorg.
- [ ] TODO(utm): `<deploy-target>` `.200`.
