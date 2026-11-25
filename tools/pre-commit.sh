#!/usr/bin/env bash
# Fast pre-commit gate for the Samay backend.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 2
step() { printf '\n\033[1m━━━ %s\033[0m\n' "$1"; }
fail() { printf '  ❌ %s\n' "$1" >&2; }

step "1/4  go vet"
go vet ./... || { fail "go vet failed"; exit 1; }

step "2/4  gofmt"
UNFMT="$(gofmt -l cmd internal)"
[ -z "$UNFMT" ] || { fail "gofmt: $UNFMT"; exit 1; }

step "3/4  secrets-check"
make secrets || { fail "secrets failed"; exit 1; }

step "4/4  Makefile surface"
bash test/opt-008-makefile-static.sh >/dev/null || { fail "makefile-static gate failed"; exit 1; }

printf '\n✅  All pre-commit gates passed.\n'
