#!/usr/bin/env bash
# wiki-mcp 패치 적용기 — 설치된 번들(에어갭 포함)에서 실행한다.
#
# 동작: 무결성 검증 → 자동 백업 → 디렉토리 통째 교체 → editable 재설치(best-effort)
#       → 임포트 검증. 실패/원복은 --rollback 으로 마지막 백업 복원.
#
# 사용법:
#   ./apply-patch.sh <patch.tar.gz>       # 오프라인 패치 파일 적용
#   ./apply-patch.sh --from-gitea [tag]   # Gitea Release 에서 받아 적용 (네트워크 필요)
#   ./apply-patch.sh --rollback           # 마지막 백업으로 원복
#   ./apply-patch.sh --list-backups       # 백업 목록
#   옵션: --force (동일/하위 버전도 강제), --no-reinstall (editable 재설치 생략),
#         --dry-run (검증/계획만, 파일 미변경)
set -euo pipefail

OW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$OW"
PY="$OW/.venv/bin/python"
PKGS="$OW/openwebui-packages"
BACKUP_DIR="$OW/backups"

log()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 패치가 건드리는 경로 (백업 스냅샷 대상 = payload 최상위와 일치) ─────────
PATCH_PATHS=(
  "wiki-mcp"
  "run-wiki-mcp.sh"
  "run-openwebui.sh"
  "load-env.sh"
  "wiki/.templates"
  "apply-patch.sh"
)

FORCE=0; NO_REINSTALL=0; DRY_RUN=0
MODE=""; ARG=""

# ── 인자 파싱 ────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --force)         FORCE=1 ;;
    --no-reinstall)  NO_REINSTALL=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    --rollback)      MODE="rollback" ;;
    --list-backups)  MODE="list" ;;
    --from-gitea)    MODE="gitea"; ARG="${2:-}"; [ -n "${2:-}" ] && shift ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    -*)              die "알 수 없는 옵션: $1" ;;
    *)               MODE="${MODE:-file}"; ARG="$1" ;;
  esac
  shift
done

# 설치 위치 정합성 (에어갭 오설치 방지)
[ -x "$PY" ] || die ".venv 파이썬 없음: $PY — 설치 루트에서 실행하세요 (install.sh 완료 후)."

# ── 현재 배포된 wiki-mcp 버전 (디스크 소스가 기준) ───────────────────────
current_version() {
  sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$OW/wiki-mcp/pyproject.toml" 2>/dev/null | head -1
}

# semver 비교: $1 <= $2 이면 0 (true)
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

# ── editable 재설치 (오프라인 우선, PKGS 있으면 활용) ────────────────────
reinstall_editable() {
  [ "$NO_REINSTALL" = 1 ] && { echo "   (--no-reinstall) 재설치 생략"; return 0; }
  local cmd=(uv pip install --python "$PY" --offline --no-index --no-build-isolation)
  [ -d "$PKGS" ] && cmd+=(--find-links="$PKGS")
  "${cmd[@]}" -e "$OW/wiki-mcp"
}

# ── 임포트/버전 검증 (부작용 없이) ───────────────────────────────────────
verify_import() {
  EMBEDDING_DISABLED=1 "$PY" - <<'PYEOF'
from importlib.metadata import version
import wiki_mcp  # editable 경로 확인 (server 미임포트 → 인덱싱 안 함)
print("   wiki-mcp:", version("wiki-mcp"))
print("   editable:", wiki_mcp.__file__)
PYEOF
}

# ── 실행 중 프로세스 안내 (자동 종료하지 않음 — 안전) ────────────────────
restart_hint() {
  local running
  # 실제 실행 바이너리 경로로 좁혀 오탐 방지 (명령줄에 문자열만 있는 무관 프로세스 제외)
  running="$(pgrep -fl 'bin/wiki-mcp' 2>/dev/null | grep -v apply-patch || true)"
  if [ -n "$running" ]; then
    warn "실행 중인 wiki-mcp 프로세스가 있습니다. 새 코드 반영을 위해 재시작하세요:"
    printf '%s\n' "$running" | sed 's,^,     ,'
    echo "     예) 재시작 후 ./run-wiki-mcp.sh {serve|mcpo|watch}"
  else
    echo "   실행 중 프로세스 없음 — 다음 실행부터 새 코드가 적용됩니다."
  fi
}

# ── 백업 목록 ────────────────────────────────────────────────────────────
if [ "$MODE" = "list" ]; then
  log "백업 목록: $BACKUP_DIR"
  ls -1t "$BACKUP_DIR"/patch-backup-*.tar.gz 2>/dev/null | sed 's,^,   ,' || echo "   (없음)"
  exit 0
fi

