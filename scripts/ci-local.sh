#!/usr/bin/env bash
# Full local CI — the repository's acceptance gate.
#
# Runs every validation .github/workflows/ci.yml runs except publishing, from a
# `git archive` snapshot of committed source in pinned containers, so local build
# output cannot make a broken commit look green. The e2e stack uses its own
# project name, named volumes and off-default ports, so it never touches a live stack
# and can run while `make up` is live. Teardown is unconditional.
#
# Usage:
#   scripts/ci-local.sh            # committed HEAD
#   scripts/ci-local.sh --staged   # HEAD + staged changes (pre-commit check)
#   scripts/ci-local.sh --no-e2e   # skip images + e2e (fast static gate)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI_PROJECT="opencaptions-ci"
# The CI stack is docker-compose.yml under its own project name, so every named
# volume and the network are separate from a live stack's. The override below adds
# only what the name cannot: the web port moved so both can run at once, and the
# model cache read-only. `!override` replaces rather than appends a list, and
# needs Compose v2.24+.
CI_OVERRIDE='services:
  web:      { ports:   !override ["127.0.0.1:15173:5173"] }
  api:      { volumes: !override ["./models:/models:ro"] }
  worker-transcription: { volumes: !override ["./models:/models:ro"] }'
compose_ci() {
  printf '%s\n' "$CI_OVERRIDE" | docker compose -p "$CI_PROJECT" -f docker-compose.yml -f - "$@"
}

# Pinned toolchain, matching ci.yml and the Dockerfiles.
NODE_IMAGE="node:24-bookworm"
UV_IMAGE="ghcr.io/astral-sh/uv:python3.14-bookworm-slim"
ACTIONLINT_IMAGE="rhysd/actionlint:1.7.12"
RUST_IMAGE="rust:1.94-slim-bookworm"
ENGINE_TOOLS_IMAGE="opencaptions-ci-engine:local"
# Built locally from NODE_IMAGE + uv (see "combined toolchain image" below).
TOOLS_IMAGE="opencaptions-ci-tools:local"
WEB_BASE_URL="http://localhost:15173"

INCLUDE_E2E=1
SOURCE_REF="HEAD"
STAGED=0
for arg in "$@"; do
  case "$arg" in
    --no-e2e) INCLUDE_E2E=0 ;;
    --staged) STAGED=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

command -v docker >/dev/null || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required"
command -v python3 >/dev/null || fail "python3 is required (to read the lockfile)"

# Derived from the lockfile: the image ships exactly the browser build its own
# @playwright/test expects.
PLAYWRIGHT_VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['packages']['node_modules/@playwright/test']['version'])" "$REPO_ROOT/apps/web/package-lock.json" 2>/dev/null || true)"
[ -n "$PLAYWRIGHT_VERSION" ] || fail "could not read @playwright/test version from apps/web/package-lock.json"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"

WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/oc-ci-XXXXXX")"
# mktemp gives 0700; some pinned images (actionlint, playwright) run as a
# non-root user and must be able to traverse the snapshot.
chmod 755 "$WORKTREE"
STACK_UP=0

