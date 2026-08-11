#!/usr/bin/env bash
# Codex — OpenAI's official CLI.
set -euo pipefail
npm install -g "@openai/codex@${CODEX_VERSION:-latest}"
codex --version
