#!/usr/bin/env bash
# The end-to-end suite (Playwright) against a disposable stack, from the checkout it is called from.
#
# The stack is docker-compose.yml under its own project name, so every named volume and the network are
# separate from a live stack's (this can run beside `make up`). The override below adds only what the name
# cannot: the web port moved, and the model cache read-only. `!override` replaces rather than appends a list
# (Compose v2.24+). The images are built here, once, tagged `ci-local` (never a live stack's `latest`), and
# the stack starts from them. Teardown is unconditional.
set -euo pipefail

ROOT="$PWD"
PROJECT="opencaptions-ci"
IMAGE_TAG="ci-local"
BASE_URL="http://localhost:15173"
OVERRIDE='services:
  web:      { ports:   !override ["127.0.0.1:15173:5173"] }
  api:      { volumes: !override ["./models:/models:ro"] }
  worker-transcription: { volumes: !override ["./models:/models:ro"] }'
NODE_IMAGE="node:26-bookworm"
CI_CACHE="${CI_CACHE:-$HOME/.cache/opencaptions-ci}"

compose_ci() {
  printf '%s\n' "$OVERRIDE" |
    OPENCAPTIONS_VERSION="$IMAGE_TAG" docker compose -p "$PROJECT" -f docker-compose.yml -f - "$@"
}
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

up=0
cleanup() {
  status=$?
  if [ "$status" != 0 ] && [ "$up" = 1 ]; then
    compose_ci logs --no-color --timestamps >compose.log 2>&1 || true
  fi
  compose_ci down -v --remove-orphans >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT INT TERM

echo "==> Building images (api, engine, web)"
compose_ci build -q >/dev/null || fail "image builds failed"
mkdir -p models

# Assert isolation positively rather than trusting the project name: the only bind mount is the model
# cache, and every named volume resolves under the CI project, so nothing a live stack writes can be reached.
bad="$(compose_ci config | awk '
  /^volumes:/ { top = 1; next }
  /^[a-z]/    { top = 0 }
  top && /^    name: / && $2 !~ /^'"$PROJECT"'_/ { print "volume " $2 }
  !top && /^ *source: \// && $2 !~ /\/models$/     { print "bind " $2 }
')"
if [ -n "$bad" ]; then
  printf 'mounts outside the CI project:\n%s\n' "$bad" >&2
  fail "the CI stack would touch host state, refusing to run e2e"
fi

compose_ci up -d --wait --wait-timeout 240 || {
  compose_ci ps
  fail "the isolated CI stack did not become healthy"
}
up=1

# Chromium is installed beside the locked @playwright/test, as a named cache holds it for a rerun; the
# Playwright image is a multi-GB pull for three browsers when only Chromium is used. Root, because
# `--with-deps` installs packages; what it writes into the checkout is handed back to the caller after.
# --network host is what lets the suite reach the isolated stack's off-default port.
mkdir -p "$CI_CACHE/playwright" "$CI_CACHE/npm"
docker run --rm --network host \
  -v "$ROOT":/w -w /w/apps/web -v "$CI_CACHE":/cache \
  -e BASE_URL="$BASE_URL" -e HOME=/tmp -e PLAYWRIGHT_BROWSERS_PATH=/cache/playwright -e npm_config_cache=/cache/npm \
  -e OWNER="$(id -u):$(id -g)" "$NODE_IMAGE" sh -c '
    status=0
    npm ci --no-audit --no-fund >/dev/null && npx playwright install --with-deps chromium >/dev/null && npm run test:e2e || status=$?
    chown -R "$OWNER" /w/apps/web /cache 2>/dev/null || true
    exit $status' || fail "end-to-end tests failed"