cleanup() {
  local status=$?
  if [ "$STACK_UP" = "1" ]; then
    step "Tearing down the isolated CI stack"
    (cd "$WORKTREE" && compose_ci down -v --remove-orphans >/dev/null 2>&1) || true
  fi
  # Container-written files are root-owned; remove them from a container.
  if [ -d "$WORKTREE" ]; then
    docker run --rm -v "$WORKTREE":/target "$NODE_IMAGE" \
      find /target -mindepth 1 -delete >/dev/null 2>&1 || true
    rm -rf "$WORKTREE" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# --- Clean source snapshot -------------------------------------------------
step "Exporting a clean source snapshot"
cd "$REPO_ROOT"
if [ "$STAGED" = "1" ]; then
  # Archive the index so staged-but-uncommitted work is validated as CI would
  # see it after commit.
  TREE="$(git write-tree)"
  git archive "$TREE" | tar -x -C "$WORKTREE"
  echo "snapshot: staged index (tree $TREE)"
else
  git archive "$SOURCE_REF" | tar -x -C "$WORKTREE"
  echo "snapshot: $(git rev-parse --short "$SOURCE_REF") ($SOURCE_REF)"
fi
# `git archive` intentionally omits .git; the generated-types gate needs a repo
# to diff against, so make the snapshot a throwaway one.
git -C "$WORKTREE" init -q
git -C "$WORKTREE" -c user.email=ci@local -c user.name=ci add -A
git -C "$WORKTREE" -c user.email=ci@local -c user.name=ci commit -qm snapshot

in_uv() { docker run --rm -v "$WORKTREE":/w -w "/w/$1" "$UV_IMAGE" sh -euc "$2"; }
in_node() { docker run --rm -v "$WORKTREE":/w -w "/w/$1" "$NODE_IMAGE" sh -euc "$2"; }
# Type generation needs Python AND Node in one place, exactly like the GitHub
# runner: the uv-managed venv is not portable between images, so a venv created
# in the uv image cannot be executed from the node image.
in_tools() { docker run --rm -v "$WORKTREE":/w -w "/w/$1" "$TOOLS_IMAGE" sh -euc "$2"; }

step "Preparing the combined toolchain image"
docker build -q -t "$TOOLS_IMAGE" - >/dev/null <<DOCKERFILE
FROM $NODE_IMAGE
COPY --from=$UV_IMAGE /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
DOCKERFILE

# --- Workflow lint (catches errors GitHub only reports at run time) ---------
step "Workflow lint (actionlint)"
# Explicit path: actionlint's repository auto-discovery does not apply to the
# snapshot, and the workflow file is the only thing being checked.
docker run --rm -v "$WORKTREE":/repo:ro -w /repo "$ACTIONLINT_IMAGE" -no-color \
  .github/workflows/ci.yml .github/workflows/ios.yml \
  || fail "actionlint found workflow errors"

# --- Repository guards -----------------------------------------------------
step "Repository guards (version sync, compose fallbacks)"
in_node . 'bash scripts/check-version-sync.sh && bash scripts/check-compose.sh' \
  || fail "repository guards failed"

# --- Backend ---------------------------------------------------------------
step "Backend lint (ruff + mypy) and tests (pytest)"
in_uv apps/api '
  export UV_CACHE_DIR=/tmp/uv RUFF_CACHE_DIR=/tmp/ruff MYPY_CACHE_DIR=/tmp/mypy
  uv sync --extra dev --locked -q
  uv run ruff check .
  uv run ruff format --check .
  uv run mypy app/
  uv run pytest -q
' || fail "backend validation failed"

# --- Engine ----------------------------------------------------------------
step "Engine format, clippy (server, WebAssembly, iOS) and tests"
# The stock image lacks the WebAssembly and iOS targets, and the cache volume must belong
# to the caller so the snapshot stays removable.
docker build -q -t "$ENGINE_TOOLS_IMAGE" - >/dev/null <<DOCKERFILE
FROM $RUST_IMAGE
RUN rustup component add rustfmt clippy && rustup target add wasm32-unknown-unknown aarch64-apple-ios
DOCKERFILE
docker run --rm -v opencaptions-ci-cargo:/cargo "$ENGINE_TOOLS_IMAGE" chown "$(id -u):$(id -g)" /cargo
docker run --rm --user "$(id -u):$(id -g)" -e CARGO_HOME=/cargo -v opencaptions-ci-cargo:/cargo \
  -v "$WORKTREE":/w -w /w/apps/engine "$ENGINE_TOOLS_IMAGE" sh -euc '
  cargo fmt --check
  cargo clippy --locked --all-targets -q -- -D warnings
  cargo clippy --locked --lib --target wasm32-unknown-unknown -q -- -D warnings
  cargo clippy --locked --lib --target aarch64-apple-ios -q -- -D warnings
  cargo test --locked -q
' || fail "engine validation failed"

# --- Frontend --------------------------------------------------------------
step "Generated API types are in sync"
in_tools . '
  export UV_CACHE_DIR=/tmp/uv
  (cd apps/api && uv sync --extra dev --locked -q)
  npm --prefix apps/web ci --no-audit --no-fund >/dev/null
  bash scripts/generate-api-types.sh
' || fail "type generation failed"
git -C "$WORKTREE" diff --exit-code -- apps/web/src/types/api.generated.ts \
  || fail "apps/web/src/types/api.generated.ts is stale — run 'make generate-types' and commit"

step "Frontend lint, typecheck and production build"
in_node apps/web '
  npm run lint
  npm run typecheck
  npm run build
' || fail "web validation failed"

if [ "$INCLUDE_E2E" = "0" ]; then
  bold $'\n✓ Static gate passed (images and e2e skipped via --no-e2e)'
  exit 0
fi

# --- Images (including the GPU target that publish-gpu builds) -------------
step "Building images (api, api GPU target, engine, web)"
# Chained with && because `set -e` does not apply inside a subshell on the left of `||`:
# written as separate lines, only the last build's status would count and a failed
# earlier image would pass the gate.
(
  cd "$WORKTREE" &&
    docker build -q --target runtime apps/api >/dev/null &&
    docker build -q --target runtime-gpu apps/api >/dev/null &&
    docker build -q apps/engine >/dev/null &&
    docker build -q --build-context engine=apps/engine apps/web >/dev/null
) || fail "image builds failed"

# --- End-to-end against a disposable stack ---------------------------------
step "End-to-end (Playwright) against an isolated stack"
cd "$WORKTREE"
mkdir -p models

# Assert isolation positively rather than trusting the project name: the only
# bind mount is the model cache, and every named volume resolves under the CI
# project, so nothing a live stack writes can be reached.
resolved="$(compose_ci config)"
bad="$(printf '%s\n' "$resolved" | awk '
  /^volumes:/ { top = 1; next }
  /^[a-z]/    { top = 0 }
  top && /^    name: / && $2 !~ /^'"$CI_PROJECT"'_/ { print "volume " $2 }
  !top && /^ *source: \// && $2 !~ /\/models$/     { print "bind " $2 }
')"
if [ -n "$bad" ]; then
  printf 'mounts outside the CI project:\n%s\n' "$bad" >&2
  fail "the CI stack would touch host state — refusing to run e2e"
fi

compose_ci up -d --build --wait --wait-timeout 240 || {
  compose_ci ps
  fail "the isolated CI stack did not become healthy"
}
STACK_UP=1

# Run the SNAPSHOT's specs in the Playwright image matching the locked
# @playwright/test version (browsers preinstalled). --network host is what lets
# the suite reach the isolated stack's off-default port.
docker run --rm --network host \
  -v "$WORKTREE":/w -w /w/apps/web \
  -e BASE_URL="$WEB_BASE_URL" -e HOME=/tmp \
  "$PLAYWRIGHT_IMAGE" \
  sh -euc 'npm ci --no-audit --no-fund >/dev/null && npm run test:e2e' \
  || fail "end-to-end tests failed"

bold $'\n✓ Full local CI passed — this commit is expected to pass GitHub CI'
