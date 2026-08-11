# A box that runs coding agents and serves their terminals to your phone.
#
#   docker build -t agentbox .
#
# Everything is inside: kitterm, the agents you asked for, Tailscale, git, and
# the tools worth having when your only screen is a phone.
#
# The base is Microsoft's devcontainers image — the same one agentbox-style
# sandboxes use — so it already carries the `vscode` user, git, and sudo.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- system tools -------------------------------------------------------------
# Chosen for working without a laptop: search (ripgrep, fd), JSON (jq), a
# multiplexer for long-running agents (tmux), and a pager that behaves in a
# browser terminal.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates curl wget gnupg \
      git openssh-client \
      ripgrep fd-find jq tmux less unzip zip \
      build-essential python3 python3-pip \
      iptables procps htop \
 && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# GitHub CLI, from its own apt repository: it is not in Ubuntu's.
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      > /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -qq && apt-get install -y -qq --no-install-recommends gh \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Tailscale, and Node for the agent CLIs.
RUN curl -fsSL https://tailscale.com/install.sh | sh \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y -qq --no-install-recommends nodejs \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- kitterm ------------------------------------------------------------------
# The release tarball is statically linked, so nothing here needs a Swift
# toolchain, and its layout is self-locating: lib/kitterm/kitterm resolves
# ../../share/kitterm/web, so extracting to /usr/local is the entire install.
#
# A tarball dropped into ./dist wins over the download — that is how you test a
# kitterm build that has not been released yet.
ARG KITTERM_VERSION=v0.14.0
ARG KITTERM_REPO=tienan92it/kitterm
ARG TARGETARCH
COPY dist/ /tmp/localdist/
RUN set -eu; \
    LOCAL="$(find /tmp/localdist -name "kitterm-*-linux-${TARGETARCH}.tar.gz" | head -1)"; \
    if [ -n "$LOCAL" ]; then \
      echo "using local tarball $LOCAL"; \
      tar -xzf "$LOCAL" -C /usr/local; \
    else \
      BASE="https://github.com/${KITTERM_REPO}/releases/download/${KITTERM_VERSION}"; \
      NAME="kitterm-${KITTERM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
      curl -fsSL -o /tmp/kitterm.tar.gz "$BASE/$NAME"; \
      curl -fsSL -o /tmp/kitterm.sha256 "$BASE/$NAME.sha256" || true; \
      if [ -s /tmp/kitterm.sha256 ]; then \
        echo "$(cat /tmp/kitterm.sha256)  /tmp/kitterm.tar.gz" | sha256sum -c -; \
      else \
        echo "warning: no published checksum for $NAME" >&2; \
      fi; \
      tar -xzf /tmp/kitterm.tar.gz -C /usr/local; \
    fi; \
    rm -rf /tmp/localdist /tmp/kitterm.tar.gz /tmp/kitterm.sha256; \
    # A dynamically linked build would exec fine here and then kill every
    # session the moment a shell is spawned. Catch it at build time.
    for b in kitterm kitterm-spawn-helper; do \
      if ldd "/usr/local/lib/kitterm/$b" 2>/dev/null | grep -q swift; then \
        echo "error: $b links the Swift runtime; this image would have no working shells" >&2; \
        exit 1; \
      fi; \
    done; \
    kitterm --version || true

# --- agents -------------------------------------------------------------------
# Comma-separated, claude always included. Each installer is its own script so
# adding one is a file, not a Dockerfile edit.
ARG AGENTS=claude
COPY agents/ /opt/agentbox/agents/
RUN chmod +x /opt/agentbox/agents/*.sh \
 && /opt/agentbox/agents/install.sh "$AGENTS"

# --- the box ------------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/agentbox-entrypoint
COPY bin/doctor /usr/local/bin/doctor
RUN chmod 755 /usr/local/bin/agentbox-entrypoint /usr/local/bin/doctor

# Shell integration is what makes commands, exit codes and durations visible
# over the API. Without it the supervision layer is dark: /api/.../commands
# stays empty forever. `cd /workspace` puts panes in the project, not $HOME.
RUN su vscode -c 'kitterm integrate bash >> /home/vscode/.bashrc' \
 && printf '\n# Open panes in the workspace, not $HOME.\ncd /workspace 2>/dev/null || true\n' \
      >> /home/vscode/.bashrc \
 && mkdir -p /workspace && chown vscode:vscode /workspace

# Named volumes are seeded from the image, ownership and all. Without these
# directories existing here, Docker creates the mount points root-owned and the
# daemon cannot write its own token — it exits before becoming healthy.
RUN mkdir -p /home/vscode/.kitterm /home/vscode/.claude /home/vscode/.codex \
 && chown -R vscode:vscode /home/vscode/.kitterm /home/vscode/.claude /home/vscode/.codex

ENV SHELL=/bin/bash
WORKDIR /workspace
EXPOSE 3418
ENTRYPOINT ["/usr/local/bin/agentbox-entrypoint"]
