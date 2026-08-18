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

# Read the version already on the machine, so the install can report a change
# rather than leaving you to guess whether it did anything.
# raw.githubusercontent.com sets max-age=300, so for five minutes after a push
# this still fetches the previous file. A reinstall that reports no version
# change right after a release is the cache, not a failure.
prev=""
if command -v kitbox >/dev/null 2>&1; then
  prev=$(kitbox version 2>/dev/null | awk '{print $2}')
fi

if [ -w "$PREFIX" ]; then
  install -m 755 "$tmp" "$PREFIX/kitbox"
else
  echo "install: $PREFIX needs root; using sudo"
  sudo install -m 755 "$tmp" "$PREFIX/kitbox"
fi

new=$("$PREFIX/kitbox" version | awk '{print $2}')
if [ -z "$prev" ]; then
  echo "installed kitbox $new to $PREFIX/kitbox"
elif [ "$prev" = "$new" ]; then
  echo "kitbox $new reinstalled to $PREFIX/kitbox (no version change)"
else
  echo "kitbox $prev -> $new in $PREFIX/kitbox"
fi

# A copy earlier in PATH keeps winning after this install, and every command you
# run afterwards is the old one. Say so rather than let it confuse a deploy.
found=$(command -v kitbox 2>/dev/null || true)
if [ -n "$found" ] && [ "$found" != "$PREFIX/kitbox" ]; then
  echo
  echo "warning: your PATH finds $found first, not $PREFIX/kitbox"
  echo "         that copy reports version $("$found" version 2>/dev/null | awk '{print $2}')"
  echo "         remove it, or put $PREFIX earlier in PATH"
fi
echo
echo "Next, from inside any project:"
echo "  kitbox init"
echo "  kitbox deploy"
