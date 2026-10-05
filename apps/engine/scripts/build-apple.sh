#!/usr/bin/env bash
# Build the caption engine for Apple platforms as OpenCaptionsEngine.xcframework,
# the binary the iOS app links (apps/ios/OpenCaptionsKit).
#
# Slices: the device (aarch64-apple-ios), the Apple-silicon simulator
# (aarch64-apple-ios-sim) and macOS (aarch64-apple-darwin), so `swift test` runs on
# a Mac with no simulator. Intel Macs and Intel simulators are not supported.
#
# Needs macOS with full Xcode (xcodebuild assembles the xcframework), a Rust of at
# least 1.85 (the engine is edition 2024) and the three Rust targets. Anything
# missing is reported with the command that fixes it.
#
# Usage: apps/engine/scripts/build-apple.sh [output-dir]   (default: apps/ios/Build)
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$(mkdir -p "${1:-$ENGINE_DIR/../ios/Build}" && cd "${1:-$ENGINE_DIR/../ios/Build}" && pwd)"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
MIN_RUST=1.85.0
LIB=libopencaptions_engine.a
XCFRAMEWORK="$OUT_DIR/OpenCaptionsEngine.xcframework"

die() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(uname)" = Darwin ] || die "the Apple build needs macOS (see apps/ios/README.md)"

# Full Xcode, not just the Command Line Tools: xcodebuild -create-xcframework is Xcode's.
xcodebuild -version >/dev/null 2>&1 \
  || die "full Xcode is required (xcodebuild not usable). Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"

command -v rustc >/dev/null || die "Rust is required: https://rustup.rs"
have="$(rustc --version | awk '{print $2}')"
[ "$(printf '%s\n%s\n' "$MIN_RUST" "$have" | sort -V | head -n1)" = "$MIN_RUST" ] \
  || die "Rust $MIN_RUST or newer is required (found $have). Run: rustup update stable"

installed="$(rustup target list --installed 2>/dev/null || true)"
missing=()
for t in "${TARGETS[@]}"; do
  printf '%s\n' "$installed" | grep -qx "$t" || missing+=("$t")
done
[ "${#missing[@]}" -eq 0 ] || die "missing Rust targets. Run: rustup target add ${missing[*]}"

cd "$ENGINE_DIR"
for t in "${TARGETS[@]}"; do
  printf '\033[1;36m==> %s\033[0m\n' "$t"
  cargo rustc --release --locked --lib --crate-type staticlib --target "$t"
done

# The header, with a module map so Swift imports it as `OpenCaptionsEngine`.
HEADERS="$(mktemp -d)"
trap 'rm -rf "$HEADERS"' EXIT
cp include/opencaptions_engine.h "$HEADERS/"
cat >"$HEADERS/module.modulemap" <<'MODULEMAP'
module OpenCaptionsEngine {
    header "opencaptions_engine.h"
    export *
}
MODULEMAP

rm -rf "$XCFRAMEWORK"
args=()
for t in "${TARGETS[@]}"; do
  args+=(-library "target/$t/release/$LIB" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${args[@]}" -output "$XCFRAMEWORK"
printf '\033[1;32m✓ %s\033[0m\n' "$XCFRAMEWORK"
