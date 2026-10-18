# TODO — samay-backend

> Live cross-cutting state lives in **`<private-ops-repo>/STATUS.md`** (CURRENT STATE ·
> WIP · BACKLOG). This file is **repo-scoped only**.

## Facts
- Go CLI/API (`github.com/samay-app/samay`) + one self-hosted Supabase stack (`supabase/`).
- Single stack (no testing mirror); unique ports 543xx; mailpit local sink.
- `make init` (gum) · `make start` local Docker · `make start ENV=staging|prod` VM+vault.
- CI: `.gitea/workflows/ci.yml`.

## TODO
- [ ] Comment prune / doc trims (AGENTS.md still carries frontend/infra sections).
- [ ] TODO(vault): server profile under `qallariy/admin/**` reorg.
- [ ] TODO: `<deploy-target>` `.200` not provisioned — create (`make init ENV=prod`) then verify.
- [x] RevenueCat server (RCBH): `revenuecat-webhook` Edge Function + SOVR
      `reconcile_subscription_overrides()` (pg_cron 15 min) + `webhook_failures`;
      migration `225_subscription_refactor` (capacity → `subscription_tier`,
      `entitlement_tier` dropped). Local: `make start RC=true`
      (`tools/<fetch-rc-secret>.sh`, vault `*-rc` profile); staging/prod: vault
      `server.env` + `vm-*.override.yml`. Remaining (owner): RC console + vault
      entries — `<private-ops-repo>/REVENUECAT-TODO.md`.
- [x] Staging backend: `<staging-target>` `.202` is **UP** (tart VM + launchd
      service; `samay-api-staging.qallariy.lat/auth/v1/health` → 200). Bring-up
      is `make init ENV=staging` (clone + boot + identity; one doas) then
      `make start ENV=staging` (one vault passphrase + one doas). Source is
      cloned in-VM over HTTPS; `samay-pushworker:prod` is built in-VM from the
      checkout (build overlay), no host preload. Profile:
      `tools/<deploy-env>` (<private-ops-repo>). Runbook:
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
