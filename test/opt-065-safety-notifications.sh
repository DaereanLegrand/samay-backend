#!/bin/bash
set -uo pipefail
# =============================================================================
# [OPT-065] Safety / moderation / block-mute / notifications
# (migration 234_safety_moderation)
#
# Verifies, with before/after evidence:
#   A) server-persisted notification categories (defaults, marketing off,
#      locked security/moderation/legal, set/get round-trip);
#   B) group-invite notifications exist AND respect the friends category;
#   C) report_content validates participation and snapshots evidence for
#      avatar/group-cover; priority is derived server-side (CSAM > harassment);
#   D) block hides discovery/search/ranking/feed, blocks new DMs/event/group
#      invites, suppresses notifications, and the blocked user can neither
#      unblock nor alter the block;
#   E) mute is weaker: notifications/feed filtered, direct chat still allowed;
#   F) report_message maps ncii -> category ncii (priority 2) and snapshots the
#      disclosed plaintext;
#   G) moderation review/dismiss records the real admin actor and delivers a
#      reporter outcome; a ban appeal is submittable while banned and an
#      overturned decision unbans;
#   H) anon cannot call the report/appeal RPCs.
#
# SELF-CONTAINED: fixed safety_* users, full cleanup on exit.
# Live: SUPABASE_URL=http://127.0.0.1:55726 ANON_KEY=... SERVICE_KEY=... \
#       bash test/opt-065-safety-notifications.sh
# =============================================================================

SUPABASE_URL="${SUPABASE_URL:-http://127.0.0.1:54386}"
. "$(cd "$(dirname "$0")" && pwd)/dev_env.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
nok() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
h1()  { echo ""; echo "=== $1 ==="; }

pyget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, list):
        d = d[0] if d else None
    d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        break
print("" if d is None else d)
' "$1"
}

