# TODO — samay-backend

> Live cross-cutting state lives in **`<private-ops-repo>/STATUS.md`** (CURRENT STATE ·
> WIP · BACKLOG). This file is **repo-scoped only**.

## Facts
- Go CLI/API (`github.com/samay-app/samay`) + one self-hosted Supabase stack (`supabase/`).
- Single stack (no testing mirror); unique ports 543xx; mailpit local sink.
- `make init APP=samay ENV=testing-local` (gum) · `make start APP=samay ENV=testing-local|testing` Docker · `ENV=staging|prod` VM+vault.

## Branch: slim-prod

The slim production backend. Changes live only in `supabase/migrations/300_slim/`
(forward-fix, idempotent) plus the anonymous-linking config. See `README.md`
§ "Slim layer" for the file map.

Shipped and verified on a fresh local stack:

- [x] Anonymous sign-ins + manual identity linking (`config.toml`,
      `.env.example`, `docker-compose.yml`; guest → Apple/Google keeps the uid).
- [x] One-checkbox onboarding: `bootstrap_profile()` records 18+/terms and
      creates the guest row atomically; `create_minigame_session` refuses with
      `not_onboarded` until then.
- [x] Prompt packs: `prompt_packs` + `pack_id`, 8 seeded (4 free with prompts,
      4 paid), `list_prompt_packs()` / `get_prompt_pack()`; prompt bodies are no
      longer client-readable (RPC only).
- [x] WaGers removed from the whole play surface (create/join/accept/leave/
      finish); `shard_wager` stays as a retired always-0 column.
- [x] `leave_minigame_session()` with host transfer.
- [x] Removed-feature relations revoked from `anon`/`authenticated` (tables kept
      for progressive re-add).
- [x] Go admin/API surface pruned (events, groups admin, shards, subs
      overrides); `go test ./...`, `go vet`, `go build` green.
- [x] `schema_test.sql` rewritten for the kept surface (901 assertions) +
      `slim_test.sql` (52); both green, re-runnable. Opt suite trimmed to 34
      scripts, all green.

## TODO
- [x] **Wave 1B consolidated** on `wave1b-conciliated` (tag `wave1b-base`):
      lanes A→B→C, combined `purge_user`/views/ranking/`search_events`,
      `232`→`970`; fresh pgTAP `1184/1184`, 1B abuse suites green.
- [x] **Wave 2 E0–E4 server:** contract fixtures (`test/contracts/`),
      economy distribution/cancel/reconciliation (`236`), subscription
      expiry/grace/overrides/retries (`237` + `samay-billing-worker`), limits +
      `create_group` + rank gating + admin audit (`238`), code-only minigame
      join codes (`239`). pgTAP `1276/1276`; `opt-068`/`069` green. (Slim-prod
      later deleted `opt-067` with the shard economy.)
- [x] Group theme server (`240_group_theme`): host-owned
      `everyone|host_only|locked`, tier palette (free black; pro/vip RGB),
      WCAG-AA auto contrast, 3/min/group + 20/day/user, audit + RLS.
      pgTAP SECTION 75; `opt-070` 13/13.
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
      - Coverage: pgTAP SECTION 65 (plan 1040). The curl half was
        `test/opt-040-chat-report-block.sh`, deleted with E2EE chat in
        slim-prod. `opt-065` still covers report_content/review/dismiss/appeals.
      - Test hygiene: `opt-001`/`opt-006` cleanups delete NO-ACTION-FK rows (no
        user leaks); `opt-021/022/023/028` mark participants ready (219 gate);
        the store reviewer (`tester@qallariy.lat`) is an Admin-owned
        staging/prod seed, not backend data.
- [x] E5 verifier: pgTAP `1319/1319`; all 46 `opt-*` green (legacy suites
      triaged to the E3/E4 contracts); `make test`, `make check`, Go green.
      Photo-read triage fix `241_event_photo_read` (229 narrowed
      `events_read_access`, hiding group-scoped photos; both removed in
      slim-prod). CI files deleted per `14-wave2-decisions` §13
      (`tools/<ops-tooling>` reduced to the Gitea SCM half).
- [ ] Comment prune / doc trims (AGENTS.md still carries frontend/infra sections).
- [ ] TODO(vault): server profile under `qallariy/admin/**` reorg.
- [ ] TODO: `<deploy-target>` `.200` not provisioned — create (`make init ENV=prod`) then verify.
- [x] RevenueCat server (RCBH): `revenuecat-webhook` Edge Function + SOVR
      `reconcile_subscription_overrides()` (pg_cron 15 min) + `webhook_failures`;
      migration `225_subscription_refactor` (capacity → `subscription_tier`,
      `entitlement_tier` dropped). Local: `make start APP=samay ENV=testing-local RC=true`
      (`tools/<fetch-rc-secret>.sh`, vault `*-rc` profile); staging/prod: vault
      `server.env` + `vm-*.override.yml`. Remaining (owner): RC console + vault
      entries — `<private-ops-repo>/REVENUECAT-TODO.md`.
- [x] Staging backend: `<staging-target>` `.202` is **UP** (tart VM + launchd
      service; `samay-api-staging.qallariy.lat/auth/v1/health` → 200). Bring-up
      is `make init ENV=staging` (clone + boot + identity; one doas) then
      `make start APP=samay ENV=staging` (one vault passphrase + one doas). Source is
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
      `make start APP=samay ENV=testing-local FCM=true` fetches the testing FCM service account from the
      vault (`tools/<fetch-fcm-secret>.sh`, <build-host> → <build-host>) and injects it
      via the shell env; `FCM=false`/unset ⇒ no fetch, no worker. staging/prod
      default on (`COMPOSE_PROFILES=fcm`).
