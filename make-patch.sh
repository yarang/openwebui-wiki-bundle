#!/usr/bin/env bash
# wiki-mcp 패치 아티팩트 생성기 — 개발/빌드 측에서 실행한다.
#
# wheel(openwebui-packages) 없이 "코드 + 실행 스크립트"만 뽑아 작은 패치를 만든다.
# 산출물: dist/wiki-mcp-patch-<ver>.tar.gz (+ .sha256)
#   구조: payload/<패치 대상 트리> + PATCH_MANIFEST.json (파일별 sha256)
#
# 사용법:
#   ./make-patch.sh                 # dist/ 에 패치 생성
#   ./make-patch.sh --publish       # 생성 후 Gitea Release 에 업로드
#   ./make-patch.sh --publish v0.2.0 # 태그 지정 업로드
#
# 버전 기준: wiki-mcp/pyproject.toml 의 version.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 패치 대상 집합 (wheel 은 절대 포함하지 않는다) ───────────────────────
#   apply-patch.sh 도 payload 에 넣어 향후 패치가 적용기 자신을 갱신할 수 있게 한다.
PATCH_PATHS=(
  "wiki-mcp"
  "run-wiki-mcp.sh"
  "run-openwebui.sh"
  "load-env.sh"
  "wiki/.templates"
  "apply-patch.sh"
)

# ── 버전 ─────────────────────────────────────────────────────────────────
VER="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' wiki-mcp/pyproject.toml | head -1)"
[ -n "$VER" ] || die "wiki-mcp/pyproject.toml 에서 version 을 찾지 못했습니다."

NAME="wiki-mcp-patch-${VER}"
STAGE="dist/${NAME}"
OUT="dist/${NAME}.tar.gz"

log "패치 버전: $VER"

# ── 스테이징 (payload/ 아래로 대상만 복사) ───────────────────────────────
rm -rf "$STAGE" "$OUT" "${OUT}.sha256"
mkdir -p "$STAGE/payload"

for p in "${PATCH_PATHS[@]}"; do
  [ -e "$p" ] || { warn "대상 없음 — 건너뜀: $p"; continue; }
  mkdir -p "$STAGE/payload/$(dirname "$p")"
  # 런타임/캐시/개발 부산물 제외 (package.sh 규칙과 동일 철학)
  rsync -a \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='*.bak' \
    --exclude='*.bak.*' \
    --exclude='*.egg-info/' \
    --exclude='.DS_Store' \
    --exclude='.pytest_cache/' \
    --exclude='.coverage' \
    --exclude='.gitignore' \
    --exclude='htmlcov/' \
    --exclude='wiki-mcp/data/' \
    --exclude='wiki-mcp/.claude/' \
    --exclude='wiki-mcp/launchd/' \
    "$p" "$STAGE/payload/$(dirname "$p")/"
done

# ── 매니페스트 생성 (payload 내부 모든 파일의 sha256) ────────────────────
log "매니페스트 생성 (파일별 sha256)"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(
  cd "$STAGE/payload"
  # 상대경로 목록 → sha256
  find . -type f | sort | while read -r f; do
    rel="${f#./}"
    sum="$(shasum -a 256 "$f" | awk '{print $1}')"
    printf '%s\t%s\n' "$sum" "$rel"
  done
) > "$STAGE/.filelist"

python3 - "$STAGE/.filelist" "$VER" "$CREATED_AT" > "$STAGE/PATCH_MANIFEST.json" <<'PYEOF'
import json, sys
filelist, ver, created = sys.argv[1], sys.argv[2], sys.argv[3]
files = []
with open(filelist, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        sha, path = line.split("\t", 1)
        files.append({"path": path, "sha256": sha})
print(json.dumps({
    "component": "wiki-mcp",
    "patch_version": ver,
    "created_at": created,
    "payload_root": "payload",
    "file_count": len(files),
    "files": files,
}, ensure_ascii=False, indent=2))
PYEOF
rm -f "$STAGE/.filelist"

# ── 아카이브 + 체크섬 ────────────────────────────────────────────────────
COPYFILE_DISABLE=1 tar -czf "$OUT" -C dist "$NAME"
rm -rf "$STAGE"
( cd dist && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )

SIZE="$(du -h "$OUT" | cut -f1)"
FCOUNT="$(tar -tzf "$OUT" | grep -c '/payload/.*[^/]$' || true)"
log "완료: $OUT ($SIZE, 파일 ${FCOUNT}개)"
echo "   체크섬: ${OUT}.sha256"

# ── (옵션) Gitea Release 업로드 ──────────────────────────────────────────
if [ "${1:-}" = "--publish" ]; then
  TAG="${2:-v$VER}"
  log "Gitea Release 업로드: $TAG"

  # 배포 대상 (.gitea.conf) + 자격증명 (저장소 밖) — release.sh 와 동일 규칙
  [ -f "$HERE/.gitea.conf" ] && { set -a; . "$HERE/.gitea.conf"; set +a; }
  HOST="${GITEA_HOST:-}"; REPO="${GITEA_REPO:-}"; API="${GITEA_API:-https://${HOST}/api/v1}"
  [ -n "$HOST" ] && [ -n "$REPO" ] || die "배포 대상 미설정 — .gitea.conf 확인"
  CRED="${GITEA_CRED_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/gitea/hosts/${HOST}.env}"
  if [ -z "${GITEA_TOKEN:-}" ] && [ -f "$CRED" ]; then set -a; . "$CRED"; set +a; fi
  TOKEN="${GITEA_TOKEN:-}"
  [ -n "$TOKEN" ] || die "토큰 없음 — $CRED 에 GITEA_TOKEN 을 두거나 GITEA_TOKEN=... 로 주입"

  # 릴리스 확인/생성
  REL_ID="$(curl -sf "$API/repos/$REPO/releases/tags/$TAG" -H "Authorization: token $TOKEN" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if [ -z "$REL_ID" ]; then
    REL_ID="$(curl -s -X POST "$API/repos/$REPO/releases" \
      -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
      -d "$(python3 -c "import json;print(json.dumps({'tag_name':'$TAG','target_commitish':'main','name':'$TAG — wiki-mcp 패치','body':'wiki-mcp $VER 코드+실행 스크립트 패치. apply-patch.sh 로 적용.','draft':False,'prerelease':False}))")" \
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
