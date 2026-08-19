#!/usr/bin/env bash
# Bring the box up. Two modes, chosen by whether a tailnet key is present.
#
#   TS_AUTHKEY set   — join the tailnet, put `tailscale serve` in front, and
#                      bind kitterm to loopback with the tailnet name trusted.
#                      Reach it at https://<TS_HOSTNAME>.<tailnet>.ts.net/
#   TS_AUTHKEY unset — bind every interface in the container so a published
#                      port works. Reach it at http://localhost:<published>/
#
# Every step announces itself. `docker logs` is the only window into a box that
# never came up, so silence there is the worst possible failure mode.
set -euo pipefail

# `docker run kitbox <cmd>` runs that command instead of starting the box, so
# the image can be inspected without a daemon holding the terminal open.
if [ "$#" -gt 0 ]; then exec "$@"; fi

TS_HOSTNAME="${TS_HOSTNAME:-kitbox}"
PORT="${KITTERM_PORT:-3418}"
WORKSPACE="${WORKSPACE_DIR:-/workspace}"
SOCK=/run/tailscale/tailscaled.sock

say() { echo "[box] $*"; }
die() { echo "[box] ERROR: $*" >&2; exit 1; }

as_user() {
  su vscode -c "cd '$WORKSPACE' 2>/dev/null || cd /home/vscode; \
                PATH=$PATH SHELL=/bin/bash $1"
}

# --- single-volume mode --------------------------------------------------------
# Managed container platforms hand an instance one persistent volume, not five:
# "A Machine can only mount one volume at a time" is Fly's wording, and Railway,
# Render and ACI have the same shape. Set STATE_DIR to that volume and every
# path that has to outlive a restart is gathered into it.
#
# By symlink rather than by moving anything, so the five-volume compose setup —
# which leaves STATE_DIR unset — keeps working untouched, and one image serves
# both. Losing any of these costs something concrete: the tailnet identity is
# the stable hostname, .kitterm is the token behind your bookmark, and .claude
# is the login you would otherwise redo on every deploy.
link_state() {
  local live="$1" store="$STATE_DIR/$2" owner="$3"
  # Nesting the store inside the path it replaces would have the rm below
  # delete the state it just copied in.
  case "$store" in "$live"|"$live"/*) die "STATE_DIR must not sit inside $live";; esac
  mkdir -p "$store"
  # Seed from the image's copy on first boot only. Re-seeding every boot would
  # let an empty directory baked into the image overwrite real saved state.
  if [ -d "$live" ] && [ ! -L "$live" ] && [ -z "$(ls -A "$store" 2>/dev/null)" ]; then
    cp -a "$live/." "$store/" 2>/dev/null || true
  fi
  rm -rf "$live"
  # `ln -sfn` onto the final path, never a staged link renamed into place: the
  # rename follows the existing symlink and lands the new one inside its target.
  ln -sfn "$store" "$live"
  chown -R "$owner:$owner" "$store"
}

if [ -n "${STATE_DIR:-}" ]; then
  say "single-volume mode: state lives in $STATE_DIR"
  case "$STATE_DIR" in /*) ;; *) die "STATE_DIR must be an absolute path (got '$STATE_DIR')";; esac
  mkdir -p "$STATE_DIR" || die "cannot write to STATE_DIR=$STATE_DIR — is the volume mounted?"
  # The workspace is already relocatable, so point it at the volume instead of
  # symlinking it — unless the operator named a path themselves.
  WORKSPACE="${WORKSPACE_DIR:-$STATE_DIR/workspace}"
  link_state /home/vscode/.kitterm kitterm   vscode
  link_state /home/vscode/.claude  claude    vscode
  link_state /home/vscode/.codex   codex     vscode
  link_state /var/lib/tailscale    tailscale root   # tailscaled runs as root
fi

# --- state directories --------------------------------------------------------
# A named volume created by an older image is root-owned, and the daemon then
# cannot write its token. Repair rather than fail: this runs as root.
for d in /home/vscode/.kitterm /home/vscode/.claude /home/vscode/.codex; do
  mkdir -p "$d"
  [ "$(stat -c %U "$d")" = vscode ] || { say "fixing ownership of $d"; chown -R vscode:vscode "$d"; }
done

# Claude Code keeps its account state in ~/.claude.json — a file beside the
# directory, not inside it. Persisting ~/.claude alone therefore loses the login
# on every redeploy, which looks like the agent forgetting who you are.
#
# Park the real file inside the directory that is already persistent and leave a
# symlink where the CLI looks for it. That covers a named volume and STATE_DIR
# with nothing new to mount. Claude Code writes through the symlink rather than
# replacing it, so the indirection survives its own updates.
CLAUDE_JSON=/home/vscode/.claude.json
CLAUDE_STORE=/home/vscode/.claude/claude.json
if [ ! -L "$CLAUDE_JSON" ]; then
  # A real file here is state from an image that predates this, worth keeping.
  if [ -f "$CLAUDE_JSON" ] && [ ! -s "$CLAUDE_STORE" ]; then
    say "moving ~/.claude.json onto persistent storage"
    mv "$CLAUDE_JSON" "$CLAUDE_STORE"
  fi
  rm -f "$CLAUDE_JSON"
  # Dangling on a fresh box is fine: the first write creates the target.
  ln -sfn "$CLAUDE_STORE" "$CLAUDE_JSON"
  chown -h vscode:vscode "$CLAUDE_JSON"
fi

# --- workspace and git --------------------------------------------------------
mkdir -p "$WORKSPACE"
chown vscode:vscode "$WORKSPACE" 2>/dev/null || true

# Identity and credentials before the clone below. `gh auth setup-git` installs
# the credential helper that a private https clone needs; running it afterwards
# meant no token could ever reach git, and every private repo failed with
# "could not read Username".
if [ -n "${GIT_USER_NAME:-}" ]; then
  as_user "git config --global user.name '$GIT_USER_NAME'"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  as_user "git config --global user.email '$GIT_USER_EMAIL'"
fi
# Agents commit inside a container whose uid differs from the host's, which git
# reads as someone else's repository and refuses to touch.
as_user "git config --global --add safe.directory '$WORKSPACE'" 2>/dev/null || true
as_user "git config --global --add safe.directory '$WORKSPACE/*'" 2>/dev/null || true
if [ -n "${GH_TOKEN:-}" ]; then
  as_user "gh auth setup-git" >/dev/null 2>&1 \
    || say "warning: could not configure git to use GH_TOKEN"
fi

# The workspace holds projects, not one project's files. A repository lands in
# $WORKSPACE/<name>, so a second clone has somewhere to go and the name stays
# visible in the prompt and in every path the agent prints.
repo_dir_name() {
  local u="${1%/}"
  u="${u%.git}"
  printf '%s' "${u##*/}"
}

