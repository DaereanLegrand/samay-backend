# Samay backend — local (Docker) + prod (VM + vault). Supabase-only stack.
#
# Local dev needs no submodule. Prod (`start PROD=true`, `deploy`) requires the
# optional <private-ops-repo> submodule (Admin access) + a vault passphrase.
.PHONY: help init tunnel start stop status reset nuke seed in-db logs \
        build-cli build-linux build-api build-loadtest build-pushworker build-pushworker-image loadtest \
        test check lint secrets migrate migrate-adopt fetch-fcm hooks guard-prod \
        db api smoke

# Identity (single source of truth) — inferred, never passed by callers.
APP := $(shell cat .qallariy-app 2>/dev/null)
export APP
# Optional <private-ops-repo> submodule (monorepo sibling fallback).
INFRA := $(firstword $(wildcard infra) $(wildcard ../../<private-ops-repo>))
-include $(INFRA)/make/app.mk

PROD      ?= false
TUNNEL    ?= quick
GO_BIN         := samay
GO_BIN_LINUX   := samay-linux
LOADTEST_BIN   := ./samay-loadtest
PUSHWORKER_BIN := ./samay-pushworker
# Image tag the VM stack expects (vm.env.template PUSHWORKER_IMAGE).
PUSHWORKER_IMAGE_TAG ?= samay-pushworker:prod
LOADTEST_URL   ?= https://samay-api.qallariy.lat
LOADTEST_ARGS  ?=
PGTAP_DB_URL   ?= postgres://postgres:postgres@localhost:54382/postgres?sslmode=disable

# ── Track-2 PUSH gate ────────────────────────────────────────────────────────
# The push worker (`samay-pushworker`) ships behind the `fcm` compose profile.
# FCM comes ONLY from the CLI/shell (never supabase/.env): `make start FCM=true`
# opts testing in; anything else ⇒ no fetch, no pushworker. staging/prod are
# always on via COMPOSE_PROFILES=fcm in their (vault-merged) env — no flag there.
PUSH_PROFILE := $(if $(filter true,$(FCM)),--profile fcm,)
# When FCM=true, `make start`/`reset` fetch the testing FCM service account from
# the vault (<build-host> → <build-host>) and inject it into the compose shell env
# (never written to disk; shell env overrides --env-file). The plain assignment
# + trailing `&&` make ANY vault failure abort the recipe before `docker compose`.
ifeq ($(FCM),true)
FCM_FETCH := SUPABASE_FCM_SERVICE_ACCOUNT_JSON_B64="$$(bash tools/<fetch-fcm-secret>.sh)" && export SUPABASE_FCM_SERVICE_ACCOUNT_JSON_B64 &&
else
FCM_FETCH :=
endif

help:
	@echo "Samay backend — make targets (PROD unset = dev/testing; PROD=true = prod)"
	@echo "  SETUP:       init"
	@echo "  DEV/TESTING: start stop status reset nuke seed tunnel in-db logs"
	@echo "  PUSH:        FCM=true (CLI/env only) fetches the vault + runs samay-pushworker (profile fcm; staging/prod always on)"
	@echo "  SUITES:      test [db|api]        loadtest [smoke]"
	@echo "  BUILD:       build-cli build-linux build-api build-loadtest build-pushworker build-pushworker-image"
	@echo "  GATES:       check lint secrets migrate migrate-adopt fetch-fcm hooks"
	@echo "  PROD:        start PROD=true   deploy"

init:
	@bash tools/init.sh

tunnel:
	@MODE=$(TUNNEL) bash tools/tunnel.sh $(TUNNEL)

# ── Prod gate (PROD=true + interactive TTY for the vault passphrase) ─────────
guard-prod:
	@[ "$(PROD)" = "true" ] || { echo "PROD=true required (prod-only)"; exit 1; }
	@[ -t 0 ] || { echo "prod requires an interactive TTY (vault passphrase)"; exit 1; }
	@[ -n "$(INFRA)" ] || { echo "prod needs the <private-ops-repo> submodule (Admin access)"; exit 1; }
	@[ -n "$(APP)" ] || { echo "APP unresolved (missing .qallariy-app)"; exit 1; }

# ── Lifecycle: local Docker by default, VM + vault when PROD=true ────────────
ifeq ($(PROD),true)
start: guard-prod
	@$(MAKE) -C $(INFRA) start PROD=true APP=$(APP)
stop: guard-prod
	@echo "prod VM has no stop target (use: make restart PROD=true)"
status: guard-prod
	@$(MAKE) -C $(INFRA) status PROD=true APP=$(APP)
else
start:
	@$(FCM_FETCH) cd supabase && docker compose $(PUSH_PROFILE) --env-file .env up -d && \
		docker compose $(PUSH_PROFILE) --env-file .env up -d --wait db auth && \
		bash ../tools/apply_migrations.sh supabase && \
		PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql
stop:
	@cd supabase && docker compose $(PUSH_PROFILE) --env-file .env down
status:
	@cd supabase && docker compose $(PUSH_PROFILE) --env-file .env ps
endif

reset:
	@[ "$(PROD)" != "true" ] || { echo "refusing to reset prod via make; run the VM reset explicitly"; exit 1; }
	@$(FCM_FETCH) cd supabase && docker compose $(PUSH_PROFILE) --env-file .env down -v && \
		rm -rf volumes/storage && \
		(docker volume rm samay_db-data samay_rustfs-data 2>/dev/null || true) && \
		docker compose $(PUSH_PROFILE) --env-file .env up -d && \
		docker compose $(PUSH_PROFILE) --env-file .env up -d --wait db auth && \
		bash ../tools/apply_migrations.sh supabase && \
		PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql

