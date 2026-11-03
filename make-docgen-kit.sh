#!/usr/bin/env bash
# 문서 생성 add-on 키트 빌더 — 에어갭 장비에 물리 반입할 소형 꾸러미를 만든다.
# 전체 번들(800MB+) 재반입 없이, 문서 생성 기능만 얹기 위한 것.
#
# 산출물: dist/docgen-addon-<ver>.tar.gz (+ .sha256)
#   구조: docgen-addon/{apply-docgen.sh, open-webui-tools/, document-templates/,
#                        docs/DOCUMENT-TOOL.md, wheels/*.whl}
#
# 사용법:
#   ./make-docgen-kit.sh              # dist/ 에 키트 생성
#   ./make-docgen-kit.sh --publish    # 생성 후 Gitea Release 에 업로드 (재배포)
#   ./make-docgen-kit.sh --publish v0.1.1
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

VER="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' open-webui-tools/document_generator.py 2>/dev/null | head -1)"
VER="${VER:-$(grep -m1 'version:' open-webui-tools/document_generator.py | sed -E 's/.*version:[[:space:]]*//')}"
VER="${VER:-0.1.0}"
NAME="docgen-addon-${VER}"
STAGE="dist/${NAME}"
OUT="dist/${NAME}.tar.gz"

log "add-on 키트: $NAME"
rm -rf "$STAGE" "$OUT" "${OUT}.sha256"
mkdir -p "$STAGE/open-webui-tools" "$STAGE/document-templates" "$STAGE/docs" "$STAGE/wheels"

# ── 소스 파일 ────────────────────────────────────────────────────────────
cp -f apply-docgen.sh "$STAGE/"
cp -f open-webui-tools/document_generator.py "$STAGE/open-webui-tools/"
cp -f fill_template.py "$STAGE/" 2>/dev/null || warn "fill_template.py 없음 — 템플릿 자동화 제외"
cp -f docs/DOCUMENT-TOOL.md "$STAGE/docs/"
# 시각 테마 (default + corporate 있으면 포함)
for f in build_theme.py theme-default.docx theme-default.pptx \
         theme-corporate.docx theme-corporate.pptx; do
  if [ -f "document-templates/$f" ]; then
    cp -f "document-templates/$f" "$STAGE/document-templates/"
    echo "   테마: $f"
  fi
done
# 콘텐츠 템플릿 (tpl-*.md) — 템플릿 자동화용
for f in document-templates/tpl-*.md; do
  [ -f "$f" ] && cp -f "$f" "$STAGE/document-templates/" && echo "   콘텐츠 템플릿: $(basename "$f")"
done

# ── wheel (에어갭 오프라인 설치용) — python-docx + 순수파이썬 의존성 ─────
#   lxml 은 기존 번들에 이미 있다는 전제(원 번들 의존성). 없으면 아래에 추가 반입.
need_wheel() {
  local pat="$1" src
  src="$(ls openwebui-packages/${pat} 2>/dev/null | head -1 || true)"
  if [ -n "$src" ]; then cp -f "$src" "$STAGE/wheels/"; echo "   wheel: $(basename "$src")";
  else warn "wheel 없음: $pat — 네트워크 있는 곳에서 openwebui-packages/ 에 먼저 받아두세요"; fi
}
need_wheel "python_docx-*.whl"
need_wheel "typing_extensions-*.whl"
# fill_template.py가 frontmatter 사용 (없어도 폴백 동작하지만 권장)
need_wheel "python_frontmatter-*.whl"
# PyYAML — Python 3.11/3.12 양쪽 wheel 모두 포함
for yw in openwebui-packages/pyyaml-*.whl; do
  [ -f "$yw" ] && cp -f "$yw" "$STAGE/wheels/" && echo "   wheel: $(basename "$yw")"
done
[ -n "$(ls "$STAGE/wheels/"python_docx-*.whl 2>/dev/null || true)" ] || die "python-docx wheel 이 없어 키트를 만들 수 없습니다."

# ── README ───────────────────────────────────────────────────────────────
cat > "$STAGE/README.txt" <<EOF
문서 생성 add-on 키트 ($VER)

