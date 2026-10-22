# OpenCaptions, lifecycle targets. Run `make` for the list.
# Plain `docker compose` works too: every stack target is a thin alias.

API         := cd apps/api && uv run
WEB         := cd apps/web && npm run
ENGINE      := ./scripts/engine-shell.sh

.DEFAULT_GOAL := help

help:                ## Show this help
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- Acceptance gate ------------------------------------------------------
# `make ci` is the Definition of Done: it runs everything GitHub CI runs except
# publishing, from a clean snapshot, against a disposable stack. GitHub CI runs the same
# CI_CHECKS, one job each, so a check is added in one place: its target below, named here.

# The checks, in the order the local gate runs them. Each is a target that runs in its pinned container.
CI_STATIC_CHECKS := lint-actions check-repo lint-backend test-backend lint-engine test-engine \
	typegen-check lint-frontend typecheck test-web build-web
CI_HEAVY_CHECKS := build-demo build-docs e2e
CI_CHECKS := $(CI_STATIC_CHECKS) $(CI_HEAVY_CHECKS)

ci:                  ## ACCEPTANCE GATE: full local CI (never touches your data)
	@./scripts/ci-local.sh

ci-staged:           ## Like ci, but validates HEAD + staged changes (pre-commit)
	@./scripts/ci-local.sh --staged

ci-static:           ## Like ci, minus image builds and e2e (fast)
	@./scripts/ci-local.sh --no-e2e

ci-checks:           ## The checks, one per word (what `make ci` runs)
	@echo $(CI_CHECKS)

ci-static-checks:    ## The checks without images, sites and e2e
	@echo $(CI_STATIC_CHECKS)

ci-list:             ## The checks, as a JSON array (what GitHub CI runs)
	@printf '[%s]\n' "$$(printf '"%s",' $(CI_CHECKS) | sed 's/,$$//')"

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
# One target per check, each in its pinned container against this checkout (scripts/ci-shell.sh,
# scripts/engine-shell.sh), so a contributor and GitHub CI run the same thing.

NPM_CI := npm ci --no-audit --no-fund >/dev/null
UV_SYNC := uv sync --extra dev --locked -q

lint: lint-backend lint-frontend   ## Run all linters

lint-actions:        ## Lint the workflows (actionlint)
	@docker run --rm -v "$(CURDIR)":/repo:ro -w /repo rhysd/actionlint:1.7.12 -no-color \
	 .github/workflows/ci.yml .github/workflows/ios.yml .github/workflows/cla.yml

check-repo:          ## Repository guards: manifest versions, compose fallbacks, iOS purpose strings
	@./scripts/ci-shell.sh node . 'bash scripts/check-version-sync.sh && bash scripts/check-compose.sh && bash scripts/check-ios-strings.sh'

lint-backend:        ## Lint Python (ruff check and format, mypy)
	@./scripts/ci-shell.sh uv apps/api '$(UV_SYNC) && uv run ruff check . && uv run ruff format --check . && uv run mypy app/'

test-backend:        ## Run pytest
	@./scripts/ci-shell.sh uv apps/api '$(UV_SYNC) && uv run pytest -q'

lint-engine:         ## Engine format and clippy (server, WebAssembly, iOS)
	@$(ENGINE) sh -euc 'cargo fmt --check \
	 && cargo clippy --locked --all-targets --features server -q -- -D warnings \
	 && cargo clippy --locked --lib --target wasm32-unknown-unknown -q -- -D warnings \
	 && cargo clippy --locked --lib --target aarch64-apple-ios -q -- -D warnings'

test-engine:         ## Run the engine's tests
	@$(ENGINE) cargo test --locked --features server -q

typegen-check:       ## Regenerate the TypeScript API types and fail if the committed file is stale
	@./scripts/ci-shell.sh tools . '(cd apps/api && $(UV_SYNC)) && (cd apps/web && $(NPM_CI)) && bash scripts/generate-api-types.sh'
	@git diff --exit-code -- apps/web/src/types/api.generated.ts \
	 || { echo "apps/web/src/types/api.generated.ts is stale, run 'make generate-types' and commit" >&2; exit 1; }

lint-frontend:       ## Lint TS/JS (biome)
	@./scripts/ci-shell.sh node apps/web '$(NPM_CI) && npm run lint'

typecheck:           ## Typecheck the web project references
	@./scripts/ci-shell.sh node apps/web '$(NPM_CI) && npm run typecheck'

