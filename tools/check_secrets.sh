#!/usr/bin/env bash
# =============================================================================
# check_secrets.sh — committed-secret gate (MKE-02/MKE-03, agent M-13).
#
# Scans TRACKED (committed) files only, via `git grep` — untracked local
# .env/.env.local files are by design NOT scanned (local secrets live outside
# version control). A hit on a real key, a placeholder pattern outside its
# documented homes, or a secrets-as-Makefile-variable assignment is a FAIL.
#
# Patterns and allowlists (each documented in the M-13 daily log
# docs/history/phase-00-foundation/2026-08-10_M13-makefile-env.md):
#
#   P1  sb_publishable_q7ND…           known dev ANON key (H-21/SEC-03 class)
#         allowlisted: opt-test defaults (dev-only, CI overrides via env —
#         M-03), the tracked supabase/.env.local dev sources, and the
#         M-03/M-09 evidence logs (historical records, I-34 precedent)
#   P2  sb_publishable_ACJW…           known HISTORICAL anon key (git history)
#         allowlisted: D-03/I-34 evidence logs only (historical records)
#   P3  sb_service_role                any service-role literal
#         allowlisted: opt-test dev defaults + opt-007 search-literal + the
#         docs that document the dev matrix (SELFHOSTING, TODO, M-03/M-09)
#   P4  sb_secret_[…]{16,}             real service-role KEY shape (Supabase)
#         allowlisted: opt-007 search-literal + M-03 evidence log only
#   P5  your_supabase                  placeholder patterns
#         allowlisted: .env.example (canonical placeholders), compose
#         ${VAR:-…} safe defaults (M-03), opt-007 search-literal, docs/
#         (document the convention)
#
# 2026-08-10 (M-26): EVIDENCE3 added — the M-13/M-17/M-20/M-21 daily logs
# quote the P2/P3 pattern LITERALS in their pattern tables and evidence
# commands (same class as the M-03/M-09/D-03/I-34 evidence logs already
# allowlisted). First flagged by the new pre-commit gate (tools/pre-commit.sh,
# TOOL-04) — the committed tree had this pre-existing failure since 8ae9e51.
#
# Usage: tools/check_secrets.sh   # exit 0 = clean, 1 = violations found
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

VIOLATIONS=0

scan() { # scan <label> <pattern> <allowlist-regex>
  local label="$1" pattern="$2" allow="$3"
  local hits
  if [ -n "$allow" ]; then
    hits="$(git grep -n -I -E -- "$pattern" -- . 2>/dev/null | grep -Ev "$allow" || true)"
  else
    hits="$(git grep -n -I -E -- "$pattern" -- . 2>/dev/null || true)"
  fi
  if [ -n "$hits" ]; then
    printf '  ✗ %s — %s\n' "$label" "$pattern"
    printf '%s\n' "$hits" | sed 's/^/      /'
    VIOLATIONS=$((VIOLATIONS + 1))
  else
    printf '  ✓ %s\n' "$label"
  fi
}

# ── allowlist fragments ─────────────────────────────────────────────────────
SELF='tools/check_secrets\.sh'
TEST_DEFAULTS='test/opt-001-rls-security\.sh|test/opt-002-events\.sh|test/opt-003-chat\.sh|test/opt-004-photos\.sh|test/opt-006-e2ee-rpc\.sh|test/run_all_backend\.sh'
ENV_LOCAL='supabase/\.env\.local|supabase-testing/\.env\.local'
OPT007='test/opt-007-compose-static\.sh'
EVIDENCE='docs/history/phase-00-foundation/2026-08-10_M03-kong-keys\.md|docs/history/phase-00-foundation/2026-08-10_M09-kong\.md'
EVIDENCE2='docs/history/phase-00-foundation/2026-08-09_D03-tofix-audit\.md|docs/history/phase-02-flutter-foundation/2026-08-09_I34-env-dartdefine\.md'
EVIDENCE3='docs/history/phase-00-foundation/2026-08-10_M13-makefile-env\.md|docs/history/phase-00-foundation/2026-08-10_M17-fastlane-ios\.md|docs/history/phase-00-foundation/2026-08-10_M20-ci\.md|docs/history/phase-00-foundation/2026-08-10_M21-ci-build\.md'

printf '── secrets-check: tracked-file scan for committed secrets ──\n'
scan 'P1 known dev anon key' \
  'sb_publishable_q7NDNoV4TCGqCgheg4tcvC_odjEiEdN' \
  "$SELF|$TEST_DEFAULTS|$ENV_LOCAL|$EVIDENCE"
scan 'P2 historical anon key' \
  'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH' \
  "$SELF|$EVIDENCE2|$EVIDENCE3"
scan 'P3 service-role literals' \
  'sb_service_role' \
  "$SELF|$TEST_DEFAULTS|$OPT007|<private-ops-repo>/SELFHOSTING\.md|docs/to-fix/TODO\.md|$EVIDENCE|$EVIDENCE3"
scan 'P4 real service-role key shape' \
  'sb_secret_[A-Za-z0-9_-]{16,}' \
  "$SELF|$OPT007|$EVIDENCE"
scan 'P5 your_supabase placeholders' \
  'your_supabase' \
  "$SELF|\.env\.example|supabase/docker-compose\.yml|supabase-testing/docker-compose\.yml|$OPT007|docs/"

if [ "$VIOLATIONS" -ne 0 ]; then
  printf 'secrets-check: FAIL — %d violation(s). Remove the literal or justify+extend the allowlist (see M-13 log).\n' "$VIOLATIONS" >&2
  exit 1
fi
printf 'secrets-check: PASS — no committed secrets (only documented allowlisted dev values).\n'
exit 0
