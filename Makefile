# Samay backend — local (Docker) + VM (staging/prod). Supabase-only stack.
#
# APP and ENV are explicit inputs (no defaults):
#   APP=samay
#   ENV=testing-local | testing | staging | prod
# testing-local and testing both run Docker on the host; the only difference is
# the public URL written to supabase/.env. The Cloudflare tunnel is NOT managed
# here — it is configured in the Cloudflare dashboard and terminated there; the
# only requirement is that its public hostname points at Kong on this host.
# staging/prod provisioning and deployment are handled outside this repo.
.PHONY: help init preflight start stop status restart reset nuke seed in-db logs \
        build-cli build-linux build-api build-loadtest build-pushworker build-pushworker-image build-billingworker loadtest \
        test check lint secrets migrate migrate-adopt hooks preflight \
        db api smoke

.NOTPARALLEL:

ifneq ($(filter command line environment,$(origin PROD)),)
$(error PROD is not an input; use ENV=testing-local|testing|staging|prod)
endif
ifneq ($(filter command line environment,$(origin TESTING)),)
$(error TESTING is not an input; use ENV=testing-local)
endif

GO_BIN         := samay
GO_BIN_LINUX   := samay-linux
LOADTEST_BIN   := ./samay-loadtest
PUSHWORKER_BIN := ./samay-pushworker
BILLINGWORKER_BIN := ./samay-billing-worker
# Image tag the VM stack expects (vm.env.template PUSHWORKER_IMAGE).
PUSHWORKER_IMAGE_TAG ?= samay-pushworker:prod
LOADTEST_URL   ?= https://samay-api.qallariy.lat
LOADTEST_ARGS  ?=
# ── Stack isolation ───────────────────────────────────────────────────────────
# Defaults preserve the single-stack setup. For a parallel/disposable stack:
#   make start STACK_PREFIX=samay-a STACK_ENV=/tmp/samay-a.env
# The env file carries STACK_PREFIX, COMPOSE_PROJECT_NAME, the 55xxx port map,
# and STORAGE_DIR. Never commit it.
# Every environment gets its OWN stack: its own env file, compose project,
# port block and storage dir. testing (vault-fed) and testing-local (locally
# minted) therefore run simultaneously without sharing a container, volume or
# port — and never share a secret generation, which is what made a
# testing-built app answer "Unauthorized" to a testing-local stack.
# STACK_ENV still overrides for a disposable stack.
ENV_STACK_ENV_testing       := $(CURDIR)/supabase/testing.env
ENV_STACK_ENV_testing-local := $(CURDIR)/supabase/testing-local.env
STACK_ENV ?= $(or $(ENV_STACK_ENV_$(ENV)),$(CURDIR)/supabase/.env)
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

# ── Push worker opt-in ───────────────────────────────────────────────────────
# The push worker (`samay-pushworker`) ships behind the `fcm` compose profile.
# `make start FCM=true` opts testing in. The FCM service account is supplied by
# the caller in SUPABASE_FCM_SERVICE_ACCOUNT_JSON_B64 (shell env; never written
# to disk, and never in supabase/.env).
PUSH_PROFILE := $(if $(filter true,$(FCM)),--profile fcm,)
FCM_FETCH :=

# ── RevenueCat opt-in (RCBH) ─────────────────────────────────────────────────
# `make start RC=true` enables the revenuecat-webhook function. Its server
# secrets (REVENUECAT_API_KEY, REVENUECAT_WEBHOOK_SECRET, …) are supplied by the
# caller in the shell environment. RC unset/false ⇒ the webhook function fails
# closed.
RC ?= false
RC_ENV ?= testing
RC_FETCH :=

define require_env
case "$(ENV)" in testing-local|testing|staging|prod) ;; *) echo "ENV is required: testing-local|testing|staging|prod"; exit 2;; esac
endef

define require_local
case "$(ENV)" in testing-local|testing) ;; *) echo "ENV=$(ENV): local-only verb (testing-local|testing)"; exit 2;; esac
endef

define require_vm
case "$(ENV)" in staging|prod) ;; *) echo "ENV=$(ENV): VM verb (staging|prod)"; exit 2;; esac; \
[ -n "$(APP)" ] || { echo "APP is required"; exit 2; }; \
echo "ENV=$(ENV): staging/prod are provisioned and deployed outside this repository; this repo only runs testing-local/testing. See README → Requirements."; exit 1
endef

