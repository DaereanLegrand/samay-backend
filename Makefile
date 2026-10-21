# Samay backend — local (Docker) + prod (VM + vault). Supabase-only stack.
#
# Local dev needs no submodule. Prod (`start PROD=true`, `deploy`) requires the
# optional <private-ops-repo> submodule (Admin access) + a vault passphrase.
.PHONY: help init preflight tunnel start stop status reset nuke seed in-db logs \
        build-cli build-linux build-api build-loadtest build-pushworker build-pushworker-image loadtest \
        test check lint secrets migrate migrate-adopt fetch-fcm <fetch-rc-secret> hooks guard-prod \
        db api smoke

# Single environment selector. Values: local (default, Docker) | staging | prod.
# `staging` targets the dedicated staging VM (`samay-staging` profile); `prod`
# the flat prod profile. `PROD` (VM + vault path) is derived — never typed.
ENV  ?= local
PROD := $(if $(filter staging prod,$(ENV)),true,false)
# Identity (single source of truth) — inferred, never passed by callers.
APP_DEFAULT := $(shell cat .qallariy-app 2>/dev/null)
APP := $(if $(filter staging,$(ENV)),$(APP_DEFAULT)-staging,$(APP_DEFAULT))
export APP
# Optional <private-ops-repo> submodule (monorepo sibling fallback).
INFRA := $(firstword $(wildcard infra) $(wildcard ../../<private-ops-repo>))
-include $(INFRA)/make/app.mk
TUNNEL    ?= quick
GO_BIN         := samay
GO_BIN_LINUX   := samay-linux
LOADTEST_BIN   := ./samay-loadtest
PUSHWORKER_BIN := ./samay-pushworker
# Image tag the VM stack expects (vm.env.template PUSHWORKER_IMAGE).
PUSHWORKER_IMAGE_TAG ?= samay-pushworker:prod
LOADTEST_URL   ?= https://samay-api.qallariy.lat
LOADTEST_ARGS  ?=
# ── Stack isolation ───────────────────────────────────────────────────────────
# Defaults preserve the single-stack setup. For a parallel/disposable stack:
#   make start STACK_PREFIX=samay-a STACK_ENV=/tmp/samay-a.env
# The env file carries STACK_PREFIX, COMPOSE_PROJECT_NAME, the 55xxx port map,
# and STORAGE_DIR. Never commit it.
STACK_ENV ?= $(CURDIR)/supabase/.env
STACK_PREFIX ?= $(shell sed -n 's/^STACK_PREFIX=\([A-Za-z0-9_-]*\).*/\1/p' $(STACK_ENV) 2>/dev/null | head -1)
ifeq ($(strip $(STACK_PREFIX)),)
STACK_PREFIX := samay
endif
POSTGRES_PORT ?= $(shell sed -n 's/^POSTGRES_PORT=\([0-9]*\).*/\1/p' $(STACK_ENV) 2>/dev/null | head -1)
ifeq ($(strip $(POSTGRES_PORT)),)
POSTGRES_PORT := 54382
endif
KONG_HTTP_PORT ?= $(shell sed -n 's/^KONG_HTTP_PORT=\([0-9]*\).*/\1/p' $(STACK_ENV) 2>/dev/null | head -1)
ifeq ($(strip $(KONG_HTTP_PORT)),)
KONG_HTTP_PORT := 54386
endif
STORAGE_DIR ?= $(shell sed -n 's/^STORAGE_DIR=\([^[:space:]]*\).*/\1/p' $(STACK_ENV) 2>/dev/null | head -1)
ifeq ($(strip $(STORAGE_DIR)),)
STORAGE_DIR := ./volumes/storage
endif
DB_CONTAINER := $(STACK_PREFIX)-db
COMPOSE = docker compose $(PUSH_PROFILE) -p $(STACK_PREFIX) --env-file $(STACK_ENV)
export STACK_PREFIX POSTGRES_PORT KONG_HTTP_PORT STORAGE_DIR DB_CONTAINER

PGTAP_DB_URL   ?= postgres://postgres:postgres@localhost:$(POSTGRES_PORT)/postgres?sslmode=disable

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

# ── RevenueCat gate (RCBH) ───────────────────────────────────────────────────
# Same opt-in shape as FCM: `make start RC=true` fetches the env's RevenueCat
# server secrets from the vault (tools/<fetch-rc-secret>.sh, <env>-rc profile) and exports
# them into the compose shell env (shell env overrides --env-file). RC unset/
# false ⇒ no fetch, no secrets ⇒ the webhook function fails closed. staging/prod
# supply these via their vault-merged env instead (no flag).
RC ?= false
RC_ENV ?= testing
ifeq ($(RC),true)
RC_FETCH := eval "$$(VAULT_PROFILE=$(RC_ENV)-rc bash tools/<fetch-rc-secret>.sh)" &&
else
RC_FETCH :=
endif

