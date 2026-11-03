#!/usr/bin/env bash
# wiki-mcp 통합 실행기 — openwebui 번들 자체 완결형.
# 사용법:
#   ./run-wiki-mcp.sh serve     # MCP stdio 서버 (Claude Code / Cursor)
#   ./run-wiki-mcp.sh mcpo      # Open WebUI 연결용 REST 브리지 (:8766)
#   ./run-wiki-mcp.sh watch     # wiki 변경 감지 자동 재인덱싱
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- .env 자동 로드 (있으면). 셸 환경변수가 우선한다. ---
# shellcheck source=load-env.sh
[ -f "$HERE/load-env.sh" ] && . "$HERE/load-env.sh" && load_env "$HERE/.env"

# venv 위치 — 기본은 번들 안 .venv. guardian 통합 설치는 ~/.guardian-llm/venv 를 쓴다.
VENV="${WIKI_VENV:-$HERE/.venv}/bin"

# --- 번들 내부 경로만 사용 (스크립트 위치 기준 — 외부 저장소 의존 없음) ---
export WIKI_PATH="${WIKI_PATH:-$HERE/wiki}"
export WIKI_DATA_DIR="${WIKI_DATA_DIR:-$HERE/wiki-data}"
# 에어갭 기본: Ollama 없이 BM25-only. Ollama bge-m3 쓰려면 EMBEDDING_DISABLED 해제.
export EMBEDDING_DISABLED="${EMBEDDING_DISABLED:-1}"

# mcpo 인증 키 — 기본값 없음. .env 의 WIKI_MCPO_KEY 필수 (mcpo 모드만)
WIKI_MCPO_HOST="${WIKI_MCPO_HOST:-127.0.0.1}"
WIKI_MCPO_PORT="${WIKI_MCPO_PORT:-8766}"
WIKI_MCPO_KEY="${WIKI_MCPO_KEY:-}"

cmd="${1:-serve}"
case "$cmd" in
  serve)
    exec "$VENV/wiki-mcp"
    ;;
  mcpo)
    if [ -z "$WIKI_MCPO_KEY" ]; then
      echo "✗ WIKI_MCPO_KEY 가 비어 있습니다. .env 에 설정하세요 (생성: openssl rand -hex 24)" >&2
      exit 1
    fi
    exec "$VENV/mcpo" --host "$WIKI_MCPO_HOST" --port "$WIKI_MCPO_PORT" --api-key "$WIKI_MCPO_KEY" -- "$VENV/wiki-mcp"
    ;;
  watch)
    exec "$VENV/wiki-mcp-watch"
    ;;
  *)
    echo "usage: $0 {serve|mcpo|watch}" >&2
    exit 2
    ;;
esac