PROJECT_DIR="$WORKSPACE"
if [ -n "${WORKSPACE_REPO:-}" ]; then
  if [ -d "$WORKSPACE/.git" ]; then
    # A box built before the nested layout. Moving a checkout out from under a
    # running agent is not worth the tidiness, so leave it where it is.
    say "the workspace holds a checkout at its root; keeping the older layout"
  else
    PROJECT_DIR="$WORKSPACE/$(repo_dir_name "$WORKSPACE_REPO")"
  fi
fi

if [ -n "${WORKSPACE_REPO:-}" ] && [ ! -d "$PROJECT_DIR/.git" ]; then
  say "cloning $WORKSPACE_REPO into $PROJECT_DIR"
  # Loud, but not fatal. Dying here used to leave a container that restarted,
  # failed the same way, and restarted again — and the one tool you would use to
  # diagnose it is the terminal this box exists to serve. So the box comes up
  # with an empty workspace and says exactly what went wrong; `doctor` repeats
  # it, and you can fix the clone from inside.
  if ! as_user "git clone '$WORKSPACE_REPO' '$PROJECT_DIR'"; then
    say "ERROR: could not clone $WORKSPACE_REPO"
    say "       The box is starting anyway, with an empty workspace, so you can"
    say "       fix this from a terminal. Common causes:"
    say "       - an ssh host alias from your laptop's ~/.ssh/config, which does"
    say "         not exist in here — use the https:// URL instead"
    say "       - a git@ URL with no key mounted at /home/vscode/.ssh"
    if [ -z "${GH_TOKEN:-}" ]; then
      say "       - a private repo over https:// with no GH_TOKEN set"
    else
      say "       - GH_TOKEN is set but GitHub rejected it, or it lacks access"
      say "         to this repository"
    fi
  fi
fi

