# Samay backend — Go CLI/API + self-hosted Supabase.
.PHONY: help build-cli build-linux build-api build-loadtest loadtest loadtest-smoke \
        test test-all test-backend-static test-go check lint secrets-check migrate-check install-hooks \
        supabase-start supabase-stop supabase-status supabase-reset supabase-init \
        supabase-seed-config supabase-seed-test in-db supabase-db-test supabase-backend-tests supabase-stack-check \
        supabase-testing-start supabase-testing-stop supabase-testing-status supabase-testing-reset supabase-testing-init \
        supabase-testing-seed-sample-matches

GO_BIN         := samay
GO_BIN_LINUX   := samay-linux
LOADTEST_BIN   := ./samay-loadtest
LOADTEST_URL   ?= https://samay-api.qallariy.lat
LOADTEST_ARGS  ?=
OVERRIDES      ?=
PGTAP_DB_URL   ?= postgres://postgres:postgres@localhost:54382/postgres?sslmode=disable

# Export local env files into recipe shells; never echo the values.
define load-env
set -a; [ -r ./.env.local ] && . ./.env.local || true; [ -r ./.env ] && . ./.env || true; set +a
endef

help:
	@echo "Samay backend — make targets"
	@echo "  GO:        build-cli build-linux build-api build-loadtest loadtest loadtest-smoke"
	@echo "  TESTS:     test test-all test-backend-static test-go"
	@echo "  GATES:     check lint secrets-check migrate-check install-hooks"
	@echo "  PROD DB:   supabase-start|stop|status|reset|init supabase-seed-config supabase-seed-test in-db"
	@echo "  TEST DB:   supabase-testing-start|stop|status|reset|init supabase-testing-seed-sample-matches"
	@echo "  DB TESTS:  supabase-db-test supabase-backend-tests supabase-stack-check"

# ── Go ───────────────────────────────────────────────────────────────────────
build-cli:
	go build -o $(GO_BIN) ./cmd/samay-admin

build-linux:
	GOOS=linux GOARCH=amd64 go build -o $(GO_BIN_LINUX) ./cmd/samay-admin

build-api:
	go build -o samay-api-server ./cmd/samay-api-server

build-loadtest:
	go build -o $(LOADTEST_BIN) ./cmd/samay-loadtest

