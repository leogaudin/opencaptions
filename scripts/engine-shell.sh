#!/usr/bin/env bash
# Runs a command in apps/engine inside the engine's pinned toolchain container: the stock rust image
# lacks clippy, rustfmt and the WebAssembly and iOS targets, so the image is built on first use.
# The cargo cache volume is chowned to the caller, as ci-local.sh does.
#   scripts/engine-shell.sh cargo test
set -euo pipefail

IMAGE="opencaptions-ci-engine:local"
CACHE="opencaptions-ci-cargo"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -q -t "$IMAGE" - >/dev/null <<DOCKERFILE
FROM rust:1.99-slim-bookworm
RUN rustup component add rustfmt clippy
RUN rustup target add wasm32-unknown-unknown aarch64-apple-ios
DOCKERFILE
fi

docker run --rm -v "$CACHE":/cargo "$IMAGE" chown "$(id -u):$(id -g)" /cargo
exec docker run --rm --user "$(id -u):$(id -g)" -e CARGO_HOME=/cargo \
  -v "$CACHE":/cargo -v "$ROOT/apps/engine":/w -w /w "$IMAGE" "$@"
