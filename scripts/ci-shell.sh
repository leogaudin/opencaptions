#!/usr/bin/env bash
# Runs a command in one of the pinned toolchain containers, against the checkout it is called from
# (its working directory: the repository, or the snapshot `make ci` validates). Every check of
# `make ci` and of GitHub CI is a Makefile target that runs through this, so both run the same
# thing in the same toolchain.
#
#   scripts/ci-shell.sh uv    apps/api 'uv run pytest'
#   scripts/ci-shell.sh node  apps/web 'npm run lint'
#   scripts/ci-shell.sh tools .        '...'   # Node and uv together (type generation)
#
# The container runs as the caller, so nothing it writes into the checkout is root-owned. Caches
# (uv, npm) live in $CI_CACHE, which GitHub restores between runs.
set -euo pipefail

NODE_IMAGE="node:26-bookworm"
UV_IMAGE="ghcr.io/astral-sh/uv:python3.14-bookworm-slim"
TOOLS_IMAGE="opencaptions-ci-tools:local"
CI_CACHE="${CI_CACHE:-$HOME/.cache/opencaptions-ci}"

kind="$1" dir="$2" command="$3"
mkdir -p "$CI_CACHE/uv" "$CI_CACHE/npm"

case "$kind" in
  uv) image="$UV_IMAGE" ;;
  node) image="$NODE_IMAGE" ;;
  tools)
    # Python AND Node in one place, like the GitHub runner: a uv-managed venv is not portable
    # between images, so a venv made in the uv image could not be run from the node image.
    image="$TOOLS_IMAGE"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      docker build -q -t "$image" - >/dev/null <<DOCKERFILE
FROM $NODE_IMAGE
COPY --from=$UV_IMAGE /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
DOCKERFILE
    fi
    ;;
  *) echo "unknown toolchain: $kind" >&2; exit 2 ;;
esac

exec docker run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/tmp/home -e UV_CACHE_DIR=/cache/uv -e npm_config_cache=/cache/npm \
  -e UV_PROJECT_ENVIRONMENT=/tmp/venv -e RUFF_CACHE_DIR=/tmp/ruff -e MYPY_CACHE_DIR=/tmp/mypy \
  -e UV_LINK_MODE=copy -e CI="${CI:-}" \
  -v "$CI_CACHE":/cache -v "$PWD":/w -w "/w/$dir" "$image" sh -euc "$command"
