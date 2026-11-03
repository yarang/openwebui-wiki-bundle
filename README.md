# Open WebUI + Wiki MCP — 오프라인(에어갭) 번들

인터넷이 차단된 macOS(arm64) 환경에서 **Open WebUI**와 **wiki-mcp**(원문을 LLM으로
위키 노트화하는 MCP 서버)를 **완전 오프라인으로** 설치·운영하기 위한 번들 소스입니다.

## 무엇을 하는가

```text
raw/ 에 원문 투입          →  LLM 변환  →  wiki/ 원자 노트  →  검색·활용
(txt/md/PDF/docx/xlsx/         (추출·청킹·         ([[id]] 링크 그래프)     (MCP 15개 도구)
 pptx/html/이미지)              OCR)
```

- **오프라인 설치** — 로컬 wheel 저장소만으로 설치(네트워크 완전 차단)
- **raw → wiki 자동 변환** — 원문을 넣으면 LLM이 원자 노트로 생성, 상호 링크까지
- **긴 문서 청킹** — 아웃라인 → 노트별 작성으로 1문서 → 다중 노트
- **문서 추출 + OCR** — PDF/Word/Excel/PPT/HTML, 스캔 PDF·이미지는 Apple Vision OCR (오프라인)
- **노트 양식(템플릿)** — `wiki/.templates/*.md` 로 frontmatter·섹션 구조 지정

## 설치용 오프라인 번들 내려받기

설치에 필요한 **wheel 저장소(~834MB)를 포함한 완성 번들**은
[**Releases**](../../releases) 에서 받습니다. (저장소에는 소스만 있습니다 — 아래 참조)

```bash
# Releases에서 tar.gz + .sha256 다운로드 후
shasum -a 256 -c openwebui-wiki-bundle-<버전>-macos-arm64.tar.gz.sha256
tar -xzf openwebui-wiki-bundle-<버전>-macos-arm64.tar.gz
cd openwebui-wiki-bundle-<버전>-macos-arm64
./install.sh
```

## 빠른 시작

```bash
./install.sh              # 오프라인 설치 (uv + 로컬 wheel)
open-webui serve          # http://localhost:8080
./run-wiki-mcp.sh watch   # raw/ 감시 → 자동 위키화
```

## 문서

| 문서 | 내용 |
| --- | --- |
| [`INSTALL.md`](INSTALL.md) | **설치·설정** — 오프라인 설치, 도구 15개, 템플릿, raw 변환, 청킹, 문서추출, OCR |
| [`docs/USAGE.md`](docs/USAGE.md) | **실사용 매뉴얼** — 설치 후 장치별 연동·검증·사용 (Open WebUI 연결) |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | **상시 운영** — 서비스 기동, launchd 자동 시작, 헬스체크, 백업 |
| [`docs/TESTING.md`](docs/TESTING.md) | **테스트 전략** — 대상·우선순위·실행 |
| [`docs/KNOWLEDGE-BASE.md`](docs/KNOWLEDGE-BASE.md) | **지식 구축** — 원자 노트 원칙, 투입 전략, 품질 튜닝, 유지보수 |
| [`docs/LM-STUDIO.md`](docs/LM-STUDIO.md) | **LM Studio 연동** — 채팅·Knowledge 임베딩·Wiki MCP 공동 사용, 에어갭 설정 |

설치 후 처음 할 일은 [`docs/USAGE.md`](docs/USAGE.md)의 연동 체크리스트입니다.

## 사전 요구사항 (대상 장비에 미리 준비)

| 항목 | 비고 |
| --- | --- |
| macOS (Apple Silicon / arm64) | 번들 wheel이 arm64 전용 |
| `uv` 0.5+ | 에어갭이면 바이너리 미리 반입 |
| Python 3.11 또는 3.12 | uv가 오프라인에서 내려받을 수 없으므로 사전 설치 |
| `openwebui-packages/` | **오프라인 wheel 저장소(~834MB)** — 이 저장소에는 없음(아래 참조) |

## 저장소 구성 (소스만 보관)

```text
INSTALL.md            # 전체 매뉴얼 (단일 기준)
install.sh            # 원커맨드 오프라인 설치
package.sh            # 배포용 번들(tar.gz) 생성
run-wiki-mcp.sh       # wiki-mcp 실행기 (serve | mcpo | watch)
wiki-mcp/src/         # wiki-mcp 소스 (editable 설치 대상)
wiki/                 # 위키 노트 + .templates/ (양식)
raw/                  # 원문 투입 디렉토리
ocr/vision_ocr.swift  # Apple Vision OCR 헬퍼 (package.sh가 컴파일)
.env.example          # 환경 변수 예시 (cp .env.example .env)
run-openwebui.sh      # Open WebUI 실행기 (.env 자동 로드)
load-env.sh           # .env 로더 (공용)
```

> **`openwebui-packages/`(wheel ~834MB)와 배포 tar.gz는 저장소에 포함하지 않습니다.**
> 대용량 바이너리는 git에 부적합하므로 **릴리스 아티팩트로 배포**합니다.

## 배포 (관리자)

```bash
./package.sh     # 번들(tar.gz + 체크섬) 생성 → dist/
./release.sh     # Gitea Release에 업로드
```

### 설정 규칙 — 배포 대상과 시크릿의 분리

| | 파일 | 위치 | 커밋 | 내용 |
| --- | --- | --- | --- | --- |
| **배포 대상** | `.gitea.conf` | 저장소 안 | ✅ | `GITEA_HOST` / `GITEA_REPO` / `GITEA_API` |
| **자격증명** | `~/.config/gitea/hosts/<호스트>.env` | **저장소 밖** | ❌ | `GITEA_TOKEN` 만 |

**시크릿을 저장소 밖에 두는 이유**: `.gitignore`는 패턴 오타·`git add -f`·파일명 변경에
취약합니다. 저장소 바깥에 두면 실수로 커밋되는 사고 자체가 성립하지 않습니다.

**호스트별로 나누는 이유**: 여러 Gitea 서버·프로젝트에서 같은 자격증명을 재사용하고,
저장소를 클론한 사람은 `.gitea.conf`로 배포 대상만 파악한 뒤 **자기 토큰**을 넣으면 됩니다.

최초 1회 설정:

```bash
mkdir -p ~/.config/gitea/hosts
printf 'GITEA_TOKEN=%s\n' '<발급받은 토큰>' > ~/.config/gitea/hosts/git.example.com.env
chmod 600 ~/.config/gitea/hosts/git.example.com.env
```
토큰 발급: `https://<호스트>/user/settings/applications` (scope: `write:repository`)

**로드 우선순위**: 환경변수 `GITEA_TOKEN` > 자격증명 파일 > `.gitea.conf`
(CI에서는 환경변수로 주입)

**안전장치**: 자격증명 파일 권한이 `600`이 아니면 **실행을 거부**합니다.

### 업로드 엔드포인트 주의

`.gitea.conf`의 `GITEA_API`는 **origin 직결(`git-origin.example.com`)** 을 가리킵니다.
`git.example.com`는 Cloudflare 프록시라 **업로드 본문이 100MB로 제한**되어
대용량 번들(800MB+)을 올릴 수 없습니다(HTTP 413). 다운로드는 어느 쪽이든 정상입니다.

번들은 **경로에 종속되지 않습니다** — 어느 위치에 풀어도 스크립트가 자기 위치를 기준으로 동작합니다.