test-web:            ## Run the web unit tests
	@./scripts/ci-shell.sh node apps/web '$(NPM_CI) && npm test'

build-web:           ## Build the web app for production
	@./scripts/ci-shell.sh node apps/web '$(NPM_CI) && npm run build'

build-demo:          ## Build the public demo site into apps/web/dist-demo (static files for a Cloudflare Worker)
	@docker build -q --build-context engine=apps/engine --target demo-site \
	 -o apps/web/dist-demo apps/web >/dev/null && echo "Wrote apps/web/dist-demo"

build-docs:          ## Build the documentation into apps/docs/dist (static files for docs.opencaptions.app)
	@docker build -q --build-context docs=docs --target docs-site -o apps/docs/dist apps/docs >/dev/null \
	 && echo "Wrote apps/docs/dist"

e2e:                 ## Build the images and run the Playwright suite against a disposable stack
	@./scripts/e2e.sh

engine-wasm:         ## Build the engine for the browser into apps/web/public/engine (for npm run dev)
	@docker build -q --build-context engine=apps/engine --target preview-assets \
	 -o apps/web/public/engine apps/web >/dev/null && echo "Wrote apps/web/public/engine"

format:              ## Auto-format all code
	@cd apps/api && uv run ruff format . && uv run ruff check --fix .
	@$(WEB) format
	@$(ENGINE) cargo fmt

generate-types:      ## Regenerate TypeScript types from the OpenAPI spec
	@$(WEB) generate-types

release:             ## Prepare a release without making it. Usage: make release VERSION=0.2.0
	@./scripts/release.sh $(VERSION)

check-versions:      ## Verify the manifests agree on the version
	@./scripts/check-version-sync.sh

check-ios-strings:   ## Verify every iOS permission purpose string is real text, not its key name
	@./scripts/check-ios-strings.sh

check-compose:       ## Verify docker-compose.yml's fallbacks agree with each other and the code
	@./scripts/check-compose.sh

# --- iOS (macOS + Xcode only; not part of `make ci`, see apps/ios/README.md) ----

IOS_ONLY := @test "$$(uname)" = Darwin || { echo "needs macOS + Xcode, see apps/ios/README.md"; exit 1; }

demo: build-demo  ## Build the public demo site (alias of build-demo)

docs:                ## Serve the documentation with live reload on http://localhost:3000
	@docker run --rm -it -p 3000:3000 -v "$$PWD/apps/docs":/site -v "$$PWD/docs":/site/src/content/docs:ro -v opencaptions-docs-modules:/site/node_modules \
	 -w /site -e ASTRO_TELEMETRY_DISABLED=1 -e ASTRO_DISABLE_UPDATE_CHECK=true node:24-bookworm-slim sh -c 'npm ci --no-audit --no-fund && npm start'

docs-build: build-docs  ## Build the documentation (alias of build-docs)

ios-engine:          ## Build the engine into apps/ios/Build/OpenCaptionsEngine.xcframework
	$(IOS_ONLY)
	@apps/engine/scripts/build-apple.sh

ios-project:         ## Generate the Xcode project (XcodeGen)
	$(IOS_ONLY)
	@cd apps/ios && xcodegen generate

ios-test:            ## Run the iOS logic tests on the Mac (no simulator)
	$(IOS_ONLY)
	@cd apps/ios/OpenCaptionsKit && swift test

ios-ui-test: ios-project ## Drive the caption gestures on a simulator (a booted one, or IOS_SIM=<name>)
	@cd apps/ios && xcodebuild test -project OpenCaptions.xcodeproj -scheme OpenCaptions \
		-destination "platform=iOS Simulator,name=$${IOS_SIM:-iPhone 18 Pro}" -derivedDataPath Build/DerivedData \
		-only-testing:OpenCaptionsUITests > Build/ui-test.log 2>&1; status=$$?; \
		grep -E "Test Case .*(passed|failed)|error:|\*\* TEST" Build/ui-test.log; exit $$status

ios-build: ios-project ## Build the iOS app for the simulator
	$(IOS_ONLY)
	@cd apps/ios && xcodebuild build -project OpenCaptions.xcodeproj -scheme OpenCaptions \
	 -destination 'generic/platform=iOS Simulator' -derivedDataPath Build/DerivedData \
	 CODE_SIGNING_ALLOWED=NO -quiet

