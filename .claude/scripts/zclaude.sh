#!/bin/bash
# usage: zclaude.sh <workdir> <brief-file>  — runs zai GLM via claude CLI, clean env, token never printed
set -euo pipefail
K="$HOME/.claude/zai_key.json"; M="${ZAI_MODEL:-glm-5.3}"
cd "$1"
exec env -i HOME="$HOME" PATH="$PATH" USER="$USER" TERM=xterm LANG=en_US.UTF-8 \
  ANTHROPIC_BASE_URL="$(jq -r .env.ANTHROPIC_BASE_URL "$K")" \
  ANTHROPIC_AUTH_TOKEN="$(jq -r .env.ANTHROPIC_AUTH_TOKEN "$K")" \
  API_TIMEOUT_MS=3000000 ANTHROPIC_MODEL="$M" ANTHROPIC_DEFAULT_OPUS_MODEL="$M" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$M" ANTHROPIC_DEFAULT_HAIKU_MODEL="$M" \
  claude -p "$(cat "$2")" --allowedTools "Bash,Write,Edit,Read,Glob,Grep" --permission-mode acceptEdits --output-format json < /dev/null