help:
	@echo "Samay backend — make targets (ENV=local (default) = Docker; ENV=staging|prod = VM + vault)"
	@echo "  SETUP:       init"
	@echo "  DEV/TESTING: start stop status reset nuke seed tunnel in-db logs"
	@echo "  PUSH:        FCM=true (CLI/env only) fetches the vault + runs samay-pushworker (profile fcm; staging/prod always on)"
	@echo "  RC:          RC=true [RC_ENV=testing|staging] (CLI/env only) fetches the vault + enables the revenuecat-webhook function"
	@echo "  SUITES:      test [db|api]        loadtest [smoke]"
	@echo "  BUILD:       build-cli build-linux build-api build-loadtest build-pushworker build-pushworker-image"
	@echo "  GATES:       check lint secrets migrate migrate-adopt fetch-fcm hooks"
	@echo "  ENV:         start ENV=staging|prod   deploy   (VM + vault; local default = Docker)"

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
# Vault-gated env init: reconcile the vault profile (Reuse / Re-generate via the
# broker gate), then clone/register the env's VM (idempotent).
init: guard-prod
	@bash tools/<secret-init>.sh $(APP_DEFAULT) $(ENV)
	@$(MAKE) -C $(INFRA) init PROD=true APP=$(APP)
start: guard-prod
	@$(MAKE) -C $(INFRA) start PROD=true APP=$(APP)
stop: guard-prod
	@echo "prod VM has no stop target (use: make restart PROD=true)"
status: guard-prod
	@$(MAKE) -C $(INFRA) status PROD=true APP=$(APP)
else
init:
	@bash tools/init.sh
preflight:
	@bash tools/check-stack-env.sh "$(STACK_ENV)"
start: preflight
	@$(FCM_FETCH)$(RC_FETCH) cd supabase && $(COMPOSE) up -d && \
		$(COMPOSE) up -d --wait db auth && \
		bash ../tools/apply_migrations.sh supabase && \
		PGPASSWORD=postgres psql -h localhost -p $(POSTGRES_PORT) -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql
stop:
	@cd supabase && $(COMPOSE) down
status:
	@cd supabase && $(COMPOSE) ps
endif

reset: preflight
	@[ "$(PROD)" != "true" ] || { echo "refusing to reset prod via make; run the VM reset explicitly"; exit 1; }
	@$(FCM_FETCH)$(RC_FETCH) cd supabase && $(COMPOSE) down -v && \
		rm -rf $(STORAGE_DIR) && \
		(docker volume rm $(STACK_PREFIX)_db-data $(STACK_PREFIX)_rustfs-data 2>/dev/null || true) && \
		$(COMPOSE) up -d && \
		$(COMPOSE) up -d --wait db auth && \
		bash ../tools/apply_migrations.sh supabase && \
		PGPASSWORD=postgres psql -h localhost -p $(POSTGRES_PORT) -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql

# Stop the stack AND remove its volumes (wiped DB + RustFS + storage bind).
# `stop` keeps volumes; `reset` also restarts/migrates/seeds. Use before a
# fresh `make start`.
nuke:
	@[ "$(PROD)" != "true" ] || { echo "refusing to nuke prod; run the VM reset explicitly"; exit 1; }
	@cd supabase && $(COMPOSE) down -v && \
		rm -rf $(STORAGE_DIR)

seed:
	@cd supabase && $(COMPOSE) exec -T db psql -U postgres -f /dev/stdin -q < seed-test.sql

in-db:
	PGPASSWORD=postgres psql -h localhost -p $(POSTGRES_PORT) -U postgres -d postgres

# Follow one stack service's logs, e.g. `make logs SVC=pushworker`
# (no SVC = all services). `make status` (docker compose ps) lists every
# service, including the `fcm`-profiled `pushworker` when FCM=true.
logs:
	@cd supabase && $(COMPOSE) logs -f --tail=200 $(SVC)

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
	    ANON=$(grep -E '^SUPABASE_ANON_KEY=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    SEC=$$(grep -E '^JWT_SECRET=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    $(LOADTEST_BIN) --url "$(LOADTEST_URL)" --anon-key "$$ANON" --service-key "$$SVC" \
	      --jwt-secret "$$SEC" --yes --run-id "smoke$$(date +%s)" \
	      --users 3 --friendships 3 --groups 1 --events 1 --matches 2 \
	      --workers 4 --duration 8s --realtime 3 ;; \
	  *) \
	    SVC=$$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    ANON=$(grep -E '^SUPABASE_ANON_KEY=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
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
	    bash -c 'nc -z 127.0.0.1 $(POSTGRES_PORT) 2>/dev/null' || { echo "PostgreSQL not reachable on $(POSTGRES_PORT) — make start"; exit 1; }; \
	    command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 1; }; \
	    supabase db test --db-url "$(PGTAP_DB_URL)" -- supabase/tests/schema_test.sql ;; \
	  api) \
	    bash -c 'nc -z 127.0.0.1 $(KONG_HTTP_PORT) 2>/dev/null' || { echo "Kong not reachable on $(KONG_HTTP_PORT) — make start"; exit 1; }; \
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
# Fetch the env's RevenueCat server secrets from the vault (owner-run; prints
# `export KEY=value` lines; nothing on disk). `make start RC=true` calls it.
<fetch-rc-secret>:
	@VAULT_PROFILE=$(RC_ENV)-rc bash tools/<fetch-rc-secret>.sh
hooks:
	@git config core.hooksPath tools/hooks
	@[ -x tools/hooks/pre-commit ] || { echo "tools/hooks/pre-commit missing or not executable"; exit 1; }
	@echo "core.hooksPath -> tools/hooks"
