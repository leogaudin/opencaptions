#!/usr/bin/env bash
# Fail if docker-compose.yml's interpolation fallbacks disagree.
#
# A `${VAR:-literal}` fallback is the configuration a plain `up` receives. The
# credentials postgres and garage bootstrap are repeated in every service that
# connects with them, so every copy must carry the same literal — one edited copy
# means 403s with nothing in the logs naming config — and where the variable is
# also an application setting, the literal must equal its default in config.py.
# LOG_LEVEL is exempt: Python wants INFO, pino wants info.
#
# Usage: bash scripts/check-compose.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

problems="$(awk '
  FNR == NR {
    if (match($0, /^    [a-z][a-z_0-9]*[ ]*:/)) {
      split($0, parts, "=")
      if (length(parts) < 2) next
      name = $1; sub(/:$/, "", name)
      val = parts[2]
      sub(/#.*$/, "", val)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      gsub(/^"|"$/, "", val)
      if (val == "False") val = "false"
      if (val == "True") val = "true"
      code[toupper(name)] = val
    }
    next
  }
  {
    rest = $0
    while (match(rest, /\$\{[A-Z0-9_]+:-[^}]*\}/)) {
      tok = substr(rest, RSTART + 2, RLENGTH - 3)
      rest = substr(rest, RSTART + RLENGTH)
      sep = index(tok, ":-")
      k = substr(tok, 1, sep - 1)
      fb = substr(tok, sep + 2)
      if (k in seen && seen[k] != fb)
        printf "  %s: two different fallbacks — %s and %s\n", k, seen[k], fb
      seen[k] = fb
      if (k != "LOG_LEVEL" && k in code && code[k] != fb)
        printf "  %s: compose fallback %s != config.py default %s\n", k, fb, code[k]
    }
  }
' "$REPO_ROOT/apps/api/app/core/config.py" "$REPO_ROOT/docker-compose.yml" | sort -u)"

if [ -n "$problems" ]; then
  echo "ERROR: docker-compose.yml interpolation fallbacks are inconsistent." >&2
  echo "$problems" >&2
  exit 1
fi

echo "✓ docker-compose.yml fallbacks consistent and matching config.py"
