#!/usr/bin/env bash
# Puts the caption engine (WebAssembly and fonts) in demo-public/engine for `npm run dev:demo`,
# unless it is already there. The build itself gets it from the Dockerfile's demo-site stage.
# Built with cargo when it has the wasm32 target, otherwise with Docker (as `make engine-wasm`).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=demo-public/engine
[ -f "$OUT/opencaptions_engine.wasm" ] && [ -f "$OUT/fonts.json" ] && exit 0
mkdir -p "$OUT"
if command -v cargo >/dev/null && rustup target list --installed 2>/dev/null | grep -q wasm32-unknown-unknown; then
  (cd ../engine && cargo build --release --locked --lib --target wasm32-unknown-unknown)
  cp ../engine/target/wasm32-unknown-unknown/release/opencaptions_engine.wasm "$OUT/"
  rm -rf "$OUT/fonts" && cp -r ../engine/fonts "$OUT/fonts"
  (cd ../engine/fonts && printf '[%s]' "$(LC_ALL=C ls | grep -iE '\.(ttf|otf)$' | sed 's/.*/"&"/' | paste -sd,)") > "$OUT/fonts.json"
else
  docker build -q --build-context engine=../engine --target preview-assets -o "$OUT" . >/dev/null
fi
echo "Wrote apps/web/$OUT"
