#!/usr/bin/env bash
# Runs a command in apps/engine inside the engine's pinned toolchain container: the stock rust image
# lacks clippy, rustfmt and the WebAssembly and iOS targets, so the image is built on first use.
# It runs as the caller and keeps cargo's registry in $CI_CACHE (which GitHub restores between runs).
#   scripts/engine-shell.sh cargo test
set -euo pipefail

IMAGE="opencaptions-ci-engine:local"
CI_CACHE="${CI_CACHE:-$HOME/.cache/opencaptions-ci}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -q -t "$IMAGE" - >/dev/null <<DOCKERFILE
FROM rust:1.99-slim-bookworm
RUN rustup component add rustfmt clippy
RUN rustup target add wasm32-unknown-unknown aarch64-apple-ios
DOCKERFILE
fi

mkdir -p "$CI_CACHE/cargo"
exec docker run --rm --user "$(id -u):$(id -g)" -e CARGO_HOME=/cache/cargo -e HOME=/tmp/home \
  -v "$CI_CACHE":/cache -v "$ROOT/apps/engine":/w -w /w "$IMAGE" "$@"