# ── 롤백 ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "rollback" ]; then
  LATEST="$(ls -1t "$BACKUP_DIR"/patch-backup-*.tar.gz 2>/dev/null | head -1 || true)"
  [ -n "$LATEST" ] || die "복원할 백업이 없습니다: $BACKUP_DIR"
  log "롤백: $(basename "$LATEST")"
  [ "$DRY_RUN" = 1 ] && { echo "   (dry-run) 위 백업을 $OW 에 풀어 복원합니다."; exit 0; }
  tar -xzf "$LATEST" -C "$OW"
  log "editable 재설치"
  reinstall_editable || warn "재설치 실패 — 코드는 원복됨(.pth 소스 참조). 수동 확인 권장."
  verify_import || warn "임포트 검증 실패 — 로그 확인 필요."
  printf '\n\033[1;32m✓ 롤백 완료 (버전 %s)\033[0m\n' "$(current_version)"
  restart_hint
  exit 0
fi

# ── Gitea 에서 패치 내려받기 ─────────────────────────────────────────────
fetch_from_gitea() {
  local tag="$1"
  [ -f "$OW/.gitea.conf" ] && { set -a; . "$OW/.gitea.conf"; set +a; }
  local host="${GITEA_HOST:-}" repo="${GITEA_REPO:-}" api="${GITEA_API:-https://${GITEA_HOST:-}/api/v1}"
  [ -n "$host" ] && [ -n "$repo" ] || die "배포 대상 미설정 — .gitea.conf 확인 (에어갭이면 오프라인 파일을 쓰세요)."
  local cred="${GITEA_CRED_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/gitea/hosts/${host}.env}"
  if [ -z "${GITEA_TOKEN:-}" ] && [ -f "$cred" ]; then set -a; . "$cred"; set +a; fi
  local token="${GITEA_TOKEN:-}"
  local auth=(); [ -n "$token" ] && auth=(-H "Authorization: token $token")

  local ep
  if [ -n "$tag" ]; then ep="$api/repos/$repo/releases/tags/$tag"; else ep="$api/repos/$repo/releases/latest"; fi
  log "Gitea 조회: $ep"
  local json; json="$(curl -sf "${auth[@]}" "$ep")" || die "Gitea 접근 실패 — 네트워크/토큰 확인 (에어갭이면 오프라인 파일 사용)."

  # 자산 URL 추출 (wiki-mcp-patch-*.tar.gz 와 그 .sha256)
  local tmp; tmp="$(mktemp -d)"
  local durl surl
  durl="$(echo "$json" | "$PY" -c "import sys,json,re
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    n=a['name']
    if re.match(r'wiki-mcp-patch-.*\.tar\.gz$',n): print(a['browser_download_url'])" | head -1)"
  surl="$(echo "$json" | "$PY" -c "import sys,json,re
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    n=a['name']
    if re.match(r'wiki-mcp-patch-.*\.tar\.gz\.sha256$',n): print(a['browser_download_url'])" | head -1)"
  [ -n "$durl" ] || die "릴리스에 wiki-mcp-patch 자산이 없습니다."

  local base; base="$(basename "$durl")"
  log "다운로드: $base"
  curl -sfL "${auth[@]}" -o "$tmp/$base" "$durl" || die "패치 다운로드 실패"
  if [ -n "$surl" ]; then
    curl -sfL "${auth[@]}" -o "$tmp/$base.sha256" "$surl" || warn "체크섬 파일 다운로드 실패 — 무결성 검증 생략"
    if [ -f "$tmp/$base.sha256" ]; then
      log "체크섬 검증"
      ( cd "$tmp" && shasum -a 256 -c "$base.sha256" ) | sed 's,^,   ,' || die "체크섬 불일치 — 손상된 패치"
    fi
  fi
  echo "$tmp/$base"
}

# ── 패치 파일 확보 ───────────────────────────────────────────────────────
PATCH_FILE=""
if [ "$MODE" = "gitea" ]; then
  PATCH_FILE="$(fetch_from_gitea "$ARG")"
elif [ "$MODE" = "file" ]; then
  [ -f "$ARG" ] || die "패치 파일 없음: $ARG"
  PATCH_FILE="$ARG"
else
  die "적용할 패치를 지정하세요. 사용법은 ./apply-patch.sh --help"
fi

# ── 전개 + 매니페스트 로드 ───────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log "패치 전개: $(basename "$PATCH_FILE")"
tar -xzf "$PATCH_FILE" -C "$WORK"
# 아카이브 최상위 디렉토리(wiki-mcp-patch-<ver>) 안으로 진입
ROOT="$(find "$WORK" -maxdepth 2 -name PATCH_MANIFEST.json -print -quit)"
[ -n "$ROOT" ] || die "PATCH_MANIFEST.json 이 없습니다 — 유효한 wiki-mcp 패치가 아닙니다."
ROOT="$(dirname "$ROOT")"
PAYLOAD="$ROOT/payload"
[ -d "$PAYLOAD" ] || die "payload/ 디렉토리가 없습니다."

PATCH_VER="$("$PY" -c "import json;print(json.load(open('$ROOT/PATCH_MANIFEST.json'))['patch_version'])")"
CUR_VER="$(current_version)"
log "현재 버전: ${CUR_VER:-unknown}  →  패치 버전: $PATCH_VER"

