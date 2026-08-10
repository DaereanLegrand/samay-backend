#!/usr/bin/env bash
# =============================================================================
# Samay — STATIC gate for the Makefile finalization (agent M-15).
#
# Makefile-side verification of the release-pipeline surface (fastlane stubs,
# migrate-check refresh, deploy placeholders, bundle-install) — no stack, no
# docker, no bundle, no fastlane required. Exit 0 = all checks pass:
#
#   1. `make -n` resolves for ALL documented targets (the full .PHONY
#      inventory, incl. override forms TARGET=/OVERRIDES=/FLUTTER_DEFINES=).
#   2. Fastlane stub contract (DEPLOYMENT-PLACEHOLDER.md §3.2/§3.3 — the
#      lane names M-17/M-18 must implement are fixed HERE):
#        ios-beta       → bundle exec fastlane ios beta_testflight
#        ios-release    → bundle exec fastlane ios release_appstore
#        android-alpha  → bundle exec fastlane android alpha_firebase
#        android-release→ bundle exec fastlane android release_play
#      Each stub gates on fastlane/Fastfile + the lane literal (clear error
#      until M-17/M-18 land). Conditional LIVE stub probe: while
#      fastlane/Fastfile is absent, `make ios-beta` must exit 1 with the
#      "M-17" message (the designed fail-fast stub behavior).
#   3. migrate-check RED probe: tools/check_migrations.sh is run against a
#      SCRATCH git repo — GREEN on a clean committed pair of stacks, RED on a
#      planted untracked migration, RED on a planted future-dated migration
#      (real repo is never touched).
#   4. Deploy targets are placeholders: deploy-api / deploy-dashboard /
#      deploy-venue exist, their block references DEPLOYMENT-PLACEHOLDER.md,
#      and contains NO scheme:// URL at all (real URLs are banned from the
#      Makefile by the repo placeholder policy).
#   5. bash -n on tools/check_migrations.sh and this file.
#
# NOTE for M-17/M-18: when fastlane/Fastfile + Gemfile land, the conditional
# stub probe (§2) auto-skips; keep the four lane names EXACTLY as above.
# M-17 (2026-08-10) added §2b: Fastfile lane/Appfile/Gemfile assertions + the
# no-real-credential-shape scan over fastlane/ (placeholder policy).
# M-18 (2026-08-10) extended §2b: platform :android + alpha_firebase /
# release_play lanes, the §3.3 Android placeholder literals, no .jks/JSON-key
# material in fastlane/ OR android/, and android/app/keystores/ absent
# (path-only contract — M-27 wires the gradle signingConfigs).
#
# Usage: bash test/opt-008-makefile-static.sh
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$REPO/Makefile"
FAILURES=0
fail() { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  M-15 — Makefile finalization static verification"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Every documented target resolves via `make -n` ────────────────────────
echo ""
echo "━━━ 1. make -n resolves all documented targets ━━━"
TARGETS="build dev install clean build-cli build-linux build-api lint check test \
test-all test-unit test-integration test-backend-static test-go flutter-test \
flutter-analyze define-env secrets-check tunnel-android \
supabase-start supabase-stop supabase-status supabase-reset \
supabase-docker-start supabase-docker-stop supabase-docker-status supabase-docker-reset \
supabase-db-test supabase-backend-tests supabase-stack-check \
supabase-seed-dev \
supabase-testing-start supabase-testing-stop supabase-testing-status supabase-testing-reset \
migrate-check \
ios-beta ios-release android-alpha android-release \
deploy-api deploy-dashboard deploy-venue bundle-install"
for t in $TARGETS; do
  if make -n "$t" >/dev/null 2>&1; then
    pass "make -n $t"
  else
    fail "make -n $t does not resolve"
  fi
done

# Override forms (the documented seam surfaces)
if make -n ios-beta >/dev/null 2>&1; then pass "make -n ios-beta (stub resolves dry)"; else fail "make -n ios-beta"; fi
if make -n deploy-api >/dev/null 2>&1; then pass "make -n deploy-api (stub resolves dry)"; else fail "make -n deploy-api"; fi
if make -n bundle-install >/dev/null 2>&1; then pass "make -n bundle-install (stub resolves dry)"; else fail "make -n bundle-install"; fi

# ── 2. Fastlane stub contract (lane names fixed for M-17/M-18) ───────────────
echo ""
echo "━━━ 2. Fastlane stub contract ━━━"
STUB_PAIRS="ios-beta:ios:beta_testflight
ios-release:ios:release_appstore
android-alpha:android:alpha_firebase
android-release:android:release_play"
while IFS=: read -r TGT PLAT LANE; do
  if grep -qE "^$TGT:" "$MAKEFILE"; then
    pass "target '$TGT:' exists"
  else
    fail "target '$TGT:' missing from Makefile"
    continue
  fi
  if grep -q "bundle exec fastlane $PLAT $LANE" "$MAKEFILE"; then
    pass "$TGT → bundle exec fastlane $PLAT $LANE"
  else
    fail "$TGT does not invoke 'bundle exec fastlane $PLAT $LANE'"
  fi
  if grep -A4 "^$TGT:" "$MAKEFILE" | grep -q "fastlane/Fastfile"; then
    pass "$TGT gates on fastlane/Fastfile (clear fail until M-17/M-18)"
  else
    fail "$TGT has no fastlane/Fastfile guard"
  fi
done <<< "$STUB_PAIRS"

# Conditional LIVE stub probe: while fastlane/Fastfile is absent the stub must
# fail fast with the M-17/M-18 message (make reports a failing recipe as
# exit 2 — the recipe itself exits 1; assert message + non-zero status).
# Auto-skips once M-17 lands.
if [ ! -f "$REPO/fastlane/Fastfile" ]; then
  OUT="$(make ios-beta 2>&1)"; ST=$?
  if [ "$ST" -ne 0 ] && printf '%s' "$OUT" | grep -q "M-17"; then
    pass "LIVE probe: make ios-beta fails fast with the M-17 message (exit $ST)"
  else
    fail "LIVE probe: make ios-beta did not fail with the M-17 message (exit $ST)"
  fi
  OUT="$(make bundle-install 2>&1)"; ST=$?
  if [ "$ST" -ne 0 ] && printf '%s' "$OUT" | grep -q "Gemfile"; then
    pass "LIVE probe: make bundle-install fails fast with the Gemfile message (exit $ST)"
  else
    fail "LIVE probe: make bundle-install did not fail with the Gemfile message (exit $ST)"
  fi
else
  echo "  ⏭  fastlane/Fastfile present — stub fail-fast probes skipped (M-17 landed)"
fi

# ── 2b. M-17/M-18 fastlane scaffold (iOS + Android, §3.3) ───────────────────
# Fastfile must define BOTH §3.3 iOS lanes under platform :ios AND BOTH §3.3
# Android lanes under platform :android, Appfile must carry the
# app_identifier + team_id placeholders, Gemfile must declare fastlane +
# cocoapods (MKE-10), and fastlane/ + android/ must contain NO real credential
# shapes (private-key material — which is what .p8 and Google service-account
# JSON content look like — no .jks keystores, no Apple app-specific
# passwords), and the §3.3 path-only files must NOT exist (ASC .p8, Google
# Play service-account JSON). android/app/keystores/ must be ABSENT (the
# keystore is generated + kept in a secret store at release time, never in
# the repo). The fail-fast guard message pins the "credentials not configured
# (placeholders)" contract.
echo ""
echo "━━━ 2b. M-17 fastlane iOS scaffold ━━━"
FL="$REPO/fastlane/Fastfile"
AF="$REPO/fastlane/Appfile"
GF="$REPO/Gemfile"

if [ -f "$FL" ]; then
  grep -q 'platform :ios' "$FL" && pass "Fastfile declares platform :ios" || fail "Fastfile missing 'platform :ios'"
  for LANE in beta_testflight release_appstore; do
    if grep -q "lane :$LANE" "$FL"; then
      pass "Fastfile defines lane :$LANE"
    else
      fail "Fastfile missing lane :$LANE (§3.3 contract)"
    fi
  done
  grep -q 'credentials not configured' "$FL" && pass "lanes fail fast on placeholder credentials" || fail "Fastfile missing the fail-fast placeholder guard"
else
  fail "fastlane/Fastfile missing — M-17 must create it (§3.3 contract)"
fi

# Android half (M-18): platform :android + both §3.3 lanes; the Android
# placeholder literals are pinned verbatim; the same guard message applies.
if [ -f "$FL" ]; then
  grep -q 'platform :android' "$FL" && pass "Fastfile declares platform :android" || fail "Fastfile missing 'platform :android'"
  for LANE in alpha_firebase release_play; do
    if grep -q "lane :$LANE" "$FL"; then
      pass "Fastfile defines lane :$LANE"
    else
      fail "Fastfile missing lane :$LANE (§3.3 contract)"
    fi
  done
  grep -q 'android/app/keystores/release-keystore.jks' "$FL" && pass "ANDROID_KEYSTORE_PATH placeholder pinned" || fail "ANDROID_KEYSTORE_PATH placeholder missing"
  grep -q 'samay-release' "$FL" && pass "ANDROID_KEYSTORE_ALIAS placeholder (samay-release) pinned" || fail "ANDROID_KEYSTORE_ALIAS placeholder missing"
  grep -q 'fastlane/keys/google-play-service-account.json' "$FL" && pass "PLAY_SERVICE_ACCOUNT_JSON placeholder pinned" || fail "PLAY_SERVICE_ACCOUNT_JSON placeholder missing"
fi

if [ -f "$AF" ]; then
  grep -q 'com.qallariy.samay' "$AF" && pass "Appfile app_identifier = com.qallariy.samay (pbxproj-verified)" || fail "Appfile missing app_identifier"
  grep -q 'XXXXXXXXXX' "$AF" && pass "Appfile team_id placeholder (XXXXXXXXXX)" || fail "Appfile missing the TEAM_ID placeholder"
else
  fail "fastlane/Appfile missing — M-17 must create it"
fi

if [ -f "$GF" ]; then
  grep -q 'gem "fastlane"' "$GF" && pass "Gemfile declares fastlane" || fail "Gemfile missing 'gem \"fastlane\"'"
  grep -q 'gem "cocoapods"' "$GF" && pass "Gemfile declares cocoapods" || fail "Gemfile missing 'gem \"cocoapods\"' (MKE-10)"
else
  fail "Gemfile missing — M-17 must create it (MKE-10)"
fi

if [ -d "$REPO/fastlane" ]; then
  if grep -rqE -- '-----BEGIN|BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY' "$REPO/fastlane"; then
    fail "fastlane/ contains private-key material (-----BEGIN … PRIVATE KEY)"
  else
    pass "fastlane/ contains no private-key material"
  fi
  if grep -rqE '[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}' "$REPO/fastlane"; then
    fail "fastlane/ contains an app-specific-password shape (xxxx-xxxx-xxxx-xxxx)"
  else
    pass "fastlane/ contains no app-specific-password shape"
  fi
  if [ -f "$REPO/fastlane/keys/AppStoreConnect_AAAAAAAAAA.p8" ]; then
    fail "fastlane/keys/AppStoreConnect_AAAAAAAAAA.p8 must NOT exist (§3.3 — path only)"
  else
    pass "fastlane/keys/AppStoreConnect_AAAAAAAAAA.p8 absent (path only, per §3.3)"
  fi
  if [ -f "$REPO/fastlane/keys/google-play-service-account.json" ]; then
    fail "fastlane/keys/google-play-service-account.json must NOT exist (§3.3 — path only)"
  else
    pass "fastlane/keys/google-play-service-account.json absent (path only, per §3.3)"
  fi
  grep -q 'AAAAAAAAAA' "$FL" && pass "ASC key-id placeholder (AAAAAAAAAA) present" || fail "ASC key-id placeholder missing"
  grep -q 'git@github.com:samay-app/samay-match.git' "$FL" && pass "MATCH_GIT_URL placeholder present" || fail "MATCH_GIT_URL placeholder missing"
  grep -q 'CHANGE_ME' "$FL" && pass "CHANGE_ME placeholder present" || fail "CHANGE_ME placeholder missing"
fi

# No .jks keystores or private-key material anywhere in android/ (M-18
# contract — the §3.3 keystore is path-only; M-27 wires the gradle
# signingConfigs to the env, the .jks itself lives in a secret store).
if find "$REPO/fastlane" "$REPO/android" -name '*.jks' -o -name '*.p8' 2>/dev/null | grep -q .; then
  fail "a .jks/.p8 file exists in fastlane/ or android/ (never create one)"
else
  pass "no .jks/.p8 files in fastlane/ or android/"
fi
if [ -d "$REPO/android" ]; then
  if grep -rqE -- '-----BEGIN|BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY' "$REPO/android"; then
    fail "android/ contains private-key material (-----BEGIN … PRIVATE KEY)"
  else
    pass "android/ contains no private-key material"
  fi
fi
if [ -d "$REPO/android/app/keystores" ]; then
  fail "android/app/keystores/ must NOT exist (§3.3 — path only; keystore generated at release time)"
else
  pass "android/app/keystores/ absent (path only, per §3.3)"
fi

# ── 3. migrate-check RED probe (scratch git repo, real repo untouched) ───────
echo ""
echo "━━━ 3. migrate-check logic (tools/check_migrations.sh) ━━━"
if bash -n "$REPO/tools/check_migrations.sh" 2>/dev/null; then
  pass "bash -n tools/check_migrations.sh"
else
  fail "bash -n tools/check_migrations.sh"
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/samay-opt008.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
git init -q "$SCRATCH"
mkdir -p "$SCRATCH/supabase/migrations" "$SCRATCH/supabase-testing/migrations"
printf '%s\n' "-- placeholder schema --" > "$SCRATCH/supabase/migrations/20260101000001_dummy.sql"
cp "$SCRATCH/supabase/migrations/20260101000001_dummy.sql" "$SCRATCH/supabase-testing/migrations/"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -q -m init

# GREEN: clean committed pair → exit 0
if bash "$REPO/tools/check_migrations.sh" "$SCRATCH" >/dev/null 2>&1; then
  pass "GREEN: clean stacks pass (exit 0)"
else
  fail "GREEN: clean stacks should pass (exit 0)"
fi

# RED #1: planted UNTRACKED migration → exit 1 + UNTRACKED message
printf '%s\n' "-- planted --" > "$SCRATCH/supabase/migrations/20261231000000_planted.sql"
OUT="$(bash "$REPO/tools/check_migrations.sh" "$SCRATCH" 2>&1)"
if [ $? -eq 1 ] && printf '%s' "$OUT" | grep -q "UNTRACKED"; then
  pass "RED: planted untracked migration flagged (exit 1, UNTRACKED)"
else
  fail "RED: planted untracked migration was NOT flagged"
fi
rm "$SCRATCH/supabase/migrations/20261231000000_planted.sql"

# RED #2: planted future-dated migration (both stacks) → exit 1 + future message
printf '%s\n' "-- future --" > "$SCRATCH/supabase/migrations/20990101000000_future.sql"
cp "$SCRATCH/supabase/migrations/20990101000000_future.sql" "$SCRATCH/supabase-testing/migrations/"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -q -m future
OUT="$(bash "$REPO/tools/check_migrations.sh" "$SCRATCH" 2>&1)"
if [ $? -eq 1 ] && printf '%s' "$OUT" | grep -q "future"; then
  pass "RED: planted future-dated migration flagged (exit 1, future-dated)"
else
  fail "RED: planted future-dated migration was NOT flagged"
fi
rm -rf "$SCRATCH"
trap - EXIT

# ── 4. Deploy targets are placeholders (no real URLs) ────────────────────────
echo ""
echo "━━━ 4. Deploy placeholder targets ━━━"
for TGT in deploy-api deploy-dashboard deploy-venue; do
  if grep -qE "^$TGT:" "$MAKEFILE"; then pass "target '$TGT:' exists"; else fail "target '$TGT:' missing"; fi
done
if grep -q "DEPLOYMENT-PLACEHOLDER.md" "$MAKEFILE"; then
  pass "deploy block points at <private-ops-repo>/DEPLOYMENT-PLACEHOLDER.md"
else
  fail "deploy block does not reference DEPLOYMENT-PLACEHOLDER.md"
fi
FIRST=$(grep -nE "^deploy-" "$MAKEFILE" | head -1 | cut -d: -f1)
if [ -n "$FIRST" ]; then
  if sed -n "${FIRST},\$p" "$MAKEFILE" | grep -qE 'https?://'; then
    fail "deploy block contains a scheme:// URL (placeholder policy violation)"
  else
    pass "deploy block contains no scheme:// URL (placeholders only)"
  fi
else
  fail "no deploy-* targets found for the URL scan"
fi
if sed -n "${FIRST},\$p" "$MAKEFILE" | grep -qE '@exit 0'; then
  pass "deploy targets echo + exit 0"
else
  fail "deploy targets do not echo + exit 0"
fi

# ── 5. Self syntax ───────────────────────────────────────────────────────────
echo ""
echo "━━━ 5. Self syntax ━━━"
if bash -n "$0" 2>/dev/null; then pass "bash -n $0"; else fail "bash -n $0"; fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "  ❌ $FAILURES makefile-static check(s) failed."
  exit 1
fi
echo "  ✅ all makefile-static checks passed."
exit 0