에어갭 장비 적용:
  1) 이 폴더를 대상 장비로 반입 후 압축 해제
  2) 설치된 번들 루트를 인자로 apply 실행:
       ./apply-docgen.sh /path/to/openwebui
  3) 안내대로 Open WebUI → Workspace → Tools 에 등록

포함:
  - 문서 생성 Tool (docx/pptx/xlsx)
  - 시각 테마 (default + corporate)
  - 콘텐츠 템플릿 (분기보고서/기술제안서/브리핑)
  - 템플릿 자동화 스크립트 (fill_template.py)
  - python-docx wheel, 적용 스크립트

템플릿 자동화 (0.1.7 신규, 오프라인 전용 — mock 데이터만 사용):
  .venv/bin/python fill_template.py tpl-report-quarterly.md --topic "주제"
  .venv/bin/python fill_template.py --list   # 사용 가능한 템플릿 목록

pptx/openpyxl 은 기존 번들에 이미 설치돼 있다는 전제입니다.
EOF

# ── 아카이브 + 체크섬 ────────────────────────────────────────────────────
COPYFILE_DISABLE=1 tar -czf "$OUT" -C dist "$NAME"
rm -rf "$STAGE"
( cd dist && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )

log "완료: $OUT ($(du -h "$OUT" | cut -f1))"
echo "   체크섬: ${OUT}.sha256"
echo ""
tar -tzf "$OUT" | sed "s,^${NAME}/,   ,"

# ── (옵션) Gitea Release 업로드 — 재배포 ─────────────────────────────────
if [ "${1:-}" = "--publish" ]; then
  TAG="${2:-docgen-v$VER}"
  log "Gitea Release 업로드: $TAG"

  [ -f "$HERE/.gitea.conf" ] && { set -a; . "$HERE/.gitea.conf"; set +a; }
  HOST="${GITEA_HOST:-}"; REPO="${GITEA_REPO:-}"; API="${GITEA_API:-https://${HOST}/api/v1}"
  [ -n "$HOST" ] && [ -n "$REPO" ] || die "배포 대상 미설정 — .gitea.conf 확인"
  CRED="${GITEA_CRED_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/gitea/hosts/${HOST}.env}"
  if [ -z "${GITEA_TOKEN:-}" ] && [ -f "$CRED" ]; then set -a; . "$CRED"; set +a; fi
  TOKEN="${GITEA_TOKEN:-}"
  [ -n "$TOKEN" ] || die "토큰 없음 — $CRED 에 GITEA_TOKEN 을 두거나 GITEA_TOKEN=... 로 주입"

  REL_ID="$(curl -sf "$API/repos/$REPO/releases/tags/$TAG" -H "Authorization: token $TOKEN" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if [ -z "$REL_ID" ]; then
    BODY="Open WebUI 문서 생성 add-on 키트 ($VER). 에어갭 적용: 압축 해제 후 ./apply-docgen.sh <번들루트>."
    REL_ID="$(curl -s -X POST "$API/repos/$REPO/releases" \
      -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
      -d "$(python3 -c "import json;print(json.dumps({'tag_name':'$TAG','target_commitish':'main','name':'$TAG — 문서 생성 add-on','body':'''$BODY''','draft':False,'prerelease':False}))")" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')"
    [ -n "$REL_ID" ] || die "릴리스 생성 실패"
  fi

  upload() {
    local f="$1" name; name="$(basename "$f")"
    curl -s "$API/repos/$REPO/releases/$REL_ID/assets" -H "Authorization: token $TOKEN" \
      | python3 -c "import sys,json
for a in json.load(sys.stdin):
    if a['name']=='$name': print(a['id'])" \
      | while read -r id; do
          curl -s -X DELETE "$API/repos/$REPO/releases/$REL_ID/assets/$id" -H "Authorization: token $TOKEN" -o /dev/null
        done
    local code; code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      "$API/repos/$REPO/releases/$REL_ID/assets?name=$name" \
      -H "Authorization: token $TOKEN" -F "attachment=@$f")"
    [ "$code" = "201" ] && echo "   업로드 OK: $name" || die "업로드 실패 (HTTP $code): $name"
  }
  upload "$OUT"
  upload "${OUT}.sha256"
  echo "   https://${HOST}/${REPO}/releases/tag/${TAG}"
fi