# Every pane starts here. .bashrc reads this, because STATE_DIR moves the
# workspace and the image has a literal baked in otherwise.
if [ -d "$PROJECT_DIR" ]; then
  export KITBOX_WORKSPACE="$PROJECT_DIR"
else
  export KITBOX_WORKSPACE="$WORKSPACE"
fi

# --- agent control -------------------------------------------------------------
# --agent-control opens POST /api/sessions/<id>/input, so anything holding a
# full-grade token can type into a shell rather than only watch one. On unless
# you say otherwise, because driving an agent from a phone is what the box is
# for — but a leaked token is then a keyboard, not a window, so set
# AGENT_CONTROL=0 where that is not a risk you will take.
#
# The browser terminal is unaffected either way: its keystrokes travel over the
# WebSocket, which the daemon grades by token, not by this flag. Turning this
# off closes the HTTP write route and nothing else.
case "$(printf '%s' "${AGENT_CONTROL:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off)
    AGENT_CONTROL_FLAG=""
    say "agent control off — POST /api/sessions/<id>/input is closed" ;;
  *)
    AGENT_CONTROL_FLAG="--agent-control" ;;
esac

# --- remote access ------------------------------------------------------------
if [ -n "${TS_AUTHKEY:-}" ]; then
  say "starting tailscaled (userspace networking)"
  mkdir -p /var/lib/tailscale /run/tailscale
  tailscaled --tun=userspace-networking \
             --state=/var/lib/tailscale/tailscaled.state \
             --socket="$SOCK" >/var/log/tailscaled.log 2>&1 &
  for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 1; done
  [ -S "$SOCK" ] || die "tailscaled never created its socket. Log:
$(tail -20 /var/log/tailscaled.log 2>/dev/null)"

  say "joining the tailnet as '$TS_HOSTNAME'"
  # --accept-dns=false is load-bearing. MagicDNS rewrites resolv.conf to
  # 100.100.100.100, which nothing in the container can reach under userspace
  # networking, and then every lookup times out — including the agent's calls
  # to its own API, which is a baffling way to discover a DNS problem.
  #
  # Bounded, because `tailscale up` has no timeout of its own and blocks
  # forever when the tailnet requires an admin to approve new machines.
  if ! timeout 90 tailscale --socket="$SOCK" up \
            --authkey="$TS_AUTHKEY" \
            --hostname="$TS_HOSTNAME" \
            --accept-dns=false; then
    say "--- tailscale status ---"; tailscale --socket="$SOCK" status 2>&1 | head -10 || true
    say "--- tailscaled log ---";   tail -15 /var/log/tailscaled.log 2>/dev/null || true
    die "could not join the tailnet.
       If it stalled rather than failed, this machine is waiting for approval:
         https://login.tailscale.com/admin/machines
       Otherwise check the key is unused and unexpired:
         https://login.tailscale.com/admin/settings/keys"
  fi

  # Parse the name properly: every peer carries a DNSName too, so grepping the
  # first match in the status JSON can return somebody else's machine.
  say "reading this node's DNS name"
  FQDN=$(tailscale --socket="$SOCK" status --json \
         | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
             try{ process.stdout.write((JSON.parse(s).Self?.DNSName||"").replace(/\.$/,"")) }catch(e){}
           })')
  [ -n "$FQDN" ] || die "joined the tailnet but this node has no DNS name.
       Enable MagicDNS: https://login.tailscale.com/admin/dns"
  say "this box is $FQDN"

  # HTTPS needs a certificate, which the tailnet only issues when HTTPS
  # Certificates is enabled. Without it the TLS handshake fails and each
  # attempt burns a Let's Encrypt authorization — five rate-limit the name for
  # an hour — so HTTP is an explicit choice, never an automatic retry.
  if [ -n "${TS_SERVE_HTTP:-}" ]; then
    say "serving plain HTTP over the tailnet (TS_SERVE_HTTP set, no certificate)"
    SCHEME=http
    tailscale --socket="$SOCK" serve --bg --http=80 "$PORT" || die "tailscale serve failed"
  else
    say "serving HTTPS over the tailnet"
    SCHEME=https
    tailscale --socket="$SOCK" serve --bg "$PORT" \
      || die "tailscale serve failed. Enable HTTPS Certificates, or set
       TS_SERVE_HTTP=1 to serve without one:
         https://login.tailscale.com/admin/dns"
  fi

  # Requests arriving under the tailnet name are treated as remote even though
  # tailscale reaches the daemon over loopback, so they must present a token.
  # The proxy is a boundary, not a bypass.
  say "starting kitterm, trusting $FQDN"
  as_user "kitterm start --port $PORT $AGENT_CONTROL_FLAG --trusted-host $FQDN" \
    || die "kitterm failed to start"
  URL_BASE="$SCHEME://$FQDN"
