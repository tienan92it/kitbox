#!/usr/bin/env bash
# Grok CLI. Community-maintained (@vibe-kit), not an xAI product — pinned by
# default because a 0.0.x package can change shape without warning.
set -euo pipefail
npm install -g "@vibe-kit/grok-cli@${GROK_VERSION:-0.0.34}"
grok --version || true