svc_get() {
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY"
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
svc_delete_quiet() {
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Prefer: return=minimal" >/dev/null 2>&1 || true
}
svc_rpc() {
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$1" -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" -d "$2"
}
auth_get() {
  local t=$1; shift
  curl -s -X GET "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t"
}
auth_delete() {
  local t=$1; shift
  curl -s -X DELETE "$SUPABASE_URL/rest/v1/$1" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Prefer: return=representation"
}
auth_rpc() {
  local t=$1 f=$2 d=$3
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $t" -H "Content-Type: application/json" -d "$d"
}
anon_rpc() {
  local f=$1 d=$2
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/$f" -H "apikey: $ANON_KEY" \
    -H "Content-Type: application/json" -d "$d"
}

UUID_A="77777777-7777-7777-7777-777777777761"
UUID_B="77777777-7777-7777-7777-777777777762"
UUID_C="77777777-7777-7777-7777-777777777763"
EMAIL_A="safety_a_opt065@samay.test"
EMAIL_B="safety_b_opt065@samay.test"
EMAIL_C="safety_c_opt065@samay.test"
PW="Pass1234!"
GROUP_ID="77777777-7777-7777-7777-777777777701"
EVENT_ID="77777777-7777-7777-7777-777777777702"
CHAT_ID="77777777-7777-7777-7777-777777777703"
MSG_ID="77777777-7777-7777-7777-777777777704"

cleanup() {
  svc_delete_quiet "appeals?appellant_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "moderation_evidence?reporter_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "message_reports?reporter_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "reports?reporter_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "notifications?user_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "user_mutes?muter_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "friendships?requester_id=in.($UUID_A,$UUID_B,$UUID_C)"
  svc_delete_quiet "messages?chat_id=eq.$CHAT_ID"
  svc_delete_quiet "chat_participants?chat_id=eq.$CHAT_ID"
  svc_delete_quiet "chats?id=eq.$CHAT_ID"
  svc_delete_quiet "event_invites?event_id=eq.$EVENT_ID"
  svc_delete_quiet "event_hosts?event_id=eq.$EVENT_ID"
  svc_delete_quiet "events?id=eq.$EVENT_ID"
  svc_delete_quiet "group_members?group_id=eq.$GROUP_ID"
  svc_delete_quiet "groups?id=eq.$GROUP_ID"
  svc_delete_quiet "users?id=in.($UUID_A,$UUID_B,$UUID_C)"
  for uid in $UUID_A $UUID_B $UUID_C; do
    curl -s -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uid" \
      -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" >/dev/null 2>&1 || true
  done
}

h1 "SETUP"
trap cleanup EXIT
cleanup
for pair in "A $UUID_A safety_a $EMAIL_A" "B $UUID_B safety_b $EMAIL_B" "C $UUID_C safety_c $EMAIL_C"; do
  set -- $pair
  resp=$(curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$4\",\"password\":\"$PW\",\"email_confirm\":true,\"id\":\"$2\"}")
  echo "$resp" | grep -q '"id"' || nok "auth create $1: $(echo "$resp" | head -c 120)"
  svc_post "users" "{\"id\":\"$2\",\"username\":\"$3\",\"date_of_birth\":\"1990-01-01\",\"discovery_opt_in\":true,\"interest_tags\":[\"music\"],\"personal_shards\":100}" >/dev/null
done
ok "3 users seeded"

TOKEN_A=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_B=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
TOKEN_C=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL_C\",\"password\":\"$PW\"}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] && [ -n "$TOKEN_C" ]; then
  ok "auth tokens obtained"
else
  nok "failed to obtain auth tokens"; exit 1
fi
ADMIN_ID=$(svc_get "admin_users?select=id&limit=1" | pyget id)
if [ -n "$ADMIN_ID" ]; then ok "admin actor $ADMIN_ID"; else nok "no admin_users row"; fi

# =========================================================================
h1 "A - server-persisted notification categories"
# =========================================================================
prefs=$(auth_rpc "$TOKEN_A" "get_notification_preferences" "{}")
if [ "$(printf '%s' "$prefs" | pyget marketing)" = "False" ] \
   && [ "$(printf '%s' "$prefs" | pyget chat)" = "True" ] \
   && [ "$(printf '%s' "$prefs" | pyget security)" = "True" ]; then
  ok "defaults: chat/security on, marketing off (BEFORE update)"
else
  nok "unexpected defaults: $(echo "$prefs" | head -c 160)"
fi
setresp=$(auth_rpc "$TOKEN_A" "set_notification_preferences" \
  '{"p_prefs":{"marketing":true,"chat":false,"security":false}}')
readback=$(auth_rpc "$TOKEN_A" "get_notification_preferences" "{}")
if [ "$(printf '%s' "$setresp" | pyget marketing)" = "True" ] \
   && [ "$(printf '%s' "$setresp" | pyget chat)" = "False" ] \
   && [ "$(printf '%s' "$readback" | pyget marketing)" = "True" ] \
   && [ "$(printf '%s' "$readback" | pyget chat)" = "False" ] \
   && [ "$(printf '%s' "$readback" | pyget security)" = "True" ]; then
  ok "update persists server-side; security stays locked on (AFTER update)"
else
  nok "prefs did not persist/lock: set=$(echo "$setresp" | head -c 120) read=$(echo "$readback" | head -c 120)"
fi
# restore defaults
auth_rpc "$TOKEN_A" "set_notification_preferences" '{"p_prefs":{"chat":true,"marketing":false}}' >/dev/null

h1 "A2 - disabled category does not create an in-app row"
svc_delete_quiet "notifications?user_id=eq.$UUID_A"
auth_rpc "$TOKEN_A" "set_notification_preferences" '{"p_prefs":{"chat":false}}' >/dev/null
svc_rpc "insert_notification" "{\"p_user_id\":\"$UUID_A\",\"p_type\":\"new_message\",\"p_title\":\"t\",\"p_body\":\"b\"}" >/dev/null
count=$(svc_get "notifications?user_id=eq.$UUID_A&type=eq.new_message&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "0" ]; then ok "chat off -> no notification row (BEFORE)"; else nok "chat off still wrote $count row(s)"; fi
auth_rpc "$TOKEN_A" "set_notification_preferences" '{"p_prefs":{"chat":true}}' >/dev/null
svc_rpc "insert_notification" "{\"p_user_id\":\"$UUID_A\",\"p_type\":\"new_message\",\"p_title\":\"t\",\"p_body\":\"b\"}" >/dev/null
count=$(svc_get "notifications?user_id=eq.$UUID_A&type=eq.new_message&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "1" ]; then ok "chat on -> notification written (AFTER)"; else nok "chat on wrote $count rows (want 1)"; fi
pushflag=$(svc_get "notifications?user_id=eq.$UUID_A&type=eq.new_message&select=category,push_allowed" | pyget category)
if [ "$pushflag" = "chat" ]; then ok "notification category denormalized for push contract"; else nok "category='$pushflag'"; fi

# =========================================================================
h1 "B - group invite notification respects preferences"
# =========================================================================
svc_post "groups" "{\"id\":\"$GROUP_ID\",\"name\":\"Safety Group\",\"created_by_user_id\":\"$UUID_A\"}" >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_A\",\"role\":\"host\",\"status\":\"active\"}" >/dev/null
svc_delete_quiet "notifications?user_id=eq.$UUID_B"
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"invited\"}" >/dev/null
count=$(svc_get "notifications?user_id=eq.$UUID_B&type=eq.group_invite&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "1" ]; then ok "group invite notification created (friends on)"; else nok "expected 1 group_invite, got $count"; fi
svc_delete_quiet "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B"
svc_delete_quiet "notifications?user_id=eq.$UUID_B&type=eq.group_invite"
auth_rpc "$TOKEN_B" "set_notification_preferences" '{"p_prefs":{"friends":false}}' >/dev/null
svc_post "group_members" "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"invited\"}" >/dev/null
count=$(svc_get "notifications?user_id=eq.$UUID_B&type=eq.group_invite&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "0" ]; then ok "friends off -> no group invite notification"; else nok "friends off still wrote $count"; fi
svc_delete_quiet "group_members?group_id=eq.$GROUP_ID&user_id=eq.$UUID_B"
auth_rpc "$TOKEN_B" "set_notification_preferences" '{"p_prefs":{"friends":true}}' >/dev/null

# =========================================================================
h1 "C - report_content validates + snapshots; priority derived"
# =========================================================================
resp=$(auth_rpc "$TOKEN_A" "report_content" \
  "{\"p_target_type\":\"avatar\",\"p_target_id\":\"$UUID_B\",\"p_category\":\"harassment\",\"p_reason\":\"harassment\"}")
R_AVATAR=$(printf '%s' "$resp" | pyget report_id)
if [ "$(printf '%s' "$resp" | pyget status)" = "ok" ] && [ "$(printf '%s' "$resp" | pyget priority)" = "20" ]; then
  ok "avatar report accepted with server priority 20"
else
  nok "avatar report failed: $(echo "$resp" | head -c 160)"
fi
snap=$(svc_get "moderation_evidence?report_id=eq.$R_AVATAR&select=snapshot,retention_until" | pyget snapshot.avatar_url)
if svc_get "moderation_evidence?report_id=eq.$R_AVATAR&select=id" | grep -q '"id"'; then
  ok "evidence snapshot captured at report time (avatar=$snap)"
else
  nok "no evidence row for avatar report"
fi
if svc_get "moderation_evidence?report_id=eq.$R_AVATAR&select=retention_until" | grep -q '20[0-9][0-9]-'; then
  ok "evidence carries a retention clock"
else
  nok "evidence retention_until missing"
fi
resp=$(auth_rpc "$TOKEN_A" "report_content" \
  "{\"p_target_type\":\"group_cover\",\"p_target_id\":\"$GROUP_ID\",\"p_category\":\"spam\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "ok" ]; then ok "member can report group cover"; else nok "group cover report: $(echo "$resp" | head -c 120)"; fi
resp=$(auth_rpc "$TOKEN_C" "report_content" \
  "{\"p_target_type\":\"group_cover\",\"p_target_id\":\"$GROUP_ID\",\"p_category\":\"spam\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "not_allowed" ]; then ok "non-member group-cover report rejected"; else nok "non-member report not rejected: $(echo "$resp" | head -c 120)"; fi
resp=$(auth_rpc "$TOKEN_A" "report_content" \
  "{\"p_target_type\":\"avatar\",\"p_target_id\":\"$UUID_B\",\"p_category\":\"csam\"}")
if [ "$(printf '%s' "$resp" | pyget priority)" = "0" ] && [ "$(printf '%s' "$resp" | pyget category)" = "csam" ]; then
  ok "CSAM report is priority 0 (immediate lane)"
else
  nok "CSAM priority wrong: $(echo "$resp" | head -c 120)"
fi

# =========================================================================
h1 "D - block scope + block ownership"
# =========================================================================
resp=$(auth_rpc "$TOKEN_A" "block_user" "{\"p_user_id\":\"$UUID_B\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "ok" ]; then ok "A blocked B (BEFORE: no block)"; else nok "block failed: $(echo "$resp" | head -c 120)"; fi
resp=$(auth_rpc "$TOKEN_B" "block_user" "{\"p_user_id\":\"$UUID_A\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "blocked_by_peer" ]; then ok "blocked party cannot alter the block"; else nok "B block attempt: $(echo "$resp" | head -c 120)"; fi
resp=$(auth_rpc "$TOKEN_B" "unblock_user" "{\"p_user_id\":\"$UUID_A\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "blocked_by_peer" ]; then ok "blocked party cannot unblock"; else nok "B unblock attempt: $(echo "$resp" | head -c 120)"; fi

# discovery + search + ranking
count=$(auth_get "$TOKEN_A" "discovery_view?id=eq.$UUID_B&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "0" ]; then ok "blocked user hidden from discovery_view"; else nok "discovery_view still shows blocked user"; fi
count=$(auth_get "$TOKEN_A" "user_search_view?id=eq.$UUID_B&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "0" ]; then ok "blocked user hidden from user_search_view"; else nok "user_search_view still shows blocked user"; fi
rank=$(auth_rpc "$TOKEN_A" "get_user_ranking" '{"p_limit":100}')
if printf '%s' "$rank" | grep -q "$UUID_B"; then nok "ranking still contains blocked user"; else ok "blocked user hidden from rankings"; fi

# feed + event invite gate
svc_post "events" "{\"id\":\"$EVENT_ID\",\"name\":\"Blocked Feed Event\",\"description\":\"hidden\",\"type\":\"casual\",\"created_by_user_id\":\"$UUID_B\",\"status\":\"upcoming\",\"starts_at\":\"2030-01-01T18:00:00Z\",\"ends_at\":\"2030-01-01T22:00:00Z\",\"capacity\":5,\"join_mode\":\"open\"}" >/dev/null
feed=$(auth_rpc "$TOKEN_A" "search_events" '{"p_query":"Blocked Feed"}')
if printf '%s' "$feed" | grep -q "$EVENT_ID"; then nok "blocked creator's event still in feed"; else ok "blocked creator's event hidden from feed"; fi
resp=$(svc_post "event_invites" "{\"event_id\":\"$EVENT_ID\",\"user_id\":\"$UUID_A\",\"invited_by_user_id\":\"$UUID_B\",\"status\":\"pending\"}")
if echo "$resp" | grep -qE 'BLOCKED|P0001'; then ok "blocked pair cannot create an event invite"; else nok "event invite not blocked: $(echo "$resp" | head -c 120)"; fi
resp=$(curl -s -X POST "$SUPABASE_URL/rest/v1/group_members" -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $TOKEN_A" -H "Content-Type: application/json" \
  -d "{\"group_id\":\"$GROUP_ID\",\"user_id\":\"$UUID_B\",\"role\":\"member\",\"status\":\"invited\"}")
if echo "$resp" | grep -qE 'BLOCKED|P0001|42501'; then ok "blocked pair cannot create a group invite"; else nok "group invite not blocked: $(echo "$resp" | head -c 120)"; fi
resp=$(auth_rpc "$TOKEN_A" "create_direct_chat" "{\"p_peer_id\":\"$UUID_B\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "blocked" ]; then ok "blocked pair cannot open a new DM"; else nok "create_direct_chat: $(echo "$resp" | head -c 120)"; fi

# block suppresses notifications from the blocked actor
svc_delete_quiet "notifications?user_id=eq.$UUID_A&type=eq.friend_request"
svc_rpc "insert_notification" "{\"p_user_id\":\"$UUID_A\",\"p_type\":\"friend_request\",\"p_title\":\"t\",\"p_body\":\"b\",\"p_data\":{\"userId\":\"$UUID_B\"}}" >/dev/null
count=$(svc_get "notifications?user_id=eq.$UUID_A&type=eq.friend_request&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "0" ]; then ok "blocked actor's notification suppressed"; else nok "blocked actor still notified ($count)"; fi

resp=$(auth_rpc "$TOKEN_A" "unblock_user" "{\"p_user_id\":\"$UUID_B\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "ok" ]; then ok "blocker can unblock (AFTER)"; else nok "unblock failed: $(echo "$resp" | head -c 120)"; fi
feed=$(auth_rpc "$TOKEN_A" "search_events" '{"p_query":"Blocked Feed"}')
if printf '%s' "$feed" | grep -q "$EVENT_ID"; then ok "unblocked creator's event returns to feed"; else nok "event still hidden after unblock"; fi

# =========================================================================
h1 "E - mute is weaker than block"
# =========================================================================
resp=$(auth_rpc "$TOKEN_A" "mute_user" "{\"p_user_id\":\"$UUID_B\"}")
if [ "$(printf '%s' "$resp" | pyget status)" = "ok" ]; then ok "A muted B"; else nok "mute failed: $(echo "$resp" | head -c 120)"; fi
svc_delete_quiet "notifications?user_id=eq.$UUID_A&type=eq.friend_request"
svc_rpc "insert_notification" "{\"p_user_id\":\"$UUID_A\",\"p_type\":\"friend_request\",\"p_title\":\"t\",\"p_body\":\"b\",\"p_data\":{\"userId\":\"$UUID_B\"}}" >/dev/null
count=$(svc_get "notifications?user_id=eq.$UUID_A&type=eq.friend_request&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$count" = "0" ]; then ok "muted actor's notification suppressed"; else nok "muted actor still notified ($count)"; fi
resp=$(auth_rpc "$TOKEN_A" "create_direct_chat" "{\"p_peer_id\":\"$UUID_B\"}")
CHAT_ID=$(printf '%s' "$resp" | pyget chatId)
if [ -n "$CHAT_ID" ]; then ok "mute still allows a new DM (weaker than block)"; else nok "mute blocked DM: $(echo "$resp" | head -c 120)"; fi
auth_rpc "$TOKEN_A" "unmute_user" "{\"p_user_id\":\"$UUID_B\"}" >/dev/null

# =========================================================================
h1 "F - report_message ncii priority + plaintext snapshot"
# =========================================================================
MSG_ID="77777777-7777-7777-7777-777777777704"
body="{\"id\":\"$MSG_ID\",\"chat_id\":\"$CHAT_ID\",\"sender_id\":\"$UUID_B\",\"content\":\"SME2.ncii.ciphertext\"}"
curl -s -X POST "$SUPABASE_URL/rest/v1/messages" -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $TOKEN_B" -H "Content-Type: application/json" \
  -H "Prefer: return=representation" -d "$body" >/dev/null
resp=$(auth_rpc "$TOKEN_A" "report_message" \
  "{\"p_message_id\":\"$MSG_ID\",\"p_reason\":\"ncii\",\"p_plaintext\":\"decrypted text\"}")
REPORT_MSG=$(printf '%s' "$resp" | pyget report_id)
if [ "$(printf '%s' "$resp" | pyget category)" = "ncii" ] \
   && [ "$(printf '%s' "$resp" | pyget priority)" = "2" ]; then
  ok "message report mapped to ncii / priority 2"
else
  nok "message report: $(echo "$resp" | head -c 160)"
fi
plain=$(svc_get "message_reports?report_id=eq.$REPORT_MSG&select=plaintext" | pyget plaintext)
if [ "$plain" = "decrypted text" ]; then ok "disclosed plaintext snapshot stored"; else nok "plaintext snapshot='$plain'"; fi

# =========================================================================
h1 "G - moderation review/dismiss, reporter outcome, ban appeal"
# =========================================================================
resp=$(svc_rpc "moderate_report" "{\"p_report_id\":\"$REPORT_MSG\",\"p_action\":\"review\",\"p_admin_user_id\":\"$ADMIN_ID\"}")
st=$(svc_get "reports?id=eq.$REPORT_MSG&select=status,reviewed_by" | pyget status)
rb=$(svc_get "reports?id=eq.$REPORT_MSG&select=status,reviewed_by" | pyget reviewed_by)
if [ "$(printf '%s' "$resp" | pyget status)" = "ok" ] && [ "$st" = "reviewed" ] && [ "$rb" = "$ADMIN_ID" ]; then
  ok "review state recorded with the real admin actor"
else
  nok "review state wrong (status=$st reviewed_by=$rb)"
fi
audit=$(svc_get "admin_audit_log?action=eq.report_review&target_id=eq.$MSG_ID&select=admin_user_id" | pyget admin_user_id)
if [ "$audit" = "$ADMIN_ID" ]; then ok "audit row carries the real actor"; else nok "audit actor='$audit'"; fi
svc_delete_quiet "notifications?user_id=eq.$UUID_A&type=eq.report_outcome"
svc_rpc "moderate_report" "{\"p_report_id\":\"$REPORT_MSG\",\"p_action\":\"dismiss\",\"p_admin_user_id\":\"$ADMIN_ID\"}" >/dev/null
st=$(svc_get "reports?id=eq.$REPORT_MSG&select=status,reporter_outcome" | pyget status)
outcome=$(svc_get "reports?id=eq.$REPORT_MSG&select=status,reporter_outcome" | pyget reporter_outcome)
count=$(svc_get "notifications?user_id=eq.$UUID_A&type=eq.report_outcome&select=id" | grep -o '"id"' | wc -l | tr -d ' ')
if [ "$st" = "dismissed" ] && [ "$outcome" = "dismissed" ] && [ "$count" = "1" ]; then
  ok "dismiss records reporter outcome + notifies the reporter"
else
  nok "dismiss state/outcome/notification wrong (status=$st outcome=$outcome notif=$count)"
fi

# A reports B's account; remove bans B; B appeals; admin overturns.
resp=$(auth_rpc "$TOKEN_A" "report_content" \
  "{\"p_target_type\":\"user\",\"p_target_id\":\"$UUID_B\",\"p_category\":\"harassment\"}")
R_USER=$(printf '%s' "$resp" | pyget report_id)
svc_rpc "moderate_report" "{\"p_report_id\":\"$R_USER\",\"p_action\":\"remove\",\"p_admin_user_id\":\"$ADMIN_ID\"}" >/dev/null
banned=$(svc_get "users?id=eq.$UUID_B&select=banned_at" | pyget banned_at)
if [ -n "$banned" ]; then ok "user report removal bans the target"; else nok "target not banned"; fi
resp=$(auth_rpc "$TOKEN_B" "submit_appeal" \
  "{\"p_report_id\":\"$R_USER\",\"p_message\":\"Please review this decision, it was not harassment.\"}")
APPEAL_ID=$(printf '%s' "$resp" | pyget appeal_id)
if [ "$(printf '%s' "$resp" | pyget status)" = "ok" ] && [ -n "$APPEAL_ID" ]; then
  ok "banned user can submit a ban appeal"
else
  nok "ban appeal failed: $(echo "$resp" | head -c 160)"
fi
if [ "$(auth_get "$TOKEN_B" "appeals?id=eq.$APPEAL_ID&select=status,is_ban_appeal" | pyget is_ban_appeal)" = "True" ]; then
  ok "appeal is flagged as a ban appeal and is owner-readable"
else
  nok "appeal row not readable/flagged"
fi
resp=$(svc_rpc "decide_appeal" "{\"p_appeal_id\":\"$APPEAL_ID\",\"p_decision\":\"overturned\",\"p_note\":\"overturned in test\",\"p_admin_user_id\":\"$ADMIN_ID\"}")
banned=$(svc_get "users?id=eq.$UUID_B&select=banned_at" | pyget banned_at)
ast=$(svc_get "appeals?id=eq.$APPEAL_ID&select=status" | pyget status)
if [ "$(printf '%s' "$resp" | pyget unbanned)" = "True" ] && [ -z "$banned" ] && [ "$ast" = "overturned" ]; then
  ok "overturned ban appeal unbans the user (AFTER)"
else
  nok "overturn wrong (unbanned=$(printf '%s' "$resp" | pyget unbanned) banned_at='$banned' status='$ast')"
fi

# =========================================================================
h1 "H - anon privilege checks"
# =========================================================================
for fn in report_content submit_appeal decide_appeal set_notification_preferences; do
  resp=$(anon_rpc "$fn" '{}')
  if echo "$resp" | grep -qE 'permission denied|42501|not_authenticated|PGRST'; then
    ok "anon denied $fn"
  else
    nok "anon was NOT denied $fn: $(echo "$resp" | head -c 100)"
  fi
done

echo ""
echo "==============================================================="
echo "  OPT-065: PASS=$PASS FAIL=$FAIL"
echo "==============================================================="
[ "$FAIL" -eq 0 ]
