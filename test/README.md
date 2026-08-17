# Samay — Testing Guide

This guide covers the **full test matrix** of the Samay repo. For the
one-paragraph overview see the root [`README.md`](../README.md#testing-summary).

## The Test Matrix

| Layer | Where | Command | Notes |
|-------|-------|---------|-------|
| **Flutter unit/widget** | `test/` | `make flutter-test` | Mirrors `lib/` layout: `test/features/`, `test/router/`, `test/providers/`, `test/services/`, `test/theme/`, `test/widgets/`. Full suite green — **2440/2440** (re-verified 2026-08-16; the historical 176 pass / 23 fail baseline was fixed by I-47). |
| **Flutter modular integration** | `integration_test/` | `flutter test integration_test/<module>_test.dart -d <device>` | **Landed (I-01, 2026-08-09).** One file per module/feature — 19 flows registered in `runner.sh`'s `ORDERED_FLOWS` (auth, ban, error, profile, theme, cosmetics, events, photos, chat, group chat, QR, realtime, notifications, feed, party finder, subscriptions, minigames, telemetry + `ui_smoke_test.dart`; friends/groups folded into other flows by I-78) — plus `integration_test/README.md` and `runner.sh` (dependency-safe order, exit 0/1). Each file is **independently runnable** and **hermetic by default**: flows run against the in-memory Supabase harness (`integration_test/support/fake_supabase.dart`) with zero network; live-stack flows are opt-in (`support/test_users.dart`, skips when the stack is down). When you build a feature, add its flow file here and register it in `runner.sh`. |
| **Backend (curl opt-tests)** | `test/opt-*.sh` | `bash test/run_all_backend.sh` | Self-contained curl scripts that hit Supabase REST/Auth exactly like the Dart client (see "How to Test Backend Changes" below). Run against Kong at `http://127.0.0.1:54386`. Prerequisites: `make supabase-docker-start`, `make supabase-docker-reset`. Suite: `opt-001` RLS security · `opt-002` event lifecycle (fields/CHECK/QR-trigger/RLS) · `opt-003` chat + E2EE envelope contract · `opt-004` photo gallery contract · `opt-005` seed-dev static gate (no stack) · `opt-006` `fetch_prekey_bundle` contract (OPK consumption) · `opt-007` compose/config static gate (no stack) · `opt-008` Makefile/scratch-repo static gate (no stack) · `opt-009` groups chain (invites/roles/chain-of-command) · `opt-010` groups chat (E2EE sender-key distribution + read receipts) · `opt-011` groups reads (group chat read paths). All auto-discovered by the `test/opt-*.sh` glob in the runner. |
| **Go (admin CLI + ops)** | `*_test.go` | `go test ./...` | 182 tests: CLI flag/validation behavior (cobra) and `internal/ops` business logic against `httptest` servers. Run via `make test` together with Flutter. |
| **SQL (pgTAP)** | `supabase/tests/schema_test.sql` | `supabase db test` | 494 assertions (plan 494, both stacks): extensions, 21 enums, 30+ tables, 17 triggers, RPCs, RLS policy sets per table, seed data (`app_config` 38 keys, 1 system admin). New migrations must extend this file. |
| **Manual end-user QA** | `test_runner.sh` (root) | `bash test_runner.sh` | gum-based interactive runner — 55 cases across auth → leaderboard (Phases 00–04). Wipes local user data, records results to a timestamped markdown file. Not part of the automated TDD suite; used for pre-release device testing. |

**Golden rule:** every code change ships a test at its layer. Flutter unit/widget
tests in `test/`, integration flow in `integration_test/`, curl opt-test in
`test/opt-NNN-*.sh` (+ registered by `run_all_backend.sh`), Go `*_test.go`,
SQL pgTAP in `supabase/tests/schema_test.sql`.

---

## Workflow

Every optimization or bug fix follows this cycle:

```
1. WRITE TEST   →  curl script that verifies expected correct behavior
2. IMPLEMENT    →  migration / code change
3. VERIFY       →  run test script; must pass
4a. PASSES      →  show user, move to next item
4b. FAILS       →  debug & fix; if stuck, ask user
```

Tests are written **before** implementation. The test defines what "correct" means. Implementation makes it pass.

---

## How to Test Backend Changes

All backend tests use **curl** to hit Supabase REST and Auth endpoints — exactly as the Flutter/Dart client does. No psql (except for schema-level checks that the client can't do).

### Anatomy of a curl test

Every request emulates one of three client states:

| Client State | HTTP Headers | When Used |
|-------------|--------------|-----------|
| **Unauthenticated (anon)** | `apikey: <ANON_KEY>` only | Before login, public data |
| **Authenticated** | `apikey: <ANON_KEY>` + `Authorization: Bearer <JWT>` | After login |
| **Admin (service_role)** | `apikey: <SERVICE_KEY>` + `Authorization: Bearer <SERVICE_KEY>` | Test setup only (seed data) |

### Helper patterns (from `opt-001-rls-security.sh`)

```bash
# ---------- anon (no JWT, only apikey) ----------
anon_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY"
}
anon_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d "$2"
}

# ---------- authenticated (apikey + JWT) ----------
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t"
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}

# ---------- service_role (test setup only) ----------
svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
}
svc_rpc() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" -d "$2"
}
```

### Key differences from psql-based testing

| Aspect | psql | curl (Dart emulation) |
|--------|------|----------------------|
| Auth | Direct connection | JWT token in Authorization header |
| RLS | Bypassed by postgres user | Enforced (anon/authenticated role) |
| Permissions | Superuser | Limited to role grants |
| Response format | SQL tables | JSON arrays/objects/errors |
| Error codes | PostgreSQL codes | PostgREST HTTP codes + JSON |

### Response interpretation

PostgREST returns different error patterns depending on where the block happens:

| Response | Meaning | Security Level |
|----------|---------|----------------|
| `42501` / `permission denied` | Table-level grant missing | ✅ Data protected |
| `PGRST204` / empty `[]` | RLS filtered all rows | ✅ Data protected (no leak) |
| Valid JSON row | Operation succeeded | ❌ Data leak |

Test for **both** `42501` and `PGRST204` as valid denial patterns:

```bash
resp=$(anon_get "users?limit=1")
if echo "$resp" | grep -qE '(42501|permission denied|violates rls|PGRST204)'; then
  ok "anon SELECT users — denied"
elif [ "$resp" = "[]" ]; then
  ok "anon SELECT users — denied (empty)"
else
  nok "anon SELECT users — possible leak"
fi
```

### Test setup pattern

```bash
# 1. Create users via admin API (emulates sign-up)
curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"test@samay.test","password":"Pass1234!","email_confirm":true,"id":"<uuid>"}'

# 2. Insert user row into public.users (admin API does not auto-create it)
svc_post "users" '{"id":"<uuid>","username":"test"}'

# 3. Sign in to get JWT (emulates client login)
TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: <ANON_KEY>" -H "Content-Type: application/json" \
  -d '{"email":"test@samay.test","password":"Pass1234!"}' \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

# 4. Seed data via service_role (bypasses RLS for setup only)
svc_post "groups" '{"id":"<uuid>","name":"Test Group","created_by_user_id":"<uuid>"}'

# 5. Run assertions as anon or authenticated user
resp=$(auth_get "$TOKEN" "users?select=id&id=eq.<uuid>")
```

---

## Running Tests

```bash
# Flutter unit/widget
make flutter-test

# Flutter modular integration (integration_test/ — landed, I-01)
flutter test integration_test/auth_flow_test.dart -d <device>   # per module
bash integration_test/runner.sh                                  # whole suite (hermetic by default)

# Backend: reset DB to clean state (applies all migrations + seed)
make supabase-docker-start
make supabase-docker-reset

# Run a backend integration test
bash test/opt-001-rls-security.sh

# Run all backend tests
bash test/run_all_backend.sh

# Go tests
go test ./...

# SQL schema tests (pgTAP)
supabase db test    # requires the stack + supabase CLI project

# Everything: Flutter + Go
make test
```

> The opt-tests default to `SUPABASE_URL=http://127.0.0.1:54386` (Kong, Samay's
> approved API port) and embed local dev keys. Override via `SUPABASE_URL`,
> `ANON_KEY`, `SERVICE_KEY` env vars to point at another stack.

---

## File Naming Convention

```
test/opt-NNN-description.sh     # Optimization integration test (curl-based)
test/features/<feature>_test.dart   # Flutter widget/unit tests per feature
test/router/, test/providers/, test/services/, test/theme/, test/widgets/  # per-layer tests
integration_test/<module>_flow_test.dart  # Flutter modular integration (landed — see integration_test/README.md; register new flows in runner.sh)
supabase/tests/schema_test.sql   # pgTAP schema assertions
```

Each curl test file is self-contained: creates its own test users, seeds data, runs assertions, and reports pass/fail. Tests use `exit 0` on success, `exit 1` on failure.

---

## What These Tests Cover

- **Security** — anon access, RLS policies, SECURITY DEFINER functions, row-level permissions
- **Correctness** — RPCs return expected data, cross-user visibility
- **Edge cases** — group membership visibility, authenticated vs unauthenticated access
- **Schema** — RLS policies correct, public vs protected tables

Backend opt-test coverage by surface (I-76, 2026-08-10):

- **opt-002 (events)** — full-field `juerga` insert via service role (pool/cap/
  remainder/join_mode/location/status), `check_casual_no_preshards` rejection
  (`casual` + pool > 0 → 23514), `dynamic_qr_enabled` auto-set by the
  `set_dynamic_qr_enabled` trigger (pool > 0 → true, INSERT and UPDATE
  branches), `events_read_access` (non-member cannot see group-scoped events;
  public events readable by anon), `ep_insert_promotor` creator branch,
  `events_update_promotor` (promotor can update, non-promotor filtered).
- **opt-003 (chat)** — `chats` rows for `group`/`event` types, opaque base64url
  E2EE envelope storage in `messages.content` (server never inspects it,
  E2EE-ARCHITECTURE §6.6), `messages_read_participant` (member/promotor reads,
  non-member `[]`), `message_cap` below-cap retention (cap semantics + trigger
  existence asserted in pgTAP — a trigger function is not callable via RPC).
- **opt-004 (photos)** — `event_photos` row + `storage_path` round-trip,
  `eph_read_access` (member reads, non-member/anon `[]`),
  `photo_likes_count_trigger` (`likes_count` = 2 after 2 likes),
  `UNIQUE (photo_id, user_id)` duplicate-like rejection (23505),
  `epl_insert_own` access check (no likes on invisible events).
- **opt-006 (E2EE)** — `e2ee_identity_keys` bundle publish, `fetch_prekey_bundle`
  via authenticated peer: bundle shape, atomic one-time-prekey consumption
  (2 → 1 → 0, audit list grows), exhausted-pool `one_time_prekey: null`
  (no OPK reuse), anon denied (EXECUTE revoked from PUBLIC), own-row RLS.
- **opt-005 (seed-dev)** — static gate (files, `bash -n`, UUID uniqueness,
  table/column/constraint/enum parity, Makefile + SEED_DEV semantics); runs
  without a stack.

Tests do **not** cover:
- UI rendering (handled by Flutter widget tests)
- Device-level features (GPS, sensors, file system)
- Performance benchmarks (run separately)
- Storage API signed URLs / object uploads (bucket-dependent — the opt-tests
  assert the `event_photos`/`storage_path` DB contract only)
