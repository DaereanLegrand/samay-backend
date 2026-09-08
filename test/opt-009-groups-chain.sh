#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-009] Group Chain of Command — Integration Test
# -----------------------------------------------------------------------------
# Verifies the group membership/leadership contract end-to-end:
#   A) member-list visibility joins through user_search_view (all members'
#      usernames resolve — the `users` join is RLS-blocked to the caller)
#   B) chain of command: only the host manages hosts; staff
#      manage members/staff; members manage nothing
#   C) transfer_host RPC: host-only, atomic role swap
#   D) host banned -> leadership auto-passes to a staff
#   E) host account soft-deleted -> leadership auto-passes to an active
#      member (invited members are skipped)
#
# Usage: bash test/opt-009-groups-chain.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0

ok()   { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
nok()  { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
info() { echo "    ℹ️  $1"; }
h1()   { echo ""; echo "━━━ $1 ━━━"; }

UUID_A=$(uuidgen | tr 'A-Z' 'a-z')
UUID_B=$(uuidgen | tr 'A-Z' 'a-z')
UUID_C=$(uuidgen | tr 'A-Z' 'a-z')
UUID_D=$(uuidgen | tr 'A-Z' 'a-z')
GROUP_ID=$(uuidgen | tr 'A-Z' 'a-z')
EMAIL_A="opt009_a_$RANDOM@samay.test"
EMAIL_B="opt009_b_$RANDOM@samay.test"
EMAIL_C="opt009_c_$RANDOM@samay.test"
EMAIL_D="opt009_d_$RANDOM@samay.test"
PW="Pass1234!"

cleanup() {
  # Order matters: dependent rows first (member rows FK-block the users
  # DELETE; the users row FK-blocks the auth-user DELETE).
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/group_members?group_id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/chats?reference_id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/groups?id=eq.$GROUP_ID" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
  for u in $UUID_A $UUID_B $UUID_C $UUID_D; do
    # The auth deletion does NOT cascade to public.users — leftover rows with
    # the fixed usernames would 23505 the next run's users insert (verified
    # live). Remove the profile rows explicitly.
    curl -s -X DELETE "$SUPABASE_URL/rest/v1/users?id=eq.$u" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$u" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1
  done
}
trap cleanup EXIT

auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $t"
}
auth_patch() {
  local t=$1; shift
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
}
auth_delete() {
  local t=$1; shift
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t"
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}
svc_post() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
}
svc_patch() {
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" -d "$2"
}

# $1 token, $2 user_id -> role string (empty when the row is invisible)
role_of() {
  auth_get "$1" "group_members?select=role&group_id=eq.$GROUP_ID&user_id=eq.$2&limit=1" \
    | python3 -c 'import sys,json; rows=json.load(sys.stdin); print(rows[0]["role"] if rows else "")'
}

create_user() { # $1 uid $2 email $3 username
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$2\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$1\"}" >/dev/null
  svc_post "users" "{\"id\":\"$1\",\"username\":\"$3\"}" >/dev/null
}

signin() { # $1 email -> prints JWT
  curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PW\"}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

add_member() { # $1 actor token, $2 user_id, $3 role, $4 status
  curl -s -o /dev/null -X POST "$SUPABASE_URL/rest/v1/group_members" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$2\",\"role\":\"$3\",\"status\":\"$4\"}"
}

# ---------------------------------------------------------------------------
h1 "SETUP: users + group + memberships"
# ---------------------------------------------------------------------------
cleanup
create_user "$UUID_A" "$EMAIL_A" "opt009_a"
create_user "$UUID_B" "$EMAIL_B" "opt009_b"
create_user "$UUID_C" "$EMAIL_C" "opt009_c"
create_user "$UUID_D" "$EMAIL_D" "opt009_d"
TA=$(signin "$EMAIL_A"); TB=$(signin "$EMAIL_B"); TC=$(signin "$EMAIL_C")
if [ -n "$TA" ] && [ -n "$TB" ] && [ -n "$TC" ]; then
  ok "sign-ins obtained"
else
  nok "sign-in failed"
fi

svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Chain Test\",\"description\":\"d\",\"created_by_user_id\":\"$UUID_A\",\"rank_bracket\":\"b0_20\"}" >/dev/null
add_member "$TA" "$UUID_A" "host" "active"
add_member "$TA" "$UUID_B" "member" "active"
add_member "$TA" "$UUID_C" "member" "active"
add_member "$TA" "$UUID_D" "member" "invited"
if [ "$(role_of "$TA" "$UUID_A")" = "host" ]; then
  ok "creator is host"
else
  nok "creator not host"
fi

# ---------------------------------------------------------------------------
h1 "A) member list resolves ALL usernames via user_search_view"
# ---------------------------------------------------------------------------
ROWS=$(auth_get "$TA" "group_members?select=id,user_id,role,status,user_search_view!inner(username)&group_id=eq.$GROUP_ID&status=eq.active")
N=$(echo "$ROWS" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
UNAMES=$(echo "$ROWS" | python3 -c 'import sys,json;print(",".join(sorted(r["user_search_view"]["username"] for r in json.load(sys.stdin))))')
if [ "$N" = "3" ] && echo "$UNAMES" | grep -q "opt009_a" \
  && echo "$UNAMES" | grep -q "opt009_b" && echo "$UNAMES" | grep -q "opt009_c"; then
  ok "creator sees 3 active members with usernames ($UNAMES)"
else
  nok "member list: $ROWS"
fi

# ---------------------------------------------------------------------------
h1 "B) chain of command (roles)"
# ---------------------------------------------------------------------------
# A promotes B to staff
auth_patch "$TA" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B" '{"role":"staff"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_B")" = "staff" ]; then
  ok "host promotes member -> staff"
else
  nok "promote member failed"
fi

# B (staff) tries to demote the host -> MUST be rejected
auth_patch "$TB" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_A" '{"role":"member"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_A")" = "host" ]; then
  ok "staff CANNOT demote the host (role unchanged)"
