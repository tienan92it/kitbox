#!/usr/bin/env bash
# opencode — third-party, model-agnostic coding agent.
set -euo pipefail
npm install -g "opencode-ai@${OPENCODE_VERSION:-latest}"
opencode --version || true
