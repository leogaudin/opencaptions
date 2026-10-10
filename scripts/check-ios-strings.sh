#!/usr/bin/env bash
# check-ios-strings.sh. Fail if an iOS purpose string is missing or just its key name.
set -euo pipefail
exec node "$(cd "$(dirname "$0")" && pwd)/check-ios-strings.mjs"
