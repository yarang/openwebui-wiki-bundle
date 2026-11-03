#!/usr/bin/env bash
# 설치용 오프라인 번들 패키징 — macOS arm64.
# 산출물: dist/openwebui-wiki-bundle-<ver>-macos-arm64.tar.gz (+ .sha256)
#
# 포함: openwebui-packages, wiki-mcp(소스), wiki(+templates), raw(README),
#       run-wiki-mcp.sh, run-openwebui.sh, .env.example, INSTALL.md
# 제외: .venv, wiki-data, 캐시/부산물, 비밀키, 머신 고유 파일
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# 버전: 설치된 open-webui 기준(없으면 0.12.3)
VER="$(.venv/bin/python -c 'from importlib.metadata import version; print(version("open-webui"))' 2>/dev/null || echo 0.12.3)"
NAME="openwebui-wiki-bundle-${VER}-macos-arm64"
STAGE="dist/${NAME}"
OUT="dist/${NAME}.tar.gz"

echo "▶ 패키징: ${NAME}"

# wheel 저장소 확인 (git에는 없음 — 릴리스 아티팩트/별도 반입)
if [ ! -d "$HERE/openwebui-packages" ]; then
  echo "✗ openwebui-packages/ 없음 — 오프라인 wheel 저장소가 있어야 패키징할 수 있습니다." >&2
  exit 1
fi

# OCR 헬퍼: 바이너리가 없으면 소스에서 빌드 (git에는 소스만 저장됨)
if [ ! -x "$HERE/ocr/vision-ocr" ] && [ -z "${SKIP_OCR:-}" ]; then
  if command -v swiftc >/dev/null 2>&1; then
    echo "▶ OCR 헬퍼 빌드: vision_ocr.swift → vision-ocr"
    swiftc -O -o "$HERE/ocr/vision-ocr" "$HERE/ocr/vision_ocr.swift"
  else
    echo "✗ swiftc 없음 — OCR 바이너리를 빌드할 수 없습니다." >&2
    echo "   Xcode Command Line Tools 설치 후 재시도하거나, SKIP_OCR=1 로 OCR 없이 패키징하세요." >&2
    exit 1
  fi
fi

rm -rf "$STAGE" "$OUT" "${OUT}.sha256"
mkdir -p "$STAGE"

# 스테이징 복사 (제외 규칙 적용)
rsync -a \
  --exclude='.venv/' \
  --exclude='wiki-data/' \
  --exclude='dist/' \
  --exclude='.git/' \
  --exclude='.claude/' \
  --exclude='.DS_Store' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.bak' \
  --exclude='*.bak.*' \
  --exclude='.webui_secret_key' \
  --exclude='.env' \
  --exclude='.gitea.env' \
  --exclude='wiki-mcp/data/' \
  --exclude='wiki-mcp/.claude/' \
  --exclude='wiki-mcp/launchd/' \
  --exclude='*.egg-info/' \
  --exclude='raw/.processed/' \
  --exclude='raw/.failed/' \
  --exclude='backups/' \
  --exclude='filled-output/' \
  --exclude='test-output/' \
  ./ "$STAGE/"

# 아카이브 생성 (macOS 확장속성 제외)
COPYFILE_DISABLE=1 tar -czf "$OUT" -C dist "$NAME"
rm -rf "$STAGE"

# 체크섬
( cd dist && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )

SIZE="$(du -h "$OUT" | cut -f1)"
echo "✅ 완료: $OUT ($SIZE)"
echo "   체크섬: ${OUT}.sha256"
echo ""
echo "▶ 검증 (아카이브 최상위):"
tar -tzf "$OUT" | sed "s,^${NAME}/,,;s,/.*,/," | sort -u | sed '/^$/d;s,^,   ,'
