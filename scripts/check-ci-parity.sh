#!/usr/bin/env bash
# Fail when `make ci` and .github/workflows/ci.yml drift apart.
#
# .github/workflows/ios.yml is deliberately outside this check: it builds the iOS app on
# macOS, which the local gate (Linux containers) cannot run. ci-local.sh only lints it.
#
# The gate only means "CI will pass" while it checks what CI checks, and these
# diverged once already. Patterns are matched per side with comments stripped, so
# a check merely mentioned cannot vouch for one, and the workflow's job list is
# pinned: a new job fails here until it is mirrored or recorded as publish-only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
RUNNER="$REPO_ROOT/scripts/ci-local.sh"

[ -f "$WORKFLOW" ] || { echo "missing $WORKFLOW" >&2; exit 1; }
[ -f "$RUNNER" ] || { echo "missing $RUNNER" >&2; exit 1; }

# Effective content only: drop comment-only lines from both files.
WORKFLOW_BODY="$(grep -vE '^\s*#' "$WORKFLOW")"
RUNNER_BODY="$(grep -vE '^\s*#' "$RUNNER")"

# name | pattern required in ci.yml | pattern required in scripts/ci-local.sh
CHECKS=(
  "ruff|ruff check|ruff check"
  "ruff-format|ruff format --check|ruff format --check"
  "mypy|mypy app/|mypy app/"
  "backend tests|pytest|pytest"
  "web lint|working-directory: apps/web|npm run lint"
  "web build|npm run build|npm run build"
  "web typecheck|npm run typecheck|npm run typecheck"
  "engine clippy|cargo clippy --locked --all-targets|cargo clippy --locked --all-targets"
  "engine wasm clippy|wasm32-unknown-unknown -- -D warnings|wasm32-unknown-unknown -q -- -D warnings"
  "engine ios clippy|aarch64-apple-ios -- -D warnings|aarch64-apple-ios -q -- -D warnings"
  "engine tests|cargo test --locked|cargo test --locked"
  "engine format|cargo fmt --check|cargo fmt --check"
  "type generation|generate-api-types.sh|generate-api-types.sh"
  "generated types gate|api.generated.ts|api.generated.ts"
  "compose fallbacks|check-compose.sh|check-compose.sh"
  "version sync|check-version-sync.sh|check-version-sync.sh"
  "end-to-end|test:e2e|test:e2e"
  "image builds|docker/build-push-action|docker build"
  "GPU image target|runtime-gpu|runtime-gpu"
)

# Jobs that exist only to publish artifacts; the local gate deliberately stops
# short of pushing anything.
PUBLISH_ONLY_JOBS="publish publish-gpu"

failed=0

for entry in "${CHECKS[@]}"; do
  IFS='|' read -r name wf_pattern run_pattern <<<"$entry"
  in_workflow=0; in_runner=0
  printf '%s' "$WORKFLOW_BODY" | grep -qF -- "$wf_pattern" && in_workflow=1
  printf '%s' "$RUNNER_BODY" | grep -qF -- "$run_pattern" && in_runner=1

  if [ "$in_workflow" = "1" ] && [ "$in_runner" = "1" ]; then
    printf '  ✓ %s\n' "$name"
  elif [ "$in_workflow" = "1" ]; then
    printf '  ✗ %s: runs in ci.yml but NOT in scripts/ci-local.sh\n' "$name" >&2
    failed=1
  elif [ "$in_runner" = "1" ]; then
    printf '  ✗ %s: runs in scripts/ci-local.sh but NOT in ci.yml\n' "$name" >&2
    failed=1
  else
    printf '  ✗ %s: missing from BOTH\n' "$name" >&2
    failed=1
  fi
done

# Any workflow job not accounted for above is drift by definition: it validates
# something the local gate may not.
KNOWN_JOBS="lint-backend lint-frontend engine typecheck test-backend compose-drift build e2e $PUBLISH_ONLY_JOBS"
workflow_jobs="$(awk '/^jobs:/{injobs=1; next} injobs && /^  [a-zA-Z0-9_-]+:/{gsub(/[: ]/,""); print}' "$WORKFLOW")"
for job in $workflow_jobs; do
  case " $KNOWN_JOBS " in
    *" $job "*) ;;
    *)
      printf '  ✗ unrecognised CI job "%s": mirror it in scripts/ci-local.sh and add it to KNOWN_JOBS\n' "$job" >&2
      failed=1
      ;;
  esac
done

if [ "$failed" != "0" ]; then
  cat >&2 <<'EOF'

ERROR: the local acceptance gate and GitHub CI have drifted.

Add the missing validation to whichever side lacks it, so that a green
`make ci` continues to mean "GitHub CI will pass". If a check genuinely
belongs to only one side, update this script and say why in the commit
message.
EOF
  exit 1
fi

echo "✓ local acceptance gate and GitHub CI cover the same validations"