help:
	@echo "Samay backend — APP=<samay> ENV=<testing-local|testing|staging|prod>"
	@echo "  SETUP:       init"
	@echo "  DEV/TESTING: start stop restart status reset nuke seed in-db logs"
	@echo "  PUSH:        FCM=true runs samay-pushworker (profile fcm)"
	@echo "  RC:          RC=true enables the revenuecat-webhook function"
	@echo "  SUITES:      test [db|api]        loadtest [smoke]"
	@echo "  BUILD:       build-cli build-linux build-api build-loadtest build-pushworker build-pushworker-image build-billingworker"
	@echo "  GATES:       check lint secrets migrate migrate-adopt hooks"
	@echo "  TUNNEL:      not managed here — point the Cloudflare public hostname"
	@echo "               at http://localhost:$(KONG_HTTP_PORT) on this host."

preflight:
	@bash tools/check-stack-env.sh "$(STACK_ENV)"

# ── Lifecycle: Docker for testing-local/testing. staging/prod are out of scope. ─
guard-env:
	@$(call require_env)

ifeq ($(filter staging prod,$(ENV)),)
init: init-local
start: start-local
restart: restart-local
status: status-local
else
init: init-vm
start: start-vm
restart: restart-vm
status: status-vm
endif

init-local: guard-env
	@ENV=$(ENV) bash tools/init.sh
init-vm: guard-env
	@$(call require_vm)

# `testing` fetches the FULL vault profile (testing/server/*) and runs on those
# secrets; `testing-local` runs on supabase/.env alone. tools/start-stack.sh
# owns the RAM disk and wipes it on EVERY exit path, so nothing survives the
# verb. See the RAM DISCIPLINE note in that script.
start-local: guard-env preflight
	@FCM=$(FCM) RC=$(RC) bash tools/start-stack.sh "$(ENV)"
start-vm: guard-env
	@$(call require_vm)

stop: guard-env
	@case "$(ENV)" in \
	  testing-local|testing) ( cd supabase && $(COMPOSE) down ) ;; \
	  staging|prod) echo "ENV=$(ENV): staging/prod are provisioned and deployed outside this repository; this repo only runs testing-local/testing."; exit 1 ;; \
	esac

restart-local: guard-env
	@$(MAKE) stop APP=$(APP) ENV=$(ENV) && $(MAKE) start APP=$(APP) ENV=$(ENV)
restart-vm: guard-env
	@$(call require_vm)

status-local: guard-env
	@case "$(ENV)" in \
	  testing-local|testing) ( cd supabase && $(COMPOSE) ps ); \
	    echo "Kong: http://localhost:$(KONG_HTTP_PORT)"; ;; \
	esac
status-vm: guard-env
	@$(call require_vm)

reset: preflight
	@$(call require_env)
	@$(call require_local)
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
	@$(call require_env)
	@$(call require_local)
	@cd supabase && $(COMPOSE) down -v && \
		rm -rf $(STORAGE_DIR)

seed:
	@$(call require_local)
	@cd supabase && $(COMPOSE) exec -T db psql -U postgres -f /dev/stdin -q < seed-test.sql

in-db:
	@$(call require_local)
	PGPASSWORD=postgres psql -h localhost -p $(POSTGRES_PORT) -U postgres -d postgres

# Follow one stack service's logs, e.g. `make logs SVC=pushworker`
# (no SVC = all services). `make status` (docker compose ps) lists every
# service, including the `fcm`-profiled `pushworker` when FCM=true.
logs:
	@$(call require_local)
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
build-billingworker:
	go build -o $(BILLINGWORKER_BIN) ./cmd/samay-billing-worker

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
	@if command -v golangci-lint >/dev/null 2>&1; then golangci-lint run ./...; else go vet ./...; fi

secrets:
	@tools/check_secrets.sh
migrate:
	@tools/check_migrations.sh
# One-time, per pre-ledger database: record the existing baseline WITHOUT
# re-running it, so `make start` only applies pending migrations from then on.
# Never needed after `make reset` (fresh -> ledger fills as files run).
migrate-adopt:
	@$(call require_local)
	@bash tools/apply_migrations.sh supabase adopt
hooks:
	@git config core.hooksPath tools/hooks
	@[ -x tools/hooks/pre-commit ] || { echo "tools/hooks/pre-commit missing or not executable"; exit 1; }
	@echo "core.hooksPath -> tools/hooks"