loadtest: build-loadtest
	@SVC=$$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	 ANON=$$(grep -E '^SUPABASE_ANON_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"'); \
	 SEC=$$(grep -E '^JWT_SECRET=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	 echo "loadtest -> $(LOADTEST_URL) (creates data; no cleanup)"; \
	 $(LOADTEST_BIN) --url "$(LOADTEST_URL)" --anon-key "$$ANON" --service-key "$$SVC" \
	   --jwt-secret "$$SEC" --yes $(LOADTEST_ARGS)

loadtest-smoke: build-loadtest
	@SVC=$$(grep -E '^SUPABASE_SERVICE_ROLE_KEY=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	 ANON=$$(grep -E '^SUPABASE_ANON_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"'); \
	 SEC=$$(grep -E '^JWT_SECRET=' supabase/.env | head -1 | cut -d= -f2- | tr -d '"'); \
	 echo "loadtest-smoke -> $(LOADTEST_URL) (creates data; no cleanup)"; \
	 $(LOADTEST_BIN) --url "$(LOADTEST_URL)" --anon-key "$$ANON" --service-key "$$SVC" \
	   --jwt-secret "$$SEC" --yes --run-id "smoke$$(date +%s)" \
	   --users 3 --friendships 3 --groups 1 --events 1 --matches 2 \
	   --workers 4 --duration 8s --realtime 3

# ── Tests ────────────────────────────────────────────────────────────────────
test: test-all

test-all: test-go test-backend-static

test-backend-static:
	bash test/opt-005-seeds-static.sh
	bash test/opt-007-compose-static.sh
	bash test/opt-008-makefile-static.sh

test-go:
	go test ./...

# ── Gates ────────────────────────────────────────────────────────────────────
check: secrets-check
	go vet ./...
	@UNFMT="$$(gofmt -l cmd internal)"; if [ -n "$$UNFMT" ]; then echo "gofmt: unformatted Go files:"; echo "$$UNFMT"; exit 1; fi
	tools/check_ports.sh --strict

lint:
	@command -v golangci-lint >/dev/null 2>&1 && golangci-lint run ./... || go vet ./...

secrets-check:
	@tools/check_secrets.sh

migrate-check:
	@tools/check_migrations.sh

install-hooks:
	@git config core.hooksPath tools/hooks
	@[ -x tools/hooks/pre-commit ] || { echo "tools/hooks/pre-commit missing or not executable"; exit 1; }
	@echo "core.hooksPath -> tools/hooks"

# ── Supabase prod stack (humans only) ────────────────────────────────────────
supabase-start:
	$(load-env)
	cd supabase && docker compose $(OVERRIDES) up -d --wait

supabase-stop:
	$(load-env)
	cd supabase && docker compose $(OVERRIDES) down

supabase-status:
	$(load-env)
	cd supabase && docker compose $(OVERRIDES) ps

supabase-reset:
	$(load-env)
	cd supabase && docker compose down && rm -rf volumes/storage && (docker volume rm samay_db-data samay_rustfs-data 2>/dev/null || true) && docker compose $(OVERRIDES) up -d && docker compose $(OVERRIDES) up -d --wait db auth && bash ../tools/apply_migrations.sh supabase && PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql

supabase-init:
	$(load-env)
	cd supabase && docker compose $(OVERRIDES) up -d --wait && bash ../tools/apply_migrations.sh supabase && PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql

supabase-seed-config:
	cd supabase && PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql

supabase-seed-test:
	cd supabase && PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-test.sql

in-db:
	$(load-env)
	@bash -c 'nc -z 127.0.0.1 $${POSTGRES_PORT:-54382} 2>/dev/null' || { echo "PostgreSQL not reachable on $${POSTGRES_PORT:-54382}"; exit 1; }
	PGPASSWORD=postgres psql -h localhost -p $${POSTGRES_PORT:-54382} -U postgres -d postgres

supabase-db-test:
	@bash -c 'nc -z 127.0.0.1 54382 2>/dev/null' || { echo "PostgreSQL not reachable on 54382"; exit 1; }
	@command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 1; }
	supabase db test --db-url "$(PGTAP_DB_URL)" -- supabase/tests/schema_test.sql

supabase-backend-tests:
	@bash -c 'nc -z 127.0.0.1 54386 2>/dev/null' || { echo "Kong not reachable on 54386"; exit 1; }
	bash test/run_all_backend.sh

supabase-stack-check:
	bash test/opt-005-seeds-static.sh
	bash test/opt-007-compose-static.sh
	tools/check_ports.sh --strict

# ── Supabase testing stack (agents) ──────────────────────────────────────────
supabase-testing-start:
	$(load-env)
	cd supabase-testing && docker compose $(OVERRIDES) up -d --wait

supabase-testing-stop:
	$(load-env)
	cd supabase-testing && docker compose $(OVERRIDES) down

supabase-testing-status:
	$(load-env)
	cd supabase-testing && docker compose $(OVERRIDES) ps

supabase-testing-reset:
	$(load-env)
	cd supabase-testing && docker compose down && rm -rf volumes/storage && (docker volume rm samay-testing_db-data samay-testing_rustfs-data 2>/dev/null || true) && docker compose $(OVERRIDES) up -d && docker compose $(OVERRIDES) up -d --wait db auth && bash ../tools/apply_migrations.sh supabase-testing && PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql

supabase-testing-init:
	$(load-env)
	cd supabase-testing && docker compose $(OVERRIDES) up -d --wait && bash ../tools/apply_migrations.sh supabase-testing && PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql

supabase-testing-seed-sample-matches:
	bash supabase-testing/seed-sample-matches.sh
