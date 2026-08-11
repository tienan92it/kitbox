#!/usr/bin/env bash
# Claude Code — Anthropic's official CLI.
set -euo pipefail
npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION:-latest}"
claude --version
