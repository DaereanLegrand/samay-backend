# TODO — samay-backend

> Live cross-cutting state lives in **`<private-ops-repo>/STATUS.md`** (CURRENT STATE ·
> WIP · BACKLOG). This file is **repo-scoped only**.

## Facts
- Go CLI/API (`github.com/samay-app/samay`) + one self-hosted Supabase stack (`supabase/`).
- Single stack (no testing mirror); unique ports 543xx; mailpit local sink.
- `make init` (gum) · `make start` local Docker · `make start ENV=staging|prod` VM+vault.
- CI: `.gitea/workflows/ci.yml`.

## TODO
- [x] Chat moderation + store-compliance hardening (Google Play UGC / Apple 1.2):
      - `226_chat_moderation` — `is_blocked_between`; block gate in
        `create_direct_chat`; `assert_message_not_blocked` BEFORE-INSERT trigger
        on `messages` (blocked pairs cannot exchange DMs); `report_message`
        (participant-gated; writes the `reports` queue row + a moderator-only
        `message_reports` snapshot of the reported plaintext/media — the
        documented E2EE reporting exception). `messages.reported` flagged.
      - `227_bottle_sober` — rephrases the Botella drinking dares into generic
        "castigo" penalties (Apple 1.4.3 / content-rating accuracy).
      - `228_moderation_hardening` — `pending_object_deletions` ENABLE RLS (was
        FORCE-only); revoke PUBLIC/anon EXECUTE on `apply_subscription_state` +
        `reconcile_subscription_overrides` (privilege escalation).
      - Admin CLI: `samay-admin reports message <report_id>` shows the reported
        message content (moderator view).
      - Coverage: pgTAP SECTION 65 (plan 1040) + `test/opt-040-chat-report-block.sh`.
      - Test hygiene: `opt-001`/`opt-006` cleanups delete NO-ACTION-FK rows (no
        user leaks); `opt-021/022/023/028` mark participants ready (219 gate);
        `opt-034` rewritten for the split CI surface; schema #210 tolerates the
        required store reviewer account (`tester@qallariy.lat`, seed-config).
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
