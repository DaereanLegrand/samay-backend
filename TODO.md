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
- [ ] Staging backend: `<staging-target>` `.202` (tooling ready:
      `make -C <private-ops-repo> start PROD=true APP=samay-staging`; profile
      `apps/samay-staging.env` + `fetch staging` vault profile). Needs the
      staging VM + vault `qallariy/samay/staging/**`. Runbook:
      `<private-ops-repo>/STAGING.md`.
- [x] Migrations are re-run safe: `public._qallariy_migrations` ledger in
      `tools/apply_migrations.sh` (mirrored in `<guest-script>`) → `make start`
      applies only pending files. A pre-ledger DB adopts **once** with
      `make migrate-adopt` (VM: `ADOPT=1 <guest-script>`); fresh (`make reset`)
      never adopts.
- [x] Push worker as a `fcm`-profile compose overlay (base compose pristine);
      `make start FCM=true` fetches the testing FCM service account from the
      vault (`tools/<fetch-fcm-secret>.sh`, <build-host> → <build-host>) and injects it
      via the shell env; `FCM=false`/unset ⇒ no fetch, no worker. staging/prod
      default on (`COMPOSE_PROFILES=fcm`).
