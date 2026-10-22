#!/usr/bin/env bash
# Full local CI, the repository's acceptance gate.
#
# Runs every check of CI_CHECKS (the Makefile names them; GitHub CI runs the same list, one job
# each) from a `git archive` snapshot of committed source, each in its pinned container, so local
# build output cannot make a broken commit look green. Publishing is the one thing it leaves out.
# The end-to-end stack uses its own project name, named volumes and off-default ports (scripts/e2e.sh),
# so it can run while `make up` is live.
#
# It leaves nothing behind: the images it builds carry their own tag (never a live stack's `latest`),
# are removed at the end, and what it adds to Docker's build cache is capped.
#
# Usage:
#   scripts/ci-local.sh            # committed HEAD
#   scripts/ci-local.sh --staged   # HEAD + staged changes (pre-commit check)
#   scripts/ci-local.sh --no-e2e   # only the static checks: no image builds, sites or e2e
#   scripts/ci-local.sh --gpu      # also build the GPU image (otherwise only when its inputs changed)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GPU_IMAGE="opencaptions-ci-gpu:local"
# What the GPU image is made from: it changes rarely, and it is the slowest build (several
# GB of CUDA libraries), so it is built when one of these differs from origin/main.
GPU_INPUTS="apps/api/Dockerfile apps/api/pyproject.toml apps/api/uv.lock"
# How much Docker build cache may stay after a run, so the next run is fast but disk is bounded.
KEEP_BUILD_CACHE="2GB"

INCLUDE_HEAVY=1
FORCE_GPU=0
STAGED=0
for arg in "$@"; do
  case "$arg" in
    --no-e2e) INCLUDE_HEAVY=0 ;;
    --staged) STAGED=1 ;;
    --gpu) FORCE_GPU=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

command -v docker >/dev/null || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required"

# A run builds several GB of images and, on Docker Desktop, grows its disk file on the host (the file never
# shrinks): a host with little room does not fail cleanly, it corrupts the build halfway ("read-only file
# system"). Stop before starting instead. OC_CI_MIN_FREE_GB=0 turns the check off.
MIN_FREE_GB="${OC_CI_MIN_FREE_GB:-8}"
FREE_GB=$(( $(df -Pk "${TMPDIR:-/tmp}" | awk 'NR==2 {print $4}') / 1048576 ))
if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
  fail "only ${FREE_GB} GB free on this disk, a run needs ${MIN_FREE_GB}. Free space first (Xcode's DerivedData, \
Rust target/ folders, unused simulators, 'docker system prune -a'), and if Docker Desktop's disk file is much \
larger than its images, lower its disk limit in Settings > Resources"
fi

WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/oc-ci-XXXXXX")"
chmod 755 "$WORKTREE"
IMAGES_BUILT=0

cleanup() {
  local status=$?
  if [ "$IMAGES_BUILT" = "1" ]; then
    # Only what this run built: its own tag, never a live stack's images.
    # shellcheck disable=SC2046
    docker image rm -f "$GPU_IMAGE" $(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep ':ci-local$' || true) >/dev/null 2>&1 || true
    docker builder prune -f --keep-storage "$KEEP_BUILD_CACHE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKTREE" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT INT TERM

# --- Clean source snapshot -------------------------------------------------
step "Exporting a clean source snapshot"
cd "$REPO_ROOT"
if [ "$STAGED" = "1" ]; then
  # Archive the index so staged-but-uncommitted work is validated as CI would see it after commit.
  TREE="$(git write-tree)"
  git archive "$TREE" | tar -x -C "$WORKTREE"
  echo "snapshot: staged index (tree $TREE)"
else
  TREE="HEAD"
  git archive HEAD | tar -x -C "$WORKTREE"
  echo "snapshot: $(git rev-parse --short HEAD) (HEAD)"
fi
# `git archive` intentionally omits .git; the generated-types gate needs a repo to diff against,
# so make the snapshot a throwaway one.
git -C "$WORKTREE" init -q
git -C "$WORKTREE" -c user.email=ci@local -c user.name=ci add -A
git -C "$WORKTREE" -c user.email=ci@local -c user.name=ci commit -qm snapshot

# --- The checks ------------------------------------------------------------
# Containers run as this user (scripts/ci-shell.sh), so the snapshot stays removable; the caches the
# checks share live outside it, in $CI_CACHE.
if [ "$INCLUDE_HEAVY" = "1" ]; then target=ci-checks; else target=ci-static-checks; fi
checks="$(make -s -C "$WORKTREE" "$target")"
for check in $checks; do
  case "$check" in build-demo | build-docs | e2e) IMAGES_BUILT=1 ;; esac
  step "make $check"
  make -s -C "$WORKTREE" "$check" || fail "$check failed"
done

if [ "$INCLUDE_HEAVY" = "0" ]; then
  bold $'\n✓ Static gate passed (images, sites and e2e skipped via --no-e2e)'
  exit 0
fi

# The GPU image is what publish-gpu pushes, so building it here is a rehearsal of that: worth
# its several GB only when something it is made from changed (or when asked with --gpu).
build_gpu=$FORCE_GPU
if [ "$build_gpu" = "0" ]; then
  # An unknown origin/main (a fresh clone, no remote) cannot say nothing changed: build.
  # shellcheck disable=SC2086
  git -C "$REPO_ROOT" diff --quiet origin/main "$TREE" -- $GPU_INPUTS 2>/dev/null || build_gpu=1
fi
if [ "$build_gpu" = "1" ]; then
  step "Building the GPU image (its inputs changed, or --gpu)"
  (cd "$WORKTREE" && docker build -q -t "$GPU_IMAGE" --target runtime-gpu apps/api >/dev/null) \
    || fail "the GPU image build failed"
else
  echo "GPU image skipped: apps/api/Dockerfile, pyproject.toml and uv.lock match origin/main (--gpu builds it anyway)"
fi

bold $'\n✓ Full local CI passed, this commit is expected to pass GitHub CI'
