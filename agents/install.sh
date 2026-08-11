#!/usr/bin/env bash
# Install the agents named in a comma-separated list. Claude is always in.
#
#   ./install.sh "claude,codex"
#
# An agent you asked for and did not get is worse than a failed build, so a
# failing installer stops the image.
set -euo pipefail

REQUESTED="${1:-claude}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Deduplicate while preserving order, with claude first whether asked for or not.
seen=" claude "
order=(claude)
IFS=',' read -ra names <<< "$REQUESTED"
for raw in "${names[@]}"; do
  name="$(echo "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [ -z "$name" ] && continue
  case "$seen" in *" $name "*) continue ;; esac
  seen="$seen$name "
  order+=("$name")
done

for name in "${order[@]}"; do
  script="$HERE/$name.sh"
  if [ ! -x "$script" ]; then
    echo "error: no installer for agent '$name'" >&2
    echo "       available: $(cd "$HERE" && ls *.sh | grep -v install.sh | sed 's/\.sh$//' | tr '\n' ' ')" >&2
    exit 1
  fi
  echo "==> installing $name"
  "$script"
done

echo "==> agents installed: ${order[*]}"
