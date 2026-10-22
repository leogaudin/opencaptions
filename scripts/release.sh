#!/usr/bin/env bash
# Prepares a release without making it: bumps every manifest to VERSION, rewrites CHANGELOG.md from the
# Conventional Commits (git-cliff, in a container), checks the manifests agree, and prints the commands
# that commit, tag and publish. Tagging and pushing are the maintainer's.
#   make release VERSION=0.2.0
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: make release VERSION=x.y.z" >&2; exit 2; }
cd "$(cd "$(dirname "$0")/.." && pwd)"
[ -z "$(git status --porcelain)" ] || { echo "the working tree is not clean: commit or stash first" >&2; exit 1; }

# The manifests (scripts/check-version-sync.sh reads the same four), and the lock files that repeat them.
# Python, not sed: the first match of a pattern is wanted, which BSD and GNU sed spell differently.
VERSION="$VERSION" python3 - <<'PY'
import os, re
v = os.environ["VERSION"]
def bump(path, pattern, repl, count=1):
    text = open(path).read()
    new, n = re.subn(pattern, repl, text, count=count, flags=re.M)
    if n == 0:
        raise SystemExit(f"no version found in {path}")
    open(path, "w").write(new)
bump("apps/api/pyproject.toml", r'^version = "[^"]*"', f'version = "{v}"')
bump("apps/engine/Cargo.toml", r'^version = "[^"]*"', f'version = "{v}"')
bump("apps/web/package.json", r'"version": *"[^"]*"', f'"version": "{v}"')
bump("apps/web/package-lock.json", r'"version": *"[^"]*"', f'"version": "{v}"', count=2)
bump("apps/ios/project.yml", r'^( *MARKETING_VERSION: *)[0-9][^ \n]*', rf'\g<1>{v}')
# The lock files name their own package once.
bump("apps/engine/Cargo.lock", r'(name = "opencaptions-engine"\nversion = )"[^"]*"', rf'\g<1>"{v}"')
bump("apps/api/uv.lock", r'(name = "opencaptions-api"\nversion = )"[^"]*"', rf'\g<1>"{v}"')
PY

bash scripts/check-version-sync.sh

# The changelog, as it will read once v$VERSION exists.
docker run --rm -v "$PWD":/app -w /app orhun/git-cliff:2 --tag "v$VERSION" --output CHANGELOG.md

cat <<MSG

Prepared $VERSION. Review the diff, then:

  git add -A && git commit -m "chore: Release $VERSION"
  git tag v$VERSION
  git push origin main v$VERSION      # the tag publishes the images, multi-arch

Then pin the quick start to it: OPENCAPTIONS_VERSION=$VERSION docker compose up -d
MSG
