#!/usr/bin/env bash
# Install the kitbox command.
#
#   curl -fsSL https://raw.githubusercontent.com/tienan92it/kitbox/main/install.sh | sh
#
# Or, if you would rather read it first — which you should, for anything you
# pipe into a shell:
#
#   curl -fsSLO https://raw.githubusercontent.com/tienan92it/kitbox/main/install.sh
#   less install.sh && sh install.sh
set -eu

REPO=${KITBOX_REPO:-tienan92it/kitbox}
REF=${KITBOX_REF:-main}
PREFIX=${KITBOX_PREFIX:-/usr/local/bin}
SRC="https://raw.githubusercontent.com/$REPO/$REF/bin/kitbox"

command -v curl >/dev/null 2>&1 || { echo "install: curl is required" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "$SRC" || { echo "install: could not fetch $SRC" >&2; exit 1; }

# A truncated download that still exits 0 would install a broken command, and
# the failure would show up later as a syntax error in the middle of a deploy.
head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' \
  || { echo "install: $SRC did not look like the kitbox script" >&2; exit 1; }
bash -n "$tmp" || { echo "install: the downloaded script does not parse" >&2; exit 1; }

if [ -w "$PREFIX" ]; then
  install -m 755 "$tmp" "$PREFIX/kitbox"
else
  echo "install: $PREFIX needs root; using sudo"
  sudo install -m 755 "$tmp" "$PREFIX/kitbox"
fi

echo "installed $("$PREFIX/kitbox" version) to $PREFIX/kitbox"
echo
echo "Next, from inside any project:"
echo "  kitbox init"
echo "  kitbox deploy"
