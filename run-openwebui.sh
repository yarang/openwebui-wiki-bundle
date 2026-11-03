#!/usr/bin/env bash
# Open WebUI 실행기 — 번들 루트의 .env를 로드하고 오프라인 기본값을 적용한다.
#
# 사용법:
#   ./run-openwebui.sh                 # http://localhost:8080
#   ./run-openwebui.sh --port 8081     # 인자는 open-webui serve 로 그대로 전달
#   (.env 의 WEBUI_PORT 로 기본 포트를 바꿀 수 있다)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# --- .env 자동 로드 (있으면). 셸 환경변수가 우선한다. ---
# shellcheck source=load-env.sh
[ -f "$HERE/load-env.sh" ] && . "$HERE/load-env.sh" && load_env "$HERE/.env"

# --- 에어갭 기본값: 외부 네트워크 호출 차단 (첫 기동 지연/오류 방지) ---
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export OFFLINE_MODE="${OFFLINE_MODE:-1}"

[ -x "$HERE/.venv/bin/open-webui" ] || {
  echo "✗ open-webui 미설치 — 먼저 ./install.sh 를 실행하세요." >&2
  exit 1
}

# --- 런타임 데이터(DB·업로드)는 번들 안 data/ 에 둔다 (.venv 재생성에도 보존) ---
export DATA_DIR="${DATA_DIR:-$HERE/data}"
# 0.10.2 번들은 DATA_DIR 없이 .venv 안 패키지 폴더에 데이터를 두었다.
# 옮기지 않고 띄우면 빈 DB로 시작해 기존 계정·채팅이 안 보이므로 여기서 멈춘다.
LEGACY="$(ls -d "$HERE"/.venv/lib/python3.*/site-packages/open_webui/data 2>/dev/null | head -1)"
if [ ! -f "$DATA_DIR/webui.db" ] && [ -n "$LEGACY" ] && [ -f "$LEGACY/webui.db" ]; then
  echo "✗ 이전 데이터가 .venv 안에 있습니다: $LEGACY" >&2
  echo "  Open WebUI를 끈 상태에서 옮긴 뒤 다시 실행하세요:  mv \"$LEGACY\" \"$DATA_DIR\"" >&2
  exit 1
fi

exec "$HERE/.venv/bin/open-webui" serve --port "${WEBUI_PORT:-8080}" "$@"