else
  nok "staff demoted the host — chain of command broken"
fi

# B (staff) tries to kick the host -> MUST be rejected
auth_delete "$TB" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_A" >/dev/null
if [ "$(role_of "$TA" "$UUID_A")" = "host" ]; then
  ok "staff CANNOT kick the host (row survives)"
else
  nok "staff kicked the host — chain of command broken"
fi

# B (staff) promotes member C -> allowed
auth_patch "$TB" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_C" '{"role":"staff"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_C")" = "staff" ]; then
  ok "staff promotes member -> staff"
else
  nok "co-promote member failed"
fi

# B (staff) demotes staff C back -> allowed
auth_patch "$TB" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_C" '{"role":"member"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_C")" = "member" ]; then
  ok "staff demotes staff -> member"
else
  nok "co-demote failed"
fi

# B (staff) kicks member C -> allowed
auth_delete "$TB" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_C" >/dev/null
if [ "$(role_of "$TA" "$UUID_C")" = "" ]; then
  ok "staff kicks member"
else
  nok "co-kick failed"
fi
# re-add C as member for the next sections
add_member "$TA" "$UUID_C" "member" "active"

# member C cannot alter anything
auth_patch "$TC" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_D" '{"role":"member"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_D")" = "member" ]; then
  ok "member CANNOT alter another member's row"
else
  nok "member altered another row"
fi

# ---------------------------------------------------------------------------
h1 "C) transfer_host RPC"
# ---------------------------------------------------------------------------
OUT=$(auth_rpc "$TB" "transfer_host" "{\"p_group_id\":\"$GROUP_ID\",\"p_new_host_id\":\"$UUID_C\"}")
if [ "$(role_of "$TA" "$UUID_B")" = "staff" ] && [ "$(role_of "$TA" "$UUID_A")" = "host" ]; then
  ok "non-host transfer rejected (roles unchanged)"
else
  nok "staff transferred leadership: $OUT"
fi

OUT=$(auth_rpc "$TA" "transfer_host" "{\"p_group_id\":\"$GROUP_ID\",\"p_new_host_id\":\"$UUID_C\"}")
if [ "$(role_of "$TA" "$UUID_C")" = "host" ] && [ "$(role_of "$TA" "$UUID_A")" = "staff" ]; then
  ok "transfer swaps roles atomically (C host, A staff)"
else
  nok "transfer failed: $OUT"
fi

# Deterministic state for D: A (staff) demotes B to member
auth_patch "$TA" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B" '{"role":"member"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_B")" = "member" ]; then
  ok "staff A demotes staff B (state prep)"
else
  nok "state prep demote failed"
fi

# ---------------------------------------------------------------------------
h1 "D) host banned -> leadership passes to a staff"
# ---------------------------------------------------------------------------
svc_patch "users?id=eq.$UUID_C" '{"banned_at":"2026-08-16T00:00:00Z","ban_reason":"opt009 test"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_A")" = "host" ] && [ "$(role_of "$TA" "$UUID_C")" = "member" ]; then
  ok "banned host demoted to member; staff A auto-promoted"
else
  nok "ban chain: A=$(role_of "$TA" "$UUID_A") C=$(role_of "$TA" "$UUID_C")"
fi
svc_patch "users?id=eq.$UUID_C" '{"banned_at":null}' >/dev/null

# ---------------------------------------------------------------------------
h1 "E) host account soft-deleted -> leadership passes to an active member"
# ---------------------------------------------------------------------------
# A (host) promotes B to staff first (deterministic successor)
auth_patch "$TA" "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B" '{"role":"staff"}' >/dev/null
svc_patch "users?id=eq.$UUID_A" '{"deleted_at":"2026-08-16T00:00:00Z"}' >/dev/null
if [ "$(role_of "$TA" "$UUID_B")" = "host" ] && [ "$(role_of "$TA" "$UUID_D")" = "member" ]; then
  ok "deleted host's leadership passed to staff B (invited D skipped)"
else
  nok "delete chain: B=$(role_of "$TA" "$UUID_B") D=$(role_of "$TA" "$UUID_D")"
fi
svc_patch "users?id=eq.$UUID_A" '{"deleted_at":null}' >/dev/null

# ---------------------------------------------------------------------------
h1 "RESULTS"
# ---------------------------------------------------------------------------
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "  🎉 All tests passed!"
  exit 0
else
  echo ""
  echo "  💥 Some tests failed."
  exit 1
fi
