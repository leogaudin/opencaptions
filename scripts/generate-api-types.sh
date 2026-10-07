#!/usr/bin/env bash
# generate-api-types.sh. Derive TypeScript types from the API's OpenAPI schema.
#
# This script dumps the OpenAPI document OFFLINE (no running server, no
# Postgres/Redis/object storage required) and pipes it through openapi-typescript to
# produce apps/web/src/types/api.generated.ts.
#
# Usage: bash scripts/generate-api-types.sh
# (run from the repository root)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_DIR="$REPO_ROOT/apps/api"
WEB_DIR="$REPO_ROOT/apps/web"
OUTPUT="$WEB_DIR/src/types/api.generated.ts"
SCHEMA_TMP="$(mktemp)"

cleanup() { rm -f "$SCHEMA_TMP"; }
trap cleanup EXIT

# --- Step 1: Offline OpenAPI dump ---
# Resolve python: the uv-managed venv that `uv sync` creates, what both
# `make ci` and GitHub CI use, falling back to system python3.
if [ -x "$API_DIR/.venv/bin/python" ]; then
  PYTHON="$API_DIR/.venv/bin/python"
else
  PYTHON=python3
fi

echo "→ Dumping OpenAPI schema (offline)..."
(cd "$API_DIR" && "$PYTHON" -c "
import json, sys
from app.main import app
json.dump(app.openapi(), sys.stdout, indent=2)
") > "$SCHEMA_TMP"

if [ ! -s "$SCHEMA_TMP" ]; then
  echo "ERROR: OpenAPI dump produced empty output" >&2
  exit 1
fi

# --- Step 2: openapi-typescript codegen ---
echo "→ Generating TypeScript types..."
npx --prefix "$WEB_DIR" openapi-typescript "$SCHEMA_TMP" -o "$OUTPUT"

if [ ! -s "$OUTPUT" ]; then
  echo "ERROR: openapi-typescript produced empty output" >&2
  exit 1
fi

echo "✓ Generated $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
