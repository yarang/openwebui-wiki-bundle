#!/usr/bin/env bash
# 오프라인(에어갭) 설치 스크립트 — macOS arm64.
# INSTALL.md 3장 절차를 그대로 자동화한다. 네트워크 접근 없음(로컬 wheel만 사용).
#
# 사용법:
#   ./install.sh                 # 설치 (기존 .venv 있으면 재사용)
#   ./install.sh --recreate      # .venv 새로 만들고 설치
#   PYVER=3.11 ./install.sh       # Python 버전 지정(기본: 3.12 우선, 없으면 3.11)
set -euo pipefail

OW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$OW"
PKGS="$OW/openwebui-packages"
PY="$OW/.venv/bin/python"
UVPIP=(uv pip install --python "$PY" --offline --no-index --find-links="$PKGS")

log() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 0. 사전 요구사항 점검 ────────────────────────────────────────────────
log "사전 요구사항 점검"
command -v uv >/dev/null 2>&1 || die "uv 미설치 — 대상 장비에 uv 바이너리를 먼저 반입하세요."
[ -d "$PKGS" ] || die "wheel 저장소 없음: $PKGS"

# 사용할 Python 버전 결정 (로컬에 이미 있는 것만)
choose_py() {
  local want="${PYVER:-}"
  local installed; installed="$(uv python list --only-installed 2>/dev/null || true)"
  if [ -n "$want" ]; then echo "$want"; return; fi
  if grep -q "cpython-3.12" <<<"$installed"; then echo "3.12"; return; fi
  if grep -q "cpython-3.11" <<<"$installed"; then echo "3.11"; return; fi
  die "로컬에 Python 3.11/3.12 인터프리터가 없습니다. 대상 장비에 먼저 설치하세요.
     (uv python list --only-installed 로 확인)"
}
PYVER="$(choose_py)"
log "Python $PYVER 사용"

# ── 1. 가상환경 ──────────────────────────────────────────────────────────
if [ "${1:-}" = "--recreate" ]; then rm -rf "$OW/.venv"; fi
if [ -d "$OW/.venv" ]; then
  log "기존 .venv 재사용 (새로 만들려면 --recreate)"
else
  log "가상환경 생성 (오프라인)"
  uv venv --offline --no-python-downloads --python "$PYVER" "$OW/.venv"
fi

# ── 2. Open WebUI ────────────────────────────────────────────────────────
log "Open WebUI 설치"
"${UVPIP[@]}" open-webui==0.12.3

# ── 3. 빌드 도구 (editable -e 전제) ──────────────────────────────────────
log "빌드 도구(setuptools, wheel) 설치"
"${UVPIP[@]}" setuptools wheel

# ── 4. wiki-mcp (editable) ───────────────────────────────────────────────
log "wiki-mcp 설치 (editable)"
"${UVPIP[@]}" --no-build-isolation -e "$OW/wiki-mcp"

# ── 5. mcpo (REST 브리지) ────────────────────────────────────────────────
log "mcpo 설치"
"${UVPIP[@]}" mcpo

# ── 5-1. 문서 생성 라이브러리 (Open WebUI '문서 생성기' Tool 용) ─────────
# docx/pptx/xlsx 생성. 오프라인 wheel(openwebui-packages)에 모두 포함.
log "문서 생성 라이브러리 설치 (python-docx, python-pptx, openpyxl)"
"${UVPIP[@]}" python-docx python-pptx openpyxl

# ── 6. 검증 ──────────────────────────────────────────────────────────────
log "설치 검증"
# EMBEDDING_DISABLED=1 로 임포트 부작용(예제 wiki 인덱싱/Ollama 접근) 억제.
# server 대신 부작용 없는 모듈로 존재/경로 확인.
EMBEDDING_DISABLED=1 "$PY" - <<'PYEOF'
from importlib.metadata import version
import open_webui  # noqa: F401  (설치 확인)
import wiki_mcp    # editable 경로 확인 (server 미임포트 → 인덱싱 안 함)
for p in ["open-webui", "wiki-mcp", "mcpo"]:
    print(f"   {p}: {version(p)}")
print("   editable:", wiki_mcp.__file__)
PYEOF
for b in open-webui wiki-mcp wiki-mcp-watch mcpo; do
  [ -x "$OW/.venv/bin/$b" ] || die "실행 파일 누락: $b"
done

printf '\n\033[1;32m✓ 설치 완료\033[0m\n'
cat <<EOF

다음 단계:
  source .venv/bin/activate

  # Open WebUI 실행
  export HF_HUB_OFFLINE=1 OFFLINE_MODE=1
  open-webui serve                  # http://localhost:8080

  # Wiki MCP 실행 (택1)
  ./run-wiki-mcp.sh mcpo            # Open WebUI 연결용 REST 브리지 (:8766)
  ./run-wiki-mcp.sh serve           # Claude Code / Cursor (stdio)
  ./run-wiki-mcp.sh watch           # raw/ 자동 위키화 (ingestion 설정 시)

자세한 내용은 INSTALL.md 참고.
EOF
