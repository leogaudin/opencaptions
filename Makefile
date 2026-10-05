# OpenCaptions — lifecycle targets. Run `make` for the list.
# Plain `docker compose` works too: every stack target is a thin alias.

API         := cd apps/api && uv run
WEB         := cd apps/web && npm run
# Built on first use (with a cargo cache volume chowned to the caller, as ci-local.sh does): the stock image lacks clippy, rustfmt and the WebAssembly and iOS targets.
ENGINE_IMG  := opencaptions-ci-engine:local
ENGINE      := (docker image inspect $(ENGINE_IMG) >/dev/null 2>&1 || printf '%s\n' \
	'FROM rust:1.94-slim-bookworm' 'RUN rustup component add rustfmt clippy' \
	'RUN rustup target add wasm32-unknown-unknown aarch64-apple-ios' | docker build -q -t $(ENGINE_IMG) - >/dev/null) \
	&& docker run --rm -v opencaptions-ci-cargo:/cargo $(ENGINE_IMG) chown "$$(id -u):$$(id -g)" /cargo \
	&& docker run --rm --user "$$(id -u):$$(id -g)" -e CARGO_HOME=/cargo \
	-v opencaptions-ci-cargo:/cargo -v "$$PWD/apps/engine":/w -w /w $(ENGINE_IMG)

.DEFAULT_GOAL := help

help:                ## Show this help
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- Acceptance gate ------------------------------------------------------
# `make ci` is the Definition of Done: it runs everything GitHub CI runs except
# publishing, from a clean snapshot, against a disposable stack.

ci:                  ## ACCEPTANCE GATE: full local CI (never touches your data)
	@./scripts/ci-local.sh

ci-staged:           ## Like ci, but validates HEAD + staged changes (pre-commit)
	@./scripts/ci-local.sh --staged

ci-static:           ## Like ci, minus image builds and e2e (fast)
	@./scripts/ci-local.sh --no-e2e

# --- Stack ----------------------------------------------------------------

up:                  ## Build and start the stack
	@docker compose up -d --build

watch:               ## Build, start, and rebuild or restart on source changes
	@docker compose watch

down:                ## Stop the stack
	@docker compose down

logs:                ## Tail logs from all services
	@docker compose logs -f

rebuild:             ## Rebuild all images from scratch, keeping volumes
	@docker compose build --no-cache && docker compose up -d

clean:               ## Stop the stack and DELETE all its data
	@docker compose down -v

# --- Checks ---------------------------------------------------------------

lint: lint-backend lint-frontend   ## Run all linters

lint-backend:        ## Lint Python (ruff + mypy)
	@$(API) ruff check . && $(API) mypy app/

lint-frontend:       ## Lint TS/JS (biome)
	@$(WEB) lint

typecheck:           ## Typecheck web project references
	@$(WEB) typecheck

test-backend:        ## Run pytest
	@$(API) pytest

test-engine:         ## Run the engine's tests
	@$(ENGINE) cargo test

engine-wasm:         ## Build the engine for the browser into apps/web/public/engine (for npm run dev)
	@docker build -q --build-context engine=apps/engine --target preview-assets \
	 -o apps/web/public/engine apps/web >/dev/null && echo "Wrote apps/web/public/engine"

format:              ## Auto-format all code
	@$(API) ruff format . && $(API) ruff check --fix .
	@$(WEB) format
	@$(ENGINE) cargo fmt

generate-types:      ## Regenerate TypeScript types from the OpenAPI spec
	@$(WEB) generate-types

typegen-check:       ## Regenerate types and fail if the committed file is stale
	@./scripts/generate-api-types.sh
	@git diff --exit-code -- apps/web/src/types/api.generated.ts

check-versions:      ## Verify the manifests agree on the version
	@./scripts/check-version-sync.sh

check-compose:       ## Verify docker-compose.yml's fallbacks agree with each other and the code
	@./scripts/check-compose.sh

# --- Operations -----------------------------------------------------------

migration:           ## New migration. Usage: make migration MSG="add foo"
	@docker compose exec -T api /app/.venv/bin/alembic revision --autogenerate -m "$(MSG)"

shell-api:           ## Open a shell in the api container
	@docker compose exec api /bin/bash

psql:                ## Open psql against the running postgres
	@docker compose exec postgres psql -U opencaptions opencaptions

# Storage is read through the garage container's own mounts (--volumes-from),
# so no volume name is guessed. The garage image has no shell, hence alpine.
STORAGE = docker run --rm --volumes-from "$$(docker compose ps -aq garage)" \
	-v "$$PWD/backups:/backups" alpine

backup:              ## Snapshot Postgres + object storage to ./backups/
	@mkdir -p backups
	@TS=$$(date +%Y%m%d-%H%M%S); set -e; \
	 docker compose exec -T postgres pg_dump -U opencaptions opencaptions > backups/db-$$TS.sql; \
	 $(STORAGE) sh -c "tar -czf /backups/storage-$$TS.tar.gz -C /var/lib/garage . \
	   && chown $$(id -u):$$(id -g) /backups/storage-$$TS.tar.gz"; \
	 echo "Wrote backups/db-$$TS.sql and backups/storage-$$TS.tar.gz"

restore:             ## Restore a snapshot. Usage: make restore TS=YYYYMMDD-HHMMSS
	@test -n "$(TS)" || (echo "Usage: make restore TS=YYYYMMDD-HHMMSS"; exit 1)
	@echo "This OVERWRITES the current database and object storage. Continue? [y/N]"
	@read ans; [ "$${ans:-N}" = "y" ] || exit 1
	@set -e; \
	 docker compose exec -T postgres psql -U opencaptions -d postgres \
	   -c 'DROP DATABASE IF EXISTS opencaptions WITH (FORCE);' -c 'CREATE DATABASE opencaptions;'; \
	 docker compose exec -T postgres psql -U opencaptions opencaptions < backups/db-$(TS).sql; \
	 docker compose stop garage; \
	 $(STORAGE) sh -c 'rm -rf /var/lib/garage/* && tar -xzf /backups/storage-$(TS).tar.gz -C /var/lib/garage'; \
	 docker compose start garage

# Derived rather than hand-listed: a stale entry makes Make skip a recipe and
# report the target up to date.
.PHONY: $(shell sed -n 's/^\([a-z][a-z-]*\):.*/\1/p' $(firstword $(MAKEFILE_LIST)))