# Stop the stack AND remove its volumes (wiped DB + RustFS + storage bind).
# `stop` keeps volumes; `reset` also restarts/migrates/seeds. Use before a
# fresh `make start`.
nuke:
	@[ "$(PROD)" != "true" ] || { echo "refusing to nuke prod; run the VM reset explicitly"; exit 1; }
	@cd supabase && docker compose $(PUSH_PROFILE) --env-file .env down -v && \
		rm -rf volumes/storage

seed:
	@cd supabase && docker compose --env-file .env exec -T db psql -U postgres -f /dev/stdin -q < seed-test.sql

in-db:
	PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres

# Follow one stack service's logs, e.g. `make logs SVC=pushworker`
# (no SVC = all services). `make status` (docker compose ps) lists every
# service, including the `fcm`-profiled `pushworker` when FCM=true.
logs:
	@cd supabase && docker compose $(PUSH_PROFILE) --env-file .env logs -f --tail=200 $(SVC)

# ── Go ───────────────────────────────────────────────────────────────────────
build-cli:
	go build -o $(GO_BIN) ./cmd/samay-admin
build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(GO_BIN_LINUX) ./cmd/samay-admin
build-api:
	go build -o samay-api-server ./cmd/samay-api-server
build-loadtest:
	go build -o $(LOADTEST_BIN) ./cmd/samay-loadtest
build-pushworker:
	go build -o $(PUSHWORKER_BIN) ./cmd/samay-pushworker
# Container image for the stack (local `make start` builds it via compose; the
# prod VM needs it preloaded: `docker save $(PUSHWORKER_IMAGE_TAG) | gzip` then
# `doas docker load` on the VM).
build-pushworker-image:
	docker build -f Dockerfile.pushworker -t $(PUSHWORKER_IMAGE_TAG) .

loadtest: build-loadtest
	@case "$(filter smoke,$(MAKECMDGOALS))" in \
	  smoke) \
	    SVC=$$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    ANON=$$(grep -E '^SUPABASE_ANON_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"'); \
	    SEC=$$(grep -E '^JWT_SECRET=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    $(LOADTEST_BIN) --url "$(LOADTEST_URL)" --anon-key "$$ANON" --service-key "$$SVC" \
	      --jwt-secret "$$SEC" --yes --run-id "smoke$$(date +%s)" \
	      --users 3 --friendships 3 --groups 1 --events 1 --matches 2 \
	      --workers 4 --duration 8s --realtime 3 ;; \
	  *) \
	    SVC=$$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    ANON=$$(grep -E '^SUPABASE_ANON_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"'); \
	    SEC=$$(grep -E '^JWT_SECRET=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    echo "loadtest -> $(LOADTEST_URL) (creates data; no cleanup)"; \
	    $(LOADTEST_BIN) --url "$(LOADTEST_URL)" --anon-key "$$ANON" --service-key "$$SVC" \
	      --jwt-secret "$$SEC" --yes $(LOADTEST_ARGS) ;; \
	esac
smoke: ;

# ── Tests (secondary-goal style: make test db | make test api) ───────────────
test:
	@case "$(filter db api,$(MAKECMDGOALS))" in \
	  db) \
	    bash -c 'nc -z 127.0.0.1 54382 2>/dev/null' || { echo "PostgreSQL not reachable on 54382 — make start"; exit 1; }; \
	    command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 1; }; \
	    supabase db test --db-url "$(PGTAP_DB_URL)" -- supabase/tests/schema_test.sql ;; \
	  api) \
	    bash -c 'nc -z 127.0.0.1 54386 2>/dev/null' || { echo "Kong not reachable on 54386 — make start"; exit 1; }; \
	    bash test/run_all_backend.sh ;; \
	  *) \
	    go test ./... && \
	    bash test/opt-005-seeds-static.sh && \
	    bash test/opt-008-makefile-static.sh ;; \
	esac
db api: ;

# ── Gates ────────────────────────────────────────────────────────────────────
check: secrets
	go vet ./...
	@UNFMT="$$(gofmt -l cmd internal)"; if [ -n "$$UNFMT" ]; then echo "gofmt: unformatted Go files:"; echo "$$UNFMT"; exit 1; fi

lint:
	@command -v golangci-lint >/dev/null 2>&1 && golangci-lint run ./... || go vet ./...

secrets:
	@tools/check_secrets.sh
migrate:
	@tools/check_migrations.sh
# One-time, per pre-ledger database: record the existing baseline WITHOUT
# re-running it, so `make start` only applies pending migrations from then on.
# Never needed after `make reset` (fresh -> ledger fills as files run).
migrate-adopt:
	@[ "$(PROD)" != "true" ] || { echo "refusing local adopt for prod; run the VM adopt"; exit 1; }
	@bash tools/apply_migrations.sh supabase adopt
# Fetch the testing FCM service account from the vault (owner-run, nothing on
# disk). `make start FCM=true` calls this automatically.
fetch-fcm:
	@bash tools/<fetch-fcm-secret>.sh
hooks:
	@git config core.hooksPath tools/hooks
	@[ -x tools/hooks/pre-commit ] || { echo "tools/hooks/pre-commit missing or not executable"; exit 1; }
	@echo "core.hooksPath -> tools/hooks"
