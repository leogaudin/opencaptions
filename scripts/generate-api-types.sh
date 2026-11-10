#!/usr/bin/env bash
# generate-api-types.sh. Derive TypeScript types from the API's OpenAPI schema.
#
# This script dumps the OpenAPI document OFFLINE (no running server, no
# Postgres/Redis/object storage required) and pipes it through openapi-typescript to
# produce apps/web/src/types/api.generated.ts. The agent package (apps/agent) gets the same types, the style
# and the save options as JSON schemas for its tools, and the built-in looks, in apps/agent/src/generated/: it is published on its
# own, so it carries copies, and `make typegen-check` fails when one is stale.
#
# Usage: bash scripts/generate-api-types.sh
# (run from the repository root)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_DIR="$REPO_ROOT/apps/api"
WEB_DIR="$REPO_ROOT/apps/web"
OUTPUT="$WEB_DIR/src/types/api.generated.ts"
AGENT_OUT="$REPO_ROOT/apps/agent/src/generated"
SCHEMA_TMP="$(mktemp)"

cleanup() { rm -f "$SCHEMA_TMP"; }
trap cleanup EXIT

# --- Step 1: Offline OpenAPI dump ---
# Resolve python: the uv-managed venv that `uv sync` creates, what both
# `make ci` and GitHub CI use. Without one, uv makes it; a bare system python3 has no
# dependencies and would fail on the first import.
if [ -x "$API_DIR/.venv/bin/python" ]; then
  PYTHON=("$API_DIR/.venv/bin/python")
elif command -v uv >/dev/null 2>&1; then
  PYTHON=(uv run --project "$API_DIR" python)
else
  PYTHON=(python3)
fi

echo "→ Dumping OpenAPI schema (offline)..."
(cd "$API_DIR" && "${PYTHON[@]}" -c "
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

# --- Step 3: the agent package's copies ---
mkdir -p "$AGENT_OUT"
cp "$OUTPUT" "$AGENT_OUT/api.ts"
cp "$WEB_DIR/src/lib/presets.json" "$AGENT_OUT/presets.json"
cp "$REPO_ROOT/apps/api/app/services/render_formats.json" "$AGENT_OUT/render_formats.json"
# The style and the save options, with what they refer to written in place, as a tool's input schema wants it.
"${PYTHON[@]}" - "$SCHEMA_TMP" "$AGENT_OUT/schemas.json" <<'PY'
import json, sys

schemas = json.load(open(sys.argv[1]))["components"]["schemas"]

def inline(node):
    if isinstance(node, dict):
        if "$ref" in node:
            return inline(schemas[node["$ref"].rsplit("/", 1)[1]])
        return {k: inline(v) for k, v in node.items()}
    if isinstance(node, list):
        return [inline(v) for v in node]
    return node

with open(sys.argv[2], "w") as out:
    json.dump({"style": inline(schemas["StyleConfig"]), "save": inline(schemas["RenderRequest"])}, out, indent=2)
    out.write("\n")
PY
echo "✓ Copied the types, the schemas and the looks to $AGENT_OUT"
