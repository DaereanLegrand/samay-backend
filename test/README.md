# Samay — Backend Testing Guide

This guide covers the **backend test matrix** of the Samay repo: Go unit
tests, curl opt-tests, and SQL pgTAP. For the one-paragraph overview see the
root [`README.md`](../README.md#testing-summary).

## Testing architecture (directive 2026-08-31)

**Testing is reserved for the backend, or per task there are NO integration
tests.** The Flutter/Dart test trees were deleted — `test/*.dart` (unit/widget/
provider/router/theme suites), `integration_test/` (all flows + `runner.sh`),
`test_driver/` — and must NOT be recreated. There is no `make flutter-test` /
`make test-file` / `make test-feature` / `make test-integration`.

## The Test Matrix

| Layer | Where | Command | Notes |
|-------|-------|---------|-------|
| **Backend (curl opt-tests)** | `test/opt-*.sh` | `bash test/run_all_backend.sh` | Self-contained curl scripts that hit Supabase REST/Auth exactly like the Dart client (see "How to Test Backend Changes" below). Run against Kong at `http://127.0.0.1:54386`. Prerequisites: `make supabase-docker-start`, `make supabase-docker-reset`. Suite: `opt-001` RLS security · `opt-002` event lifecycle (fields/CHECK/QR-trigger/RLS) · `opt-003` chat + E2EE envelope contract · `opt-004` photo gallery contract · `opt-005` seed-dev static gate (no stack) · `opt-006` `fetch_prekey_bundle` contract (OPK consumption) · `opt-007` compose/config static gate (no stack) · `opt-008` Makefile/scratch-repo static gate (no stack) · `opt-009` groups chain (invites/roles/chain-of-command) · `opt-010` groups chat (E2EE sender-key distribution + read receipts) · `opt-011` groups reads (group chat read paths) · `opt-012` friendships · `opt-013` user ranking · `opt-014` profile-RPC lockdown · `opt-015` search RPC (rate limits) · `opt-016` profile-RPC lockdown static · `opt-018` minigame play flow · `opt-019` minigame lobby (ready map, creator-only Start/remove, roster) · `opt-020` minigame voting · `opt-021` minigame play v2 · `opt-022` minigame round-key request · `opt-023` minigame reaction event · `opt-024` events capacity (entitlement-tier attendee cap). All auto-discovered by the `test/opt-*.sh` glob in the runner. |
| **Go (admin CLI + ops)** | `*_test.go` | `go test ./...` | 188 tests: CLI flag/validation behavior (cobra) and `internal/ops` business logic against `httptest` servers. Run via `make test` together with the static gates. |
| **SQL (pgTAP)** | `supabase/tests/schema_test.sql` | `supabase db test` | **plan(871)** assertions (both stacks, mirrored byte-identical): extensions, enums, tables, triggers, RPCs, RLS policy sets per table, seed data, minigame play engine + partida names + partida lobby (Section 49g — ready map, `set_minigame_ready`/`get_minigame_participants`/`remove_minigame_participant`, creator-gated init, `minigame_sessions` realtime), `get_friend_profiles` (batched accepted-friend profiles), `202_minigame_play_v2` round-key hardening. New migrations must extend this file. |
| **Manual end-user QA** | `test_runner.sh` (root) | `bash test_runner.sh` | gum-based interactive runner — 55 cases across auth → leaderboard (Phases 00–04). Wipes local user data, records results to a timestamped markdown file. Not part of the automated TDD suite; used for pre-release device testing. |

**Golden rule:** every backend change ships a test at its layer. Go
`*_test.go`, curl opt-test in `test/opt-NNN-*.sh` (+ registered by
`run_all_backend.sh`), SQL pgTAP in `supabase/tests/schema_test.sql`.

---

## Workflow

Every optimization or bug fix follows this cycle:

```
1. WRITE TEST   →  curl script that verifies expected correct behavior
2. IMPLEMENT    →  migration / code change
3. VERIFY       →  run the opt-test against the stack; pgTAP for schema
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
# Backend: reset DB to clean state (applies all migrations + seed)
make supabase-docker-start
make supabase-docker-reset

# Run a backend integration test
bash test/opt-001-rls-security.sh

# Run all backend tests
bash test/run_all_backend.sh

# Backend-test keys: sourced automatically from the RUNNING stack's
# gitignored env files by `test/dev_env.sh` (precedence: explicit env >
# supabase-testing/.env > supabase/.env > supabase*/.env.local). No key
# literals are committed anywhere; override via ANON_KEY/SERVICE_KEY env vars.
# tools/check_secrets.sh fails if any local secret value leaks into a tracked file.

# Go tests
go test ./...

# SQL schema tests (pgTAP)
supabase db test    # requires the stack + supabase CLI project

# Everything (no stack needed): Go + backend static gates
make test
```

> The opt-tests default to `SUPABASE_URL=http://127.0.0.1:54386` (Kong, Samay's
> approved API port) and embed local dev keys. Override via `SUPABASE_URL`,
> `ANON_KEY`, `SERVICE_KEY` env vars to point at another stack.

---

## File Naming Convention

```
test/opt-NNN-description.sh     # Backend integration test (curl-based)
supabase/tests/schema_test.sql  # pgTAP schema assertions
internal/**/*_test.go           # Go unit tests (admin CLI + ops logic)
```

Each curl test file is self-contained: creates its own test users, seeds data,
runs assertions, and reports pass/fail. Tests use `exit 0` on success,
`exit 1` on failure.

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
  public events readable by anon), `ep_insert_host` creator branch,
  `events_update_host` (host can update, non-host filtered).
- **opt-003 (chat)** — `chats` rows for `group`/`event` types, opaque base64url
  E2EE envelope storage in `messages.content` (server never inspects it,
  E2EE-ARCHITECTURE §6.6), `messages_read_participant` (member/host reads,
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
- UI rendering (the Flutter/Dart test trees were deleted — directive 2026-08-31)
- Device-level features (GPS, sensors, file system)
- Performance benchmarks (run separately)
- Storage API signed URLs / object uploads (bucket-dependent — the opt-tests
  assert the `event_photos`/`storage_path` DB contract only)