mac-build: ios-project ## Build the Mac app (the same target, for macOS)
	$(IOS_ONLY)
	@cd apps/ios && xcodebuild build -project OpenCaptions.xcodeproj -scheme OpenCaptions \
	 -destination 'generic/platform=macOS' -derivedDataPath Build/DerivedData \
	 CODE_SIGNING_ALLOWED=NO -quiet

# The build number must rise with every upload to App Store Connect: the date and time do.
IOS_BUILD ?= $(shell date +%y%m%d%H%M)
# What the export does (see Config/ExportOptions.plist); a different plist can sign with another certificate or only export.
IOS_EXPORT_OPTIONS ?= Config/ExportOptions.plist

ios-archive: ios-project ## Archive the App Store build (Pro for sale, starts free); IOS_BUILD=<number> to set the build number
	$(IOS_ONLY)
	@cd apps/ios && rm -rf Build/OpenCaptions.xcarchive && xcodebuild archive -project OpenCaptions.xcodeproj \
	 -scheme OpenCaptions -configuration AppStore -destination 'generic/platform=iOS' \
	 -archivePath Build/OpenCaptions.xcarchive -allowProvisioningUpdates \
	 CURRENT_PROJECT_VERSION=$(IOS_BUILD) -quiet

# Xcode shells out to rsync, and Homebrew's rsync on the PATH does not take the flags it passes (the export
# stops at "Copy failed"), so the export runs with the system tools only.
IOS_EXPORT_ENV := env PATH=/usr/bin:/bin:/usr/sbin:/sbin

ios-ipa: ios-archive ## Archive and export the signed .ipa (Build/Export/OpenCaptions.ipa), for the Transporter app
	@cd apps/ios && sed 's#<string>upload</string>#<string>export</string>#' $(IOS_EXPORT_OPTIONS) > Build/ExportOptions-ipa.plist \
	 && rm -rf Build/Export && $(IOS_EXPORT_ENV) xcodebuild -exportArchive -archivePath Build/OpenCaptions.xcarchive \
	 -exportOptionsPlist Build/ExportOptions-ipa.plist -exportPath Build/Export
	@echo "Signed file: apps/ios/Build/Export/OpenCaptions.ipa (drag it into Transporter, or use make ios-upload with an App Store Connect API key)"

# An App Store Connect API key (Users and Access, Integrations) signs the upload in without Xcode's saved login:
# IOS_API_KEY=<key id> IOS_API_ISSUER=<issuer id> IOS_API_KEY_FILE=<path to AuthKey_<id>.p8>.
IOS_AUTH = $(if $(IOS_API_KEY),-authenticationKeyPath $(IOS_API_KEY_FILE) -authenticationKeyID $(IOS_API_KEY) -authenticationKeyIssuerID $(IOS_API_ISSUER),-allowProvisioningUpdates)

ios-upload: ios-archive ## Archive and send it to App Store Connect (TestFlight); needs an API key or Xcode's login
	@cd apps/ios && $(IOS_EXPORT_ENV) xcodebuild -exportArchive -archivePath Build/OpenCaptions.xcarchive \
	 -exportOptionsPlist $(IOS_EXPORT_OPTIONS) -exportPath Build/Export $(IOS_AUTH)

# The Mac app is the same target and the same App Store record as the iPhone's: one purchase of Pro covers both.
MAC_EXPORT_OPTIONS ?= Config/ExportOptions-macOS.plist

mac-archive: ios-project ## Archive the Mac App Store build; IOS_BUILD=<number> to set the build number
	$(IOS_ONLY)
	@cd apps/ios && rm -rf Build/OpenCaptions-mac.xcarchive && xcodebuild archive -project OpenCaptions.xcodeproj \
	 -scheme OpenCaptions -configuration AppStore -destination 'generic/platform=macOS' \
	 -archivePath Build/OpenCaptions-mac.xcarchive -allowProvisioningUpdates \
	 CURRENT_PROJECT_VERSION=$(IOS_BUILD) -quiet

mac-upload: mac-archive ## Archive the Mac app and send it to App Store Connect (TestFlight); same API key as ios-upload
	@cd apps/ios && $(IOS_EXPORT_ENV) xcodebuild -exportArchive -archivePath Build/OpenCaptions-mac.xcarchive \
	 -exportOptionsPlist $(MAC_EXPORT_OPTIONS) -exportPath Build/Export-mac $(IOS_AUTH)

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
