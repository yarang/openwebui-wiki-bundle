#!/usr/bin/env bash
# .env 로더 — 번들 루트의 .env를 읽어 환경변수로 export한다.
# run-wiki-mcp.sh / run-openwebui.sh 가 공용으로 source 한다.
#
# 규칙:
#   1) 우선순위: 셸 환경변수 > .env > 스크립트 기본값
#      이미 설정된 변수는 덮어쓰지 않는다 → 일회성 오버라이드가 가능하다.
#         WIKI_INGEST_MODEL=other ./run-wiki-mcp.sh watch
#   2) 주석은 줄 맨 앞의 '#'. 값 뒤의 인라인 주석(' #...')도 제거한다.
#   3) 값의 앞뒤 따옴표는 벗긴다.
#
# 사용:
#   . "$HERE/load-env.sh"
#   load_env "$HERE/.env"

load_env() {
  local file="${1:-}" line key val
  [ -n "$file" ] && [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                       # CRLF 방어
    case "$line" in ''|'#'*) continue ;; esac  # 빈 줄 / 주석 줄
    case "$line" in *=*) ;; *) continue ;; esac

    key="${line%%=*}"
    val="${line#*=}"
    key="${key//[[:space:]]/}"
    [ -n "$key" ] || continue

    val="${val%%[[:space:]]#*}"                        # 인라인 주석 제거
    val="${val#"${val%%[![:space:]]*}"}"               # 앞 공백
    val="${val%"${val##*[![:space:]]}"}"               # 뒤 공백
    case "$val" in                                     # 따옴표 제거
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac

    # 셸 환경변수가 우선 — 이미 설정돼 있으면 건드리지 않는다
    if [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$file"
}
