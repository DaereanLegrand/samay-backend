# Samay backend — local (Docker) stack. VM/staging/prod verbs abort: their
# provisioning and deployment are handled outside this repository.
#
# ENV is the only selector, and it defaults to testing-local so the everyday
# verbs need no flags from this directory:
#   ENV=testing-local | testing | staging | prod
# Two local stacks, two file classes:
#   testing-local — .env/testing-local.env holds secrets + layout (minted).
#   testing       — .env/testing.env is a secret-free LAYOUT; the secrets are
#                   fetched from the vault into a RAM disk at `make start`.
# staging/prod provisioning and deployment are handled outside this repo.
.PHONY: help init regen preflight start stop status restart reset nuke seed in-db logs \
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

# ENV defaults to the local stack so `make init`, `make start`, `make regen` and
# the rest work with no flags from this directory. Only a truly undefined ENV is
# defaulted: a command-line value wins, and so does an inherited one.
ifeq ($(origin ENV),undefined)
ENV := testing-local
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
# ONE stack per environment, each with its own compose project, port block and
# storage dir. Env files live in .env/ at this repo root.
# Two file classes, and they never mix:
#
#   .env/testing-local.env  SECRETS + layout. `make init` mints the JWT and the
#                           anon/service keys here. The only file-fed env.
#   .env/testing.env        LAYOUT ONLY (ports, stack identity, toggles). Public
#                           URLs, client ids and every secret come from the
#                           vault at `make start` and live on the RAM disk.
#
# Both live at the repo root so a standalone clone is self-contained.
#
# staging/prod are provisioned outside this repository.
SAMAY_ENV_DIR               := $(CURDIR)/.env
ENV_STACK_ENV_testing       := $(SAMAY_ENV_DIR)/testing.env
ENV_STACK_ENV_testing-local := $(SAMAY_ENV_DIR)/testing-local.env
STACK_ENV ?= $(or $(ENV_STACK_ENV_$(ENV)),$(SAMAY_ENV_DIR)/testing-local.env)

# ONE RAM disk per verb, same rule as the frontend Makefile: `deploy`-style
# verbs fetch several profiles and every consumer reads the same path, so the
# tag is computed once (:= , never ?= with $(shell)) and exported.
ifeq ($(origin RAM_TAG),undefined)
RAM_TAG := $(shell od -An -N3 -tu4 /dev/urandom | tr -d ' ')
endif
RAM_DIR ?= /Volumes/SamayRAM-$(RAM_TAG)
export RAM_TAG RAM_DIR
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
# to disk, and never in an env file).
PUSH_PROFILE := $(if $(filter true,$(FCM)),--profile fcm,)
FCM_FETCH :=

# ── RevenueCat secrets (RCBH) ────────────────────────────────────────────────
# The revenuecat-webhook service is NOT profile-gated: it always starts and
# reads REVENUECAT_API_KEY / REVENUECAT_WEBHOOK_SECRET from the inherited
# shell/compose environment, failing closed when the webhook secret is absent.
# `RC` is forwarded to the vault fetch, but this repo only ever fetches the
# `server` profile, where `release-secrets.sh` returns before its RC block —
# so `RC=true` changes nothing here. Export the secrets instead.
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
echo "ENV=$(ENV): staging/prod are provisioned and deployed outside this repository; this repo only runs testing-local/testing. See README → Requirements."; exit 1
endef

help:
	@echo "Samay backend — ENV=<testing-local|testing|staging|prod> (default testing-local)"
	@echo "  SETUP:       init [ENV=…]"
	@echo "  VALUES:      regen [ENV=…] [REGEN_UNITS=\"rustfs realtime\"] [YES=1]"
	@echo "  DEV/TESTING: start stop restart status reset nuke seed in-db logs"
	@echo "  PUSH:        FCM=true runs samay-pushworker (profile fcm)"
	@echo "  RC:          inert here — export REVENUECAT_WEBHOOK_SECRET instead;"
	@echo "               revenuecat-webhook always runs, fails closed w/o secret"
	@echo "  SUITES:      test [db|api]        loadtest [smoke]"
	@echo "  BUILD:       build-cli build-linux build-api build-loadtest build-pushworker build-pushworker-image build-billingworker"
	@echo "  GATES:       check lint secrets migrate migrate-adopt hooks"
	@echo "  TUNNEL:      not managed here — point the Cloudflare public hostname"
	@echo "               at http://localhost:$(KONG_HTTP_PORT) on this host."

