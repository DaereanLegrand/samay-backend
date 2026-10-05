#!/usr/bin/env bash
# =============================================================================
# [OPT-040] Organization SCM (native Gitea) static gate.
#
# Stack-free verification that the SCM VM bootstrap is Gitea-only and native
# (official binary + OpenRC + SQLite — no Docker), that GitLab is fully retired,
# and that the org-level names/URLs are consistent. No network, no UTM, no
# running stack. Exit 0 = all checks pass:
#
#   1. The native SCM artifacts exist (lib.sh, host-10/11/12, guest-scm-01/02/
#      03/04-theme/05, scm.env.template, README.md, VAULT-SETUP.md).
#   2. GitLab is retired: guest-scm-04-gitlab.sh / guest-scm-06-mirror.sh and
#      compose/scm/ are GONE (04 is now the theme step).
#   3. Every tools/<ops-tooling>/*.sh is `bash -n` clean.
#   4. lib.sh pins the org identity (QallariySCM.utm / <source-host> / .201) on
#      /Volumes/Media; the guest scripts install the pinned Gitea binary and
#      supervise it with OpenRC (no `docker`).
#   5. scm.env.template is Gitea-only and org-scoped (qallariy) with the real
#      gitea-scm.qallariy.lat URL and NO GITLAB_* / :8929 remnant.
#   6. The Makefile exposes <source-host>-{vm,fetch,sync}.
#   7. No secret-shaped literals in the bootstrap scripts/templates.
#
# Usage: bash test/opt-040-scm-native-static.sh
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$REPO/tools/<ops-tooling>"
MAKEFILE="$REPO/Makefile"
FAILURES=0
fail() { echo "  ❌ $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✅ $*"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  OPT-040 — organization SCM (native Gitea) static verification"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Artifacts present ─────────────────────────────────────────────────────
echo ""
echo "━━━ 1. Native SCM artifacts present ━━━"
for f in lib.sh <host-script> <host-script> <host-script> \
         guest-scm-01-packages.sh guest-scm-02-runtime.sh guest-scm-03-gitea.sh \
         guest-scm-04-theme.sh guest-scm-05-tunnel.sh \
         scm.env.template README.md VAULT-SETUP.md; do
  if [ -r "$BOOT/$f" ]; then pass "exists: tools/<ops-tooling>/$f"; else fail "missing: tools/<ops-tooling>/$f"; fi
done

# ── 2. GitLab retired ────────────────────────────────────────────────────────
echo ""
echo "━━━ 2. GitLab fully retired ━━━"
for f in guest-scm-04-gitlab.sh guest-scm-06-mirror.sh; do
  if [ -e "$BOOT/$f" ]; then fail "$f still present (GitLab must be retired)"; else pass "$f absent"; fi
done
if [ -d "$BOOT/compose/scm" ]; then
  fail "compose/scm/ still present (Gitea/GitLab compose must be retired)"
else
  pass "compose/scm/ absent (native Gitea, no compose)"
fi

# ── 3. Parse-clean ───────────────────────────────────────────────────────────
echo ""
echo "━━━ 3. tools/<ops-tooling>/*.sh bash -n ━━━"
shopt -s nullglob
SCRIPTS=("$BOOT"/*.sh)
shopt -u nullglob
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  fail "no tools/<ops-tooling>/*.sh found"
else
  for s in "${SCRIPTS[@]}"; do
    bash -n "$s" 2>/dev/null && pass "$(basename "$s") bash -n clean" || fail "$(basename "$s") bash -n FAILED"
  done
fi

# ── 4. Org identity + native Gitea ───────────────────────────────────────────
echo ""
echo "━━━ 4. Org identity + native Gitea ━━━"
LIB="$BOOT/lib.sh"
if grep -q 'QallariySCM.utm' "$LIB"; then pass "lib.sh bundle = QallariySCM.utm"; else fail "lib.sh bundle is not QallariySCM.utm"; fi
if grep -q 'SCM_VM_NAME="${SCM_VM_NAME:-QallariySCM}"' "$LIB"; then pass "lib.sh SCM_VM_NAME = QallariySCM"; else fail "lib.sh SCM_VM_NAME not QallariySCM"; fi
if grep -q 'SCM_VM_HOSTNAME="${SCM_VM_HOSTNAME:-<source-host>}"' "$LIB"; then pass "lib.sh hostname = <source-host>"; else fail "lib.sh hostname not <source-host>"; fi
if grep -q '/Volumes/Media' "$LIB"; then pass "lib.sh roots storage under /Volumes/Media"; else fail "lib.sh does not reference /Volumes/Media"; fi

R02="$BOOT/guest-scm-02-runtime.sh"
if grep -q 'GITEA_VER="${GITEA_VER:-1.27.3}"' "$R02"; then pass "guest-scm-02 pins Gitea 1.27.3"; else fail "guest-scm-02 does not pin Gitea 1.27.3"; fi
if grep -q 'dl.gitea.com' "$R02"; then pass "guest-scm-02 fetches the official binary"; else fail "guest-scm-02 does not fetch the official binary"; fi
if grep -q '/etc/init.d/gitea' "$R02"; then pass "guest-scm-02 installs the OpenRC unit"; else fail "guest-scm-02 does not install the OpenRC unit"; fi
R03="$BOOT/guest-scm-03-gitea.sh"
if grep -q 'SECRET_KEY' "$R03"; then pass "guest-scm-03 writes SECRET_KEY into app.ini"; else fail "guest-scm-03 does not write SECRET_KEY"; fi
if grep -q 'DB_TYPE = sqlite3' "$R03"; then pass "guest-scm-03 uses SQLite"; else fail "guest-scm-03 does not use SQLite"; fi
# Qallariy theme: guest-scm-04 installs it, host-12 stages it.
R04="$BOOT/guest-scm-04-theme.sh"
if grep -q 'THEMES = qallariy,<theme-name>' "$R04" && grep -q 'DEFAULT_THEME = qallariy' "$R04"; then
  pass "guest-scm-04 enables the Qallariy themes"
else
  fail "guest-scm-04 does not enable the Qallariy themes"
fi
if grep -q '/var/lib/gitea/custom\|GITEA_HOME' "$R04" && grep -q 'custom' "$R04"; then
  pass "guest-scm-04 installs into the Gitea custom dir"
else
  fail "guest-scm-04 does not install into the Gitea custom dir"
fi
if grep -q 'GITEA_THEME_SRC' "$BOOT/<host-script>"; then
  pass "host-12 stages the Gitea theme"
else
  fail "host-12 does not stage the Gitea theme"
fi
# No Docker anywhere in the SCM bootstrap (Docker stays only in the CI runner).
if grep -rqE 'docker (compose|network|run|exec)|apk add[^\n]*docker' "$BOOT"/lib.sh "$BOOT"/guest-scm-*.sh "$BOOT"/host-1*.sh; then
  fail "Docker reference found in the SCM bootstrap (must be Docker-free)"
else
  pass "SCM bootstrap is Docker-free"
fi
# cloudflared flags: --no-autoupdate/--loglevel are tunnel-level and MUST come
# before the `run` subcommand; and status()/stop() must match that command.
R05="$BOOT/guest-scm-05-tunnel.sh"
if grep -q 'tunnel --no-autoupdate --loglevel warn run' "$R05"; then
  pass "guest-scm-05: cloudflared flags precede 'run'"
else
  fail "guest-scm-05: cloudflared flags must precede 'run' (tunnel …flags… run)"
fi
if grep -q 'pgrep -f "\$CF tunnel"' "$R05" && grep -q 'pkill -f "\$CF tunnel"' "$R05"; then
  pass "guest-scm-05: status/stop patterns match the connector command"
else
  fail "guest-scm-05: status/stop patterns do not match the connector command"
fi

# ── 5. Gitea-only org template ───────────────────────────────────────────────
echo ""
echo "━━━ 5. scm.env.template (Gitea-only, org-scoped) ━━━"
TMPL="$BOOT/scm.env.template"
if grep -q '^GITEA_ORG=qallariy' "$TMPL"; then pass "GITEA_ORG=qallariy"; else fail "GITEA_ORG missing/not qallariy"; fi
if grep -q '^GITEA_ADMIN_USERNAME=admin' "$TMPL"; then pass "GITEA_ADMIN_USERNAME=admin"; else fail "GITEA_ADMIN_USERNAME not admin"; fi
if grep -q '^GITEA_ROOT_URL=https://gitea-scm.qallariy.lat/' "$TMPL"; then pass "GITEA_ROOT_URL = gitea-scm.qallariy.lat"; else fail "GITEA_ROOT_URL is not gitea-scm.qallariy.lat"; fi
if grep -qE 'GITLAB_|:8929|gitlab-scm' "$TMPL"; then fail "scm.env.template still carries a GitLab remnant"; else pass "no GitLab remnant in scm.env.template"; fi

# ── 6. Makefile targets ──────────────────────────────────────────────────────
echo ""
echo "━━━ 6. Makefile <source-host>-* targets ━━━"
if [ -r "$MAKEFILE" ]; then
  for t in vm fetch sync deploy; do
    if grep -qE "^<source-host>-${t}:" "$MAKEFILE"; then pass "target: <source-host>-${t}"; else fail "target missing: <source-host>-${t}"; fi
  done
else
  fail "Makefile missing"
fi

# ── secret-shape scanner (self-safe: patterns assembled at runtime) ──────────
SB_PAT="$(printf 'sb_%s[A-Za-z0-9_-]{16,}' 'secret_')"
PK_PAT="$(printf '%s[A-Z ]*%s' 'BEGIN ' 'PRIVATE KEY')"
SECRET_PATTERNS="$SB_PAT
AIza[0-9A-Za-z_-]{35}
AKIA[0-9A-Z]{16}
ghp_[0-9A-Za-z]{36}
gho_[0-9A-Za-z]{36}
ghs_[0-9A-Za-z]{36}
github_pat_[0-9A-Za-z_]{30,}
xox[baprs]-[0-9A-Za-z-]{10,}
sk_live_[0-9A-Za-z]{10,}
eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
$PK_PAT
[A-Za-z0-9+/]{200,}={0,2}"

# ── 7. No secret-shaped literals ─────────────────────────────────────────────
echo ""
echo "━━━ 7. No secret-shaped literals ━━━"
FOUND_SECRET=0
for s in "$LIB" "$BOOT"/host-1*.sh "$BOOT"/guest-scm-*.sh "$TMPL" "$BOOT/VAULT-SETUP.md"; do
  [ -r "$s" ] || continue
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    hits="$(grep -nE -- "$pat" "$s" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      fail "secret-shaped literal in ${s#$REPO/} → $(printf '%s' "$hits" | head -1)"
      FOUND_SECRET=1
    fi
  done <<< "$SECRET_PATTERNS"
done
[ "$FOUND_SECRET" -eq 0 ] && pass "no secret-shaped literals in the SCM bootstrap"

# ── 8. Self syntax ───────────────────────────────────────────────────────────
echo ""
echo "━━━ 8. Self syntax ━━━"
if bash -n "$0" 2>/dev/null; then pass "bash -n $0"; else fail "bash -n $0"; fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "  ❌ OPT-040 FAILED: $FAILURES check(s) failed."
  exit 1
fi
echo "  ✅ OPT-040 PASSED — native organization SCM verified."
exit 0
