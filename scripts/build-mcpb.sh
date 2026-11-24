#!/usr/bin/env bash
# build-mcpb.sh. Builds the Claude Desktop extension (an .mcpb file) of the agent package: the
# built package, its production dependencies, and the manifest in apps/agent/mcpb/.
#
#   bash scripts/build-mcpb.sh opencaptions-macos darwin arm64 x64
#   bash scripts/build-mcpb.sh opencaptions-linux-test linux x64      # what the CI check starts
#
# Writes apps/agent/<name>.mcpb. The speech engine (sherpa-onnx-node) loads a native package per
# platform and architecture, so one bundle carries one for each architecture named: `npm ci --os
# --cpu` installs a platform's from any machine. Needs `make agent-engine` and `npm run build`
# first (apps/agent/engine and apps/agent/dist), and runs in the pinned node container:
# `make agent-mcpb`.
set -euo pipefail

MCPB="@anthropic-ai/mcpb@2.1.2"
MAX_MB=120

name="${1:?usage: build-mcpb.sh <name> <os> <cpu>...}"
os="${2:?usage: build-mcpb.sh <name> <os> <cpu>...}"
shift 2
[ "$#" -gt 0 ] || { echo "usage: build-mcpb.sh <name> <os> <cpu>..." >&2; exit 2; }
cpus=("$@")

case "$os" in
  darwin | linux) native="$os" ;;
  *) echo "unsupported os: $os (darwin or linux)" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
agent=apps/agent
for needed in dist/cli.js engine/opencaptions_engine.wasm engine/fonts mcpb/manifest.json; do
  [ -e "$agent/$needed" ] || { echo "missing $agent/$needed: run make agent-engine and npm run build first" >&2; exit 1; }
done

stage="$agent/.mcpb-build/$name"
rm -rf "$stage"
mkdir -p "$stage/engine"
cp -R "$agent/dist" "$stage/dist"
cp "$agent/engine/opencaptions_engine.wasm" "$stage/engine/"
cp -R "$agent/engine/fonts" "$stage/engine/fonts"
cp "$agent/package.json" "$agent/package-lock.json" "$agent/README.md" "$stage/"
cp LICENSE "$stage/"
cp "$agent/mcpb/manifest.json" "$stage/manifest.json"
cp apps/docs/public/img/icon-512.png "$stage/icon.png"

install() { # <folder> <cpu>: the production dependencies, for this platform
  (cd "$1" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --os="$native" --cpu="$2" >/dev/null)
}

install "$stage" "${cpus[0]}"
for cpu in "${cpus[@]:1}"; do
  # npm installs one architecture's native package per run: take the others' from a second install
  # of the same lock file, which keeps them held to its checksums.
  other="$(mktemp -d)"
  cp "$agent/package.json" "$agent/package-lock.json" "$other/"
  install "$other" "$cpu"
  cp -R "$other/node_modules/sherpa-onnx-$native-$cpu" "$stage/node_modules/"
  rm -rf "$other"
done
for cpu in "${cpus[@]}"; do
  [ -d "$stage/node_modules/sherpa-onnx-$native-$cpu" ] \
    || { echo "sherpa-onnx-$native-$cpu is not in the bundle" >&2; exit 1; }
done

npx -y "$MCPB" validate "$stage/manifest.json" >/dev/null
out="$agent/$name.mcpb"
rm -f "$out"
npx -y "$MCPB" pack "$stage" "$out" >/dev/null

size_mb=$(($(wc -c <"$out") / 1048576))
echo "Wrote $out (${size_mb} MB)"
[ "$size_mb" -le "$MAX_MB" ] || { echo "the bundle is over $MAX_MB MB: something that is not needed got in" >&2; exit 1; }
