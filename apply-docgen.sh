#!/usr/bin/env bash
# 문서 생성 add-on 적용기 — 에어갭 번들에 파일 반입 + 라이브러리 오프라인 설치.
# (docgen-addon 키트 최상위에 담겨 배포된다. 대상 장비에서 이 스크립트를 실행한다.)
#
# 사용법 (반입한 키트를 풀고 실행):
#   ./apply-docgen.sh <설치된 번들 루트 경로>
#   (인자 생략 시 현재 디렉토리를 번들 루트로 간주)
#
# 하는 일:
#   1) open-webui-tools/, document-templates/, docs/DOCUMENT-TOOL.md 를 번들로 복사
#      (테마 파일은 사용자 편집 보존 — 없을 때만 복사)
#   2) python-docx(신규) 오프라인 설치 (pptx/openpyxl 는 이미 있으면 audit)
#   3) 임포트 검증 후 다음 단계(UI 등록) 안내
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 이 스크립트가 든 키트 디렉토리
OW="${1:-$PWD}"                                        # 설치된 번들 루트
PY="$OW/.venv/bin/python"

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -x "$PY" ] || die ".venv 파이썬 없음: $PY — 설치된 번들 루트를 인자로 주세요. 예) ./apply-docgen.sh /path/to/openwebui"

# ── 1. 파일 반입 ─────────────────────────────────────────────────────────
log "파일 복사 → $OW"
mkdir -p "$OW/open-webui-tools" "$OW/document-templates" "$OW/docs"
cp -f "$KIT/open-webui-tools/document_generator.py" "$OW/open-webui-tools/"
echo "   복사: open-webui-tools/document_generator.py"
# 템플릿 자동화 스크립트 (0.1.7+)
if [ -f "$KIT/fill_template.py" ]; then
  cp -f "$KIT/fill_template.py" "$OW/"
  echo "   복사: fill_template.py"
fi
# 시각 테마 — 기존 편집 보존 (없을 때만 복사)
for f in build_theme.py theme-default.docx theme-default.pptx \
         theme-corporate.docx theme-corporate.pptx; do
  if [ -e "$OW/document-templates/$f" ]; then
    echo "   유지(기존): document-templates/$f"
  elif [ -e "$KIT/document-templates/$f" ]; then
    cp -f "$KIT/document-templates/$f" "$OW/document-templates/"
    echo "   복사: document-templates/$f"
  fi
done
# 콘텐츠 템플릿 (tpl-*.md) — 항상 덮어쓰기 (사용자 편집 보존 불필요, 구조 정의 파일)
for f in "$KIT"/document-templates/tpl-*.md; do
  if [ -f "$f" ]; then
    cp -f "$f" "$OW/document-templates/"
    echo "   복사: document-templates/$(basename "$f")"
  fi
done
[ -f "$KIT/docs/DOCUMENT-TOOL.md" ] && cp -f "$KIT/docs/DOCUMENT-TOOL.md" "$OW/docs/"

# ── 2. 라이브러리 오프라인 설치 ──────────────────────────────────────────
# uv 가 있으면 uv pip, 없으면 순수 파이썬 wheel 을 site-packages 에 직접 푼다.
log "문서 라이브러리 설치 (python-docx 신규)"

find_uv() {
  local c
  for c in uv "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0
    elif [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

extract_wheel() {  # $1=모듈명 $2=wheel 글롭 — 모듈이 없을 때만 unzip 설치
  local mod="$1" glob="$2" sp w
  "$PY" -c "import $mod" 2>/dev/null && return 0
  command -v unzip >/dev/null 2>&1 || die "unzip 없음 — 수동 wheel 설치 불가"
  sp="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  [ -n "$sp" ] || die "site-packages 경로 확인 실패"
  w="$(ls "$KIT/wheels/"$glob 2>/dev/null | head -1 || true)"
  [ -n "$w" ] || die "wheel 없음: $glob"
  unzip -o -q "$w" -d "$sp"
  echo "   수동 설치: $(basename "$w") → site-packages"
}

if UV="$(find_uv)"; then
  echo "   uv: $UV"
  FIND=(--find-links="$KIT/wheels")
  [ -d "$OW/openwebui-packages" ] && FIND+=(--find-links="$OW/openwebui-packages")
  "$UV" pip install --python "$PY" --offline --no-index "${FIND[@]}" \
    python-docx python-pptx openpyxl python-frontmatter \
    || die "uv 오프라인 설치 실패 — 대상 venv에 lxml 이 있는지, 키트 wheels/ 가 온전한지 확인"
else
  echo "   uv 없음 — 순수 파이썬 wheel 직접 설치로 진행"
  extract_wheel typing_extensions "typing_extensions-*.whl"
  extract_wheel docx "python_docx-*.whl"
fi

# ── 3. 검증 ──────────────────────────────────────────────────────────────
log "검증"
"$PY" -c "import docx; print('   python-docx', docx.__version__)" \
  || die "docx import 실패 — lxml 이 대상 venv 에 있는지 확인 (원 번들 의존성)"
for m in pptx openpyxl frontmatter; do
  "$PY" -c "import $m" 2>/dev/null && echo "   $m OK" \
    || printf '\033[1;33m! %s 없음 — 템플릿 자동화에 필요합니다(키트 wheels/ 확인)\033[0m\n' "$m"
done

printf '\n\033[1;32m✓ 파일/라이브러리 적용 완료\033[0m\n'
cat <<EOF

남은 단계 (Open WebUI UI — 장비별 1회):
  1) Open WebUI 재시작 권장:  (실행 중이면) open-webui serve 재기동
  2) Workspace → Tools → ➕ → $OW/open-webui-tools/document_generator.py 붙여넣기 → Save
  3) 그 Tool ⚙️ Valves → templates_dir = $OW/document-templates
  4) (권장) Workspace → Models 에 "문서 작성 도우미" 프리셋 + 이 Tool 연결

템플릿 자동화 (채팅 없이 CLI로 문서 생성, 오프라인 전용 — mock 데이터만 사용):
  .venv/bin/python fill_template.py --list                    # 템플릿 목록
  .venv/bin/python fill_template.py tpl-report-quarterly.md \\  # 문서 생성
      --topic "주제"

자세한 내용: $OW/docs/DOCUMENT-TOOL.md
EOF