else
  say "no TS_AUTHKEY — local mode, binding all interfaces in this container"
  as_user "kitterm start --port $PORT --lan $AGENT_CONTROL_FLAG" \
    || die "kitterm failed to start"
  URL_BASE="http://localhost:${PUBLISHED_PORT:-$PORT}"
fi

# A named token survives restarts and can be revoked without bouncing the
# daemon, unlike the ephemeral one. kitterm stores only its hash and shows the
# value once, so keep our own copy beside it — both live on the same volume, so
# a bookmarked link keeps working across restarts.
TOKEN_FILE=/home/vscode/.kitterm/kitbox-token
mint_token() {
  as_user "kitterm token revoke phone" >/dev/null 2>&1 || true
  local fresh
  fresh=$(as_user "kitterm token create phone" 2>/dev/null | tail -1)
  case "$fresh" in
    ktk_*) printf '%s' "$fresh" > "$TOKEN_FILE"
           chown vscode:vscode "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
           printf '%s' "$fresh" ;;
    *) return 1 ;;
  esac
}

# A stored token is worthless if the daemon's own store was wiped without this
# file, so prove it before printing it in a URL.
#
# Not by asking loopback: the daemon trusts every loopback peer unconditionally
# and never looks at the token, so `127.0.0.1/api/health?token=anything` returns
# 200 and proves nothing. Naming the trusted host is what marks a request as
# arriving from outside — the same grading a phone gets through the proxy.
token_works() {
  if [ -n "${FQDN:-}" ]; then
    curl -fsS -m 5 -o /dev/null -H "Host: $FQDN" \
         "http://127.0.0.1:$PORT/api/health?token=$1" 2>/dev/null
  else
    # Local mode has no trusted host to name, so compare against the store
    # instead: no `phone` entry means this file outlived the hash it matched.
    as_user "kitterm token list" 2>/dev/null | grep -q "^phone[[:space:]]"
  fi
}

TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
if [ -n "$TOKEN" ]; then
  if ! token_works "$TOKEN"; then
    say "the stored token no longer authenticates; minting a new one"
    TOKEN="$(mint_token || true)"
  else
    say "reusing the token from a previous run"
  fi
else
  TOKEN="$(mint_token || true)"
fi
[ -n "${TOKEN:-}" ] || die "daemon started but produced no access token"

echo
echo "================================================================"
echo "  Open this on your phone and your laptop:"
echo "    $URL_BASE/?token=$TOKEN"
echo
# The client keeps its pane layout in sessionStorage, which is per tab. Reload a
# tab and it reattaches to the same shell; open the app fresh and it starts a
# new one, so the scrollback looks lost. This page lists what is still running.
echo "  Reconnecting later? This lists the shells still running:"
echo "    $URL_BASE/sessions?token=$TOKEN"
echo
INSTALLED=""
for a in claude codex grok opencode; do
  command -v "$a" >/dev/null 2>&1 && INSTALLED="$INSTALLED $a"
done
echo "  Agents:${INSTALLED:- none}"
echo "  Diagnose problems with:  docker exec <name> doctor"
echo "================================================================"
echo

say "box is up; leave this container running"

# The daemon and its shells are detached, so this process is both what keeps
# the container alive and the only thing that can notice the daemon dying.
# Sitting on `tail -f /dev/null` would keep the container "running" around a
# dead daemon forever, and `restart: unless-stopped` would never fire.
shutdown() {
  say "shutting down"
  as_user "kitterm stop" >/dev/null 2>&1 || true
  exit 0
}
trap shutdown TERM INT

while true; do
  # Backgrounded, because bash defers a trap until the foreground command
  # returns — a plain `sleep 10` would make every `docker stop` wait out its
  # full ten-second grace period before the container died.
  sleep 10 & wait $! || true
  curl -fsS -m 5 -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null \
    || die "kitterm stopped answering on port $PORT. Exiting so the container
       restarts. Log: /home/vscode/.kitterm/server.log"
done
