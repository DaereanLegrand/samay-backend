# TODO — samay-backend

## Facts
- Go CLI/API (`github.com/samay-app/samay`) + one self-hosted Supabase stack (`supabase/`).
- Single stack (no testing mirror); unique ports 543xx; mailpit local sink.
- `make init` (gum) · `make start` local Docker · `make start PROD=true` VM+vault.
- CI: `.gitea/workflows/ci.yml`.

## TODO
- [ ] Comment prune / doc trims (AGENTS.md still carries frontend/infra sections).
- [ ] TODO(vault): server profile under `qallariy/admin/**` reorg.
- [ ] TODO(utm): `<deploy-target>` `.200` (present; reprovision/verify).
