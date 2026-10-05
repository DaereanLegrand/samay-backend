# Samay backend — local (Docker) + prod (VM + vault).
.PHONY: help init tunnel start stop status reset seed db-test backend-tests in-db \
        build-cli build-linux build-api build-loadtest loadtest loadtest-smoke \
        test test-static test-go check lint secrets-check migrate-check install-hooks

APP       := samay
QVM_APP   ?= samay
INFRA     ?= ../../<private-ops-repo>
PROD      ?= false
TUNNEL    ?= quick
GO_BIN         := samay
GO_BIN_LINUX   := samay-linux
LOADTEST_BIN   := ./samay-loadtest
LOADTEST_URL   ?= https://samay-api.qallariy.lat
LOADTEST_ARGS  ?=
PGTAP_DB_URL   ?= postgres://postgres:postgres@localhost:54382/postgres?sslmode=disable

help:
	@echo "Samay backend — make targets"
	@echo "  SETUP:   init            interactive local setup (.env, mode)"
	@echo "  LOCAL:   start stop status reset seed db-test backend-tests in-db"
	@echo "           tunnel [MODE=quick|named|stop]"
	@echo "  PROD:    start PROD=true (VM + vault)   status PROD=true"
	@echo "  BUILD:   build-cli build-linux build-api build-loadtest loadtest loadtest-smoke"
	@echo "  GATES:   check lint secrets-check migrate-check install-hooks test test-static test-go"

init:
	@bash tools/init.sh

tunnel:
	@MODE=$(TUNNEL) bash tools/tunnel.sh $(TUNNEL)

# ── Lifecycle: local Docker by default, VM + vault when PROD=true ────────────
start:
	@if [ "$(PROD)" = "true" ]; then \
		make -C $(INFRA) supabase-prod-start QVM_APP=$(QVM_APP); \
	else \
		cd supabase && docker compose --env-file .env up -d --wait && \
		bash ../tools/apply_migrations.sh supabase && \
		PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql; \
	fi

stop:
	@if [ "$(PROD)" = "true" ]; then \
		echo "prod VM has no stop target (use: make -C $(INFRA) supabase-prod-restart QVM_APP=$(QVM_APP))"; \
	else \
		cd supabase && docker compose --env-file .env down; \
	fi

status:
	@if [ "$(PROD)" = "true" ]; then \
		make -C $(INFRA) supabase-prod-status QVM_APP=$(QVM_APP); \
	else \
		cd supabase && docker compose --env-file .env ps; \
	fi

reset:
	@if [ "$(PROD)" = "true" ]; then \
		echo "refusing to reset prod via make; run the VM reset explicitly"; exit 1; \
	else \
		cd supabase && docker compose --env-file .env down -v && \
		rm -rf volumes/storage && \
		(docker volume rm samay_db-data samay_rustfs-data 2>/dev/null || true) && \
		docker compose --env-file .env up -d --wait && \
		bash ../tools/apply_migrations.sh supabase && \
		PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres -v ON_ERROR_STOP=1 -f seed-config.sql; \
	fi

seed:
	@cd supabase && docker compose --env-file .env exec -T db psql -U postgres -f /dev/stdin -q < seed-test.sql

db-test:
	@bash -c 'nc -z 127.0.0.1 54382 2>/dev/null' || { echo "PostgreSQL not reachable on 54382 — make start"; exit 1; }
	@command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 1; }
	supabase db test --db-url "$(PGTAP_DB_URL)" -- supabase/tests/schema_test.sql

backend-tests:
	@bash -c 'nc -z 127.0.0.1 54386 2>/dev/null' || { echo "Kong not reachable on 54386 — make start"; exit 1; }
	bash test/run_all_backend.sh

in-db:
	PGPASSWORD=postgres psql -h localhost -p 54382 -U postgres -d postgres

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
	 $(LOADTEST_BIN) --url "$(LOADTEST_URL)" --anon-key "$$ANON" --service-key "$$SVC" \
	   --jwt-secret "$$SEC" --yes --run-id "smoke$$(date +%s)" \
	   --users 3 --friendships 3 --groups 1 --events 1 --matches 2 \
	   --workers 4 --duration 8s --realtime 3

# ── Gates / tests ────────────────────────────────────────────────────────────
test: test-go test-static
test-static:
	bash test/opt-005-seeds-static.sh
	bash test/opt-008-makefile-static.sh
test-go:
	go test ./...

check: secrets-check
	go vet ./...
	@UNFMT="$$(gofmt -l cmd internal)"; if [ -n "$$UNFMT" ]; then echo "gofmt: unformatted Go files:"; echo "$$UNFMT"; exit 1; fi

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