# ── 버전 가드 (다운그레이드/재적용 방지) ─────────────────────────────────
if [ -n "$CUR_VER" ] && [ "$FORCE" = 0 ]; then
  if ver_le "$PATCH_VER" "$CUR_VER"; then
    die "패치 버전($PATCH_VER) 이 현재($CUR_VER) 보다 높지 않습니다. 강제하려면 --force."
  fi
fi

# ── 무결성 검증 (payload 내 모든 파일 sha256 == 매니페스트) ──────────────
log "무결성 검증 (파일별 sha256)"
"$PY" - "$ROOT/PATCH_MANIFEST.json" "$PAYLOAD" <<'PYEOF'
import json, sys, hashlib, os
manifest, payload = sys.argv[1], sys.argv[2]
m = json.load(open(manifest))
bad = 0
for e in m["files"]:
    fp = os.path.join(payload, e["path"])
    if not os.path.exists(fp):
        print(f"   누락: {e['path']}"); bad += 1; continue
    h = hashlib.sha256(open(fp, "rb").read()).hexdigest()
    if h != e["sha256"]:
        print(f"   변조/손상: {e['path']}"); bad += 1
if bad:
    print(f"   ✗ {bad}개 파일 불일치"); sys.exit(1)
print(f"   ✓ {len(m['files'])}개 파일 검증 통과")
PYEOF

if [ "$DRY_RUN" = 1 ]; then
  log "(dry-run) 적용 계획"
  echo "   교체 대상:"; printf '     %s\n' "${PATCH_PATHS[@]}"
  echo "   백업 위치: $BACKUP_DIR/patch-backup-${CUR_VER:-unknown}-<ts>.tar.gz"
  echo "   재설치: $([ "$NO_REINSTALL" = 1 ] && echo '생략' || echo 'editable -e 재설치')"
  exit 0
fi

# ── 백업 (현재 patchable 집합 스냅샷) ────────────────────────────────────
mkdir -p "$BACKUP_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/patch-backup-${CUR_VER:-unknown}-${TS}.tar.gz"
log "백업: $(basename "$BACKUP")"
EXISTING=(); for p in "${PATCH_PATHS[@]}"; do [ -e "$OW/$p" ] && EXISTING+=("$p"); done
COPYFILE_DISABLE=1 tar -czf "$BACKUP" -C "$OW" "${EXISTING[@]}"

# ── 디렉토리 통째 교체 (런타임 데이터 보호) ──────────────────────────────
log "적용: 디렉토리 교체"
SELF="$OW/apply-patch.sh"          # 실행 중인 자기 자신
SELF_UPDATED=0
for p in "${PATCH_PATHS[@]}"; do
  src="$PAYLOAD/$p"
  [ -e "$src" ] || continue
  if [ -d "$src" ]; then
    mkdir -p "$OW/$p"
    # --delete 로 통째 교체하되, 런타임/로컬 디렉토리는 보호(P)한다.
    rsync -a --delete \
      --filter='P data/' --filter='P .claude/' --filter='P launchd/' \
      --filter='P __pycache__/' \
      "$src/" "$OW/$p/"
  elif [ "$OW/$p" = "$SELF" ]; then
    # 실행 중인 스크립트를 제자리에서 덮어쓰면 bash 가 깨질 수 있다.
    # 내용이 다르면 사이드카(.new)로 빼두고 마지막에 교체를 안내한다.
    if ! cmp -s "$src" "$SELF"; then
      cp -f "$src" "$SELF.new"; chmod +x "$SELF.new"; SELF_UPDATED=1
      echo "   보류: apply-patch.sh (→ apply-patch.sh.new, 실행 중 자기교체 방지)"
    else
      echo "   교체: apply-patch.sh (변화 없음)"
    fi
    continue
  else
    cp -f "$src" "$OW/$p"
    [ -x "$src" ] && chmod +x "$OW/$p" || true
  fi
  echo "   교체: $p"
done

# ── editable 재설치 + 검증 ───────────────────────────────────────────────
log "editable 재설치"
if reinstall_editable; then :; else
  warn "재설치 실패 — 새 코드는 배치됨(.pth 소스 참조로 대부분 동작). 의존성 변경 시 문제일 수 있음."
  warn "원복하려면: ./apply-patch.sh --rollback"
fi

log "검증"
if verify_import; then :; else
  warn "임포트 검증 실패 — 롤백 권장: ./apply-patch.sh --rollback"
  exit 1
fi

printf '\n\033[1;32m✓ 패치 적용 완료: %s → %s\033[0m\n' "${CUR_VER:-unknown}" "$PATCH_VER"
if [ "${SELF_UPDATED:-0}" = 1 ]; then
  warn "apply-patch.sh 자체가 갱신되었습니다. 다음 명령으로 새 버전으로 교체하세요:"
  echo "     mv ./apply-patch.sh.new ./apply-patch.sh"
fi
restart_hint
echo "   문제 시 원복: ./apply-patch.sh --rollback"
