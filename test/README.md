# Samay — Testing Guide

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
# Reset DB to clean state (applies all migrations + seed)
make supabase-reset

# Run a backend integration test
bash test/opt-001-rls-security.sh

# Run all tests
bash test/run_all_backend.sh
```

---

## File Naming Convention

```
test/opt-NNN-description.sh     # Optimization integration test (curl-based)
```

Each test file is self-contained: creates its own test users, seeds data, runs assertions, and reports pass/fail. Tests use `exit 0` on success, `exit 1` on failure.

---

## What These Tests Cover

- **Security** — anon access, RLS policies, SECURITY DEFINER functions, row-level permissions
- **Correctness** — RPCs return expected data, cross-user visibility
- **Edge cases** — group membership visibility, authenticated vs unauthenticated access
- **Schema** — RLS policies correct, public vs protected tables

Tests do **not** cover:
- UI rendering (handled by Flutter widget tests)
- Device-level features (GPS, sensors, file system)
- Performance benchmarks (run separately)
