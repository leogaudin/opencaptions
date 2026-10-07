#!/usr/bin/env bash
# check-version-sync.sh. Fail if the package manifests disagree on the
# project version.
#
# Each component derives its version from its OWN manifest at build/run time:
#   - apps/api      → pyproject.toml, read via importlib.metadata
#   - apps/web      → package.json, bundled by Vite
#   - apps/engine   → Cargo.toml, compiled in
#   - apps/ios      → project.yml (MARKETING_VERSION), read by XcodeGen
# So those manifests are the only places a version number lives. Nothing
# forces them to agree with each other, so this guard is the safety net: run it
# before cutting a release (and ideally in CI) to catch a manifest that was
# bumped while the others were forgotten.
#
# Usage: bash scripts/check-version-sync.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

extract_toml_version() {
  # First `version = "..."` at column 0 (the [project] version; `target-version`
  # and `python_version` do not match the anchored `version = ` prefix).
  sed -n 's/^version = "\([^"]*\)".*/\1/p' "$1" | head -n1
}

extract_json_version() {
  sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

api_version="$(extract_toml_version "$REPO_ROOT/apps/api/pyproject.toml")"
web_version="$(extract_json_version "$REPO_ROOT/apps/web/package.json")"
engine_version="$(extract_toml_version "$REPO_ROOT/apps/engine/Cargo.toml")"
ios_version="$(sed -n 's/^ *MARKETING_VERSION: *\([0-9][^ ]*\).*/\1/p' "$REPO_ROOT/apps/ios/project.yml" | head -n1)"

echo "api      (pyproject.toml): ${api_version:-<none>}"
echo "web      (package.json):   ${web_version:-<none>}"
echo "engine   (Cargo.toml):     ${engine_version:-<none>}"
echo "ios      (project.yml):    ${ios_version:-<none>}"

if [ -z "$api_version" ] || [ -z "$web_version" ] || [ -z "$engine_version" ] || [ -z "$ios_version" ]; then
  echo "ERROR: could not extract a version from one or more manifests" >&2
  exit 1
fi

if [ "$api_version" != "$web_version" ] || [ "$api_version" != "$engine_version" ] || [ "$api_version" != "$ios_version" ]; then
  echo "ERROR: manifest versions disagree, bump them all to the same value" >&2
  exit 1
fi

echo "✓ All manifests agree on version $api_version"