preflight:
	@bash tools/check-stack-env.sh "$(STACK_ENV)" "$(ENV)"

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

# ── Values: one engine, two destinations ─────────────────────────────────────
# tools/secrets.sh owns the definition of "generated" and the unit vocabulary,
# so `init` and `regen` can never drift from each other or from the vault
# broker's manifest. It is IN THIS REPO, so a standalone clone can mint the
# local stack's values with no private tooling:
#
#   init   ensure every generated value exists; never replaces one
#   regen  replace them (all units, or REGEN_UNITS="...") after a gum confirm
#
# Destination follows ENV:
#   testing-local        → .env/testing-local.env, vault never contacted
#   testing|staging|prod → the vault profile, via the broker's `regen` (SSH)
SECRETS_TOOL ?= $(CURDIR)/tools/secrets.sh

init-local: guard-env
	@if [ "$(ENV)" = "testing" ]; then \
	  bash "$(SECRETS_TOOL)" init --vault samay testing; \
	else \
	  ENV=$(ENV) bash tools/init.sh; \
	fi
init-vm: guard-env
	@$(call require_vm)

# YES=1 skips the confirmation (for scripted runs); the default is to ask.
REGEN_YES := $(if $(filter 1 true yes,$(YES)),--yes,)
regen: guard-env
	@case "$(ENV)" in \
	  testing-local) bash "$(SECRETS_TOOL)" regen --file "$(SAMAY_ENV_DIR)/testing-local.env" $(REGEN_YES) $(REGEN_UNITS) ;; \
	  testing)       bash "$(SECRETS_TOOL)" regen --vault samay testing $(REGEN_YES) $(REGEN_UNITS) ;; \
	  staging)       bash "$(SECRETS_TOOL)" regen --vault samay staging $(REGEN_YES) $(REGEN_UNITS) ;; \
	  prod)          bash "$(SECRETS_TOOL)" regen --vault samay prod $(REGEN_YES) $(REGEN_UNITS) ;; \
	esac

# `testing` fetches the FULL vault profile (testing/server/*) and runs on those
# secrets; `testing-local` runs on $(SAMAY_ENV_DIR)/testing-local.env alone.
# tools/start-stack.sh owns the RAM disk and wipes it on EVERY exit path, so
# nothing survives the verb. See the RAM DISCIPLINE note in that script.
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
	@$(MAKE) stop ENV=$(ENV) && $(MAKE) start ENV=$(ENV)
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
	@RESET=1 FCM=$(FCM) RC=$(RC) bash tools/start-stack.sh "$(ENV)"

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
	    SVC=$$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' $(SAMAY_ENV_DIR)/testing-local.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    ANON=$(grep -E '^SUPABASE_ANON_KEY=' $(SAMAY_ENV_DIR)/testing-local.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    SEC=$$(grep -E '^JWT_SECRET=' $(SAMAY_ENV_DIR)/testing-local.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    $(LOADTEST_BIN) --url "$(LOADTEST_URL)" --anon-key "$$ANON" --service-key "$$SVC" \
	      --jwt-secret "$$SEC" --yes --run-id "smoke$$(date +%s)" \
	      --users 3 --friendships 3 --groups 1 --events 1 --matches 2 \
	      --workers 4 --duration 8s --realtime 3 ;; \
	  *) \
	    SVC=$$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' $(SAMAY_ENV_DIR)/testing-local.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    ANON=$(grep -E '^SUPABASE_ANON_KEY=' $(SAMAY_ENV_DIR)/testing-local.env | head -1 | cut -d= -f2- | tr -d '"'); \
	    SEC=$$(grep -E '^JWT_SECRET=' $(SAMAY_ENV_DIR)/testing-local.env | head -1 | cut -d= -f2- | tr -d '"'); \
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
