#!/usr/bin/env bash
# wiki-mcp 통합 실행기 — openwebui 번들 자체 완결형.
# 사용법:
#   ./run-wiki-mcp.sh serve     # MCP stdio 서버 (Claude Code / Cursor)
#   ./run-wiki-mcp.sh http      # 공용 MCP HTTP 서버 (:8765, Bearer 인증) — 유일한 Chroma writer
#   ./run-wiki-mcp.sh mcpo      # Open WebUI 연결용 REST 브리지 (:8766)
#   ./run-wiki-mcp.sh watch     # wiki 변경 감지 자동 재인덱싱
#
# Chroma 는 프로세스마다 HNSW 인덱스를 메모리에 둔다 → 벡터 저장소를 쓰거나 검색하는
# 프로세스는 하나여야 한다. wiki-mcp kit(guardian/wiki-mcp-kit) 은 `http` 하나를
# LaunchAgent(dev.guardian.wiki-mcp) 로 띄우고, mcpo 와 Claude Code 가 모두 그 서버를
# 바라보게 만든다(WIKI_MCPO_UPSTREAM=http). 그 상태에서 `serve` 와 stdio 업스트림의
# `mcpo` 는 두 번째 writer 가 생기는 것을 막으려 거부한다.
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

# 공용 HTTP 서버(wiki-mcp kit) — 유일한 Chroma writer. 키가 비면 server 는 경고만
# 내고 인증 없이 띄워 버리므로(WIKI_MCP_API_KEY 빈 값), 여기서 거부한다.
WIKI_MCP_HOST="${WIKI_MCP_HOST:-127.0.0.1}"
WIKI_MCP_PORT="${WIKI_MCP_PORT:-8765}"
WIKI_MCP_API_KEY="${WIKI_MCP_API_KEY:-}"
WIKI_MCPO_UPSTREAM="${WIKI_MCPO_UPSTREAM:-stdio}"

# http://127.0.0.1:$PORT/mcp 가 응답하는가 — 401/406/200 이면 서버가 살아 있다
# (인증·Accept 헤더 검사가 그보다 앞단이라 어떤 코드로도 "답한다"의 증거가 된다). 000 = 죽음.
http_up() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:${WIKI_MCP_PORT}/mcp")" || code=000
  case "$code" in 401|406|200) return 0 ;; *) return 1 ;; esac
}

cmd="${1:-serve}"
case "$cmd" in
  serve)
    # 공용 HTTP 서버가 이미 떠 있으면 stdio 로 두 번째 writer 를 만들지 않는다.
    if http_up; then
      echo "✗ 공용 wiki-mcp HTTP 서버가 127.0.0.1:${WIKI_MCP_PORT} 에서 이미 실행 중입니다." >&2
      echo "  Chroma 는 프로세스마다 인덱스를 따로 두므로 writer 는 하나여야 합니다." >&2
      echo "  Claude Code 에서는 stdio 대신 HTTP 등록을 쓰세요:" >&2
      echo "    claude mcp add-json wiki '{\"type\":\"http\",\"url\":\"http://127.0.0.1:${WIKI_MCP_PORT}/mcp\",\"headers\":{\"Authorization\":\"Bearer <WIKI_MCP_API_KEY>\"}}' -s user" >&2
      exit 1
    fi
    exec "$VENV/wiki-mcp"
    ;;
  http)
    if [ -z "$WIKI_MCP_API_KEY" ]; then
      echo "✗ WIKI_MCP_API_KEY 가 비어 있습니다. server 가 무인증으로 뜨는 것을 여기서 막는다." >&2
      echo "  .env 에 설정하세요 (생성: openssl rand -hex 24)" >&2
      exit 1
    fi
    export WIKI_MCP_TRANSPORT=http
    export WIKI_MCP_HOST
    export WIKI_MCP_PORT
    exec "$VENV/wiki-mcp"
    ;;
  mcpo)
    if [ -z "$WIKI_MCPO_KEY" ]; then
      echo "✗ WIKI_MCPO_KEY 가 비어 있습니다. .env 에 설정하세요 (생성: openssl rand -hex 24)" >&2
      exit 1
    fi
    if [ "$WIKI_MCPO_UPSTREAM" = "http" ]; then
      # 공용 HTTP 서버로 중계 — mcpo 는 기동 시 upstream 이 죽어 있으면 곧바로 죈다(status 3).
      # launchd 는 10초 뒤 다시 올리지만, 여기서 먼저 최대 30초 기다린다(로그인 직후엔
      # 두 LaunchAgent 가 동시에 올라와 http 쪽이 아직 준비 안 됐을 수 있다).
      if [ -z "$WIKI_MCP_API_KEY" ]; then
        echo "✗ WIKI_MCPO_UPSTREAM=http 인데 WIKI_MCP_API_KEY 가 비어 있습니다. .env 에 설정하세요 (생성: openssl rand -hex 24)" >&2
        exit 1
      fi
      i=1
      while [ "$i" -le 30 ]; do
        http_up && break
        sleep 1
        i=$((i + 1))
      done
      if ! http_up; then
        echo "✗ 공용 wiki-mcp HTTP 서버(127.0.0.1:${WIKI_MCP_PORT}) 가 30초 안에 응답하지 않았습니다." >&2
        echo "  원인은 ${WIKI_HOME:-~/llm-wiki}/logs/http.log 를 확인하세요. launchd 가 잠시 뒤 다시 시도합니다." >&2
        exit 1
      fi
      exec "$VENV/mcpo" --host "$WIKI_MCPO_HOST" --port "$WIKI_MCPO_PORT" --api-key "$WIKI_MCPO_KEY" \
        --server-type streamable-http \
        -H "{\"Authorization\":\"Bearer ${WIKI_MCP_API_KEY}\"}" \
        -- "http://127.0.0.1:${WIKI_MCP_PORT}/mcp"
    fi
    # stdio 업스트림도 serve 처럼 단일-writer 가드: 공용 HTTP 서버가 살아 있는데 mcpo 가
    # 자체 wiki-mcp 를 stdio 로 띄우면 writer 가 둘이 된다.
    if http_up; then
      echo "✗ WIKI_MCPO_UPSTREAM 가 stdio 인데 공용 wiki-mcp HTTP 서버가 127.0.0.1:${WIKI_MCP_PORT} 에서 이미 실행 중입니다." >&2
      echo "  이대로 진행하면 mcpo 가 자체 stdio wiki-mcp 를 띄워 writer 가 둘이 됩니다." >&2
      echo "  .env 에 WIKI_MCPO_UPSTREAM=http 를 설정하고 mcpo 를 다시 띄우세요(공용 서버로 중계)." >&2
      exit 1
    fi
    exec "$VENV/mcpo" --host "$WIKI_MCPO_HOST" --port "$WIKI_MCPO_PORT" --api-key "$WIKI_MCPO_KEY" -- "$VENV/wiki-mcp"
    ;;
  watch)
    exec "$VENV/wiki-mcp-watch"
    ;;
  *)
    echo "usage: $0 {serve|http|mcpo|watch}" >&2
    exit 2
    ;;
esac
