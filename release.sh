#!/usr/bin/env bash
# 배포 스크립트 — package.sh로 만든 번들을 Gitea Release에 업로드한다.
#
# Cloudflare 프록시(git.example.com)는 업로드 본문을 100MB로 제한하므로,
# origin 직결 엔드포인트(git-origin.example.com)를 사용한다. 정식 인증서 적용됨.
#
# 설정 규칙 (배포 대상과 시크릿을 분리한다):
#
#   1) 배포 대상 — 저장소 안 `.gitea.conf` (시크릿 아님, 커밋됨)
#        GITEA_HOST / GITEA_REPO / GITEA_API
#
#   2) 자격증명 — 저장소 밖 `~/.config/gitea/hosts/<GITEA_HOST>.env` (chmod 600)
#        GITEA_TOKEN=...
#      호스트별로 분리해 여러 Gitea 서버/프로젝트에서 재사용한다.
#
#   3) 우선순위: 환경변수 > 자격증명 파일 > .gitea.conf
#      (CI에서는 GITEA_TOKEN 환경변수로 주입)
#
# 사용법:
#   ./release.sh                  # dist/의 최신 번들을 업로드
#   ./release.sh v0.10.2          # 태그 지정
#   GITEA_TOKEN=xxxx ./release.sh # 환경변수로 1회성 주입
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

log() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. 배포 대상 (저장소 안, 시크릿 아님) ────────────────────────────────
CONF="$HERE/.gitea.conf"
if [ -f "$CONF" ]; then
  set -a; . "$CONF"; set +a
fi
HOST="${GITEA_HOST:-}"
REPO="${GITEA_REPO:-}"
API="${GITEA_API:-https://${HOST}/api/v1}"
[ -n "$HOST" ] && [ -n "$REPO" ] || die "배포 대상 미설정 — .gitea.conf 에 GITEA_HOST / GITEA_REPO 를 지정하세요."

# ── 2. 자격증명 (저장소 밖, 호스트별) ────────────────────────────────────
CRED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gitea/hosts"
CRED="${GITEA_CRED_FILE:-$CRED_DIR/${HOST}.env}"
if [ -z "${GITEA_TOKEN:-}" ] && [ -f "$CRED" ]; then
  PERM="$(stat -f '%OLp' "$CRED" 2>/dev/null || stat -c '%a' "$CRED" 2>/dev/null || echo '?')"
  [ "$PERM" = "600" ] || die "$CRED 권한이 $PERM 입니다 (600이어야 함) — chmod 600 '$CRED'"
  set -a; . "$CRED"; set +a
fi
TOKEN="${GITEA_TOKEN:-}"

[ -n "$TOKEN" ] || die "토큰 없음 (호스트: $HOST)

  자격증명 파일을 만드세요 — 저장소 바깥이라 커밋될 위험이 없습니다:

     mkdir -p '$CRED_DIR'
     printf 'GITEA_TOKEN=%s\n' '<발급받은 토큰>' > '$CRED'
     chmod 600 '$CRED'

  토큰 발급: https://${HOST}/user/settings/applications  (scope: write:repository)

  또는 1회성으로:  GITEA_TOKEN=xxxx ./release.sh"

# ── 번들 찾기 ────────────────────────────────────────────────────────────
TAR="$(ls -t dist/openwebui-wiki-bundle-*.tar.gz 2>/dev/null | head -1 || true)"
[ -n "$TAR" ] || die "dist/에 번들이 없습니다. 먼저 ./package.sh 를 실행하세요."
SUM="${TAR}.sha256"
[ -f "$SUM" ] || die "체크섬 파일 없음: $SUM"

BASE="$(basename "$TAR")"
VER="$(sed -E 's/.*bundle-([0-9.]+)-.*/\1/' <<<"$BASE")"
TAG="${1:-v$VER}"

log "번들: $BASE ($(du -h "$TAR" | cut -f1))"
log "태그: $TAG → $REPO"

# ── 무결성 확인 ──────────────────────────────────────────────────────────
log "체크섬 검증"
( cd dist && shasum -a 256 -c "$(basename "$SUM")" ) | sed 's/^/  /'

# ── 릴리스 생성(있으면 재사용) ───────────────────────────────────────────
log "릴리스 확인/생성"
REL_ID="$(curl -sf "$API/repos/$REPO/releases/tags/$TAG" -H "Authorization: token $TOKEN" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"

if [ -z "$REL_ID" ]; then
  BODY="완전 오프라인(에어갭) 설치용 번들.\n\n## 설치\n\`\`\`bash\nshasum -a 256 -c ${BASE}.sha256\ntar -xzf ${BASE}\ncd ${BASE%.tar.gz}\n./install.sh\n\`\`\`\n\n사전 요구사항: macOS arm64, uv, Python 3.11/3.12 (대상 장비에 미리 준비)\n자세한 내용은 INSTALL.md 참조."
  REL_ID="$(curl -s -X POST "$API/repos/$REPO/releases" \
    -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json,sys
print(json.dumps({
  'tag_name': '$TAG', 'target_commitish': 'main',
  'name': '$TAG — 오프라인 번들 (macOS arm64)',
  'body': '''$(printf '%b' "$BODY")''',
  'draft': False, 'prerelease': False,
}))")" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')"
  [ -n "$REL_ID" ] || die "릴리스 생성 실패"
  echo "  생성됨 (id=$REL_ID)"
else
  echo "  기존 릴리스 재사용 (id=$REL_ID)"
fi

# ── 자산 업로드 (동명 자산은 교체) ───────────────────────────────────────
upload() {
  local f="$1" name; name="$(basename "$f")"
  # 기존 동명 자산 제거
  curl -s "$API/repos/$REPO/releases/$REL_ID/assets" -H "Authorization: token $TOKEN" \
    | python3 -c "
import sys,json
for a in json.load(sys.stdin):
    if a['name']=='$name': print(a['id'])
" | while read -r id; do
      curl -s -X DELETE "$API/repos/$REPO/releases/$REL_ID/assets/$id" \
        -H "Authorization: token $TOKEN" -o /dev/null
    done
  log "업로드: $name ($(du -h "$f" | cut -f1))"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$API/repos/$REPO/releases/$REL_ID/assets?name=$name" \
    -H "Authorization: token $TOKEN" -F "attachment=@$f")"
  [ "$code" = "201" ] && echo "  OK (HTTP $code)" || die "업로드 실패 (HTTP $code)"
}

upload "$TAR"
upload "$SUM"

printf '\n\033[1;32m✓ 배포 완료\033[0m\n'
echo "  https://git.example.com/${REPO}/releases/tag/${TAG}"
