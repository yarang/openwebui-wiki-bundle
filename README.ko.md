# Open WebUI + Wiki MCP + Claude Code — 오프라인(에어갭) 번들

[English](README.md) | 한국어

인터넷이 차단된 Apple Silicon Mac(macOS arm64) 한 대에 로컬 AI 작업 환경을 **완전 오프라인으로**
설치·운영하기 위한 번들 소스입니다.

- **LM Studio** — 모델을 로컬에서 실행 (채팅 Gemma-4-E4B, 임베딩 bge-m3)
- **Open WebUI** — 채팅 화면
- **wiki-mcp** — 원문을 LLM이 서로 연결된 Markdown 위키로 정리하는 MCP 서버 ("LLM-wiki")
- **Claude Code** — `claude-lms` 래퍼로 로컬 모델 위에서 도는 코딩 에이전트

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
- **하이브리드 검색** — BM25 + 임베딩. 한국어 질의 14개에서 1순위 정답은 bge-m3 14개, nomic 3개

## 두 가지 번들

| 번들 | 구성 | 이 저장소만으로 빌드 | 문서 |
| --- | --- | --- | --- |
| openwebui-wiki 번들 (저장소 루트) | Open WebUI + wiki-mcp | 가능 | [`INSTALL.md`](INSTALL.md) |
| 통합 번들 ([`guardian/`](guardian/)) | LM Studio(앱·모델) + Open WebUI + wiki-mcp + Claude Code(`claude-lms`) | 불가 — 기반 번들이 필요(아래) | [`guardian/README.md`](guardian/README.md), [`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md) |

### 저장소에 있는 것과 없는 것

있는 것:

- wiki-mcp 소스, openwebui-wiki 번들의 설치·패키징 스크립트
- `guardian/build-merged-bundle.sh` — 기반 번들에 위키 계층, bge-m3 임베딩 모델, 공식 LM Studio dmg,
  Claude Code 를 더해 통합 번들을 만든다
- `guardian/claude-lms`, `guardian/install-claude-code.sh` (LM Studio 위의 Claude Code)
- 설치 문제 기록([`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md))과 매뉴얼

없는 것:

- 대용량 바이너리 — wheel 저장소(~834MB), 모델, LM Studio dmg
- Claude Code 바이너리 — `build-merged-bundle.sh` 가 빌드 Mac 에 설치된 것(`~/.local/bin/claude`)을
  Anthropic 서명인지 확인한 뒤 복사한다
- **기반 번들 빌더** — server-guardian 의 `build-llm-bundle.sh`(LM Studio 런타임, 채팅 모델, 번들 Python,
  Open WebUI wheel). 아직 공개하지 않은 별도 저장소에 있어서, 통합 번들은 이 저장소만으로 다시 만들 수 없다

## 오프라인 Claude Code (`claude-lms`)

`claude-lms` 는 Claude Code 를 LM Studio 로 연결하므로(`ANTHROPIC_BASE_URL`) Anthropic 계정이나 API 키가
필요 없습니다. 필수가 아닌 통신과 자동 업데이트를 끕니다. Claude Code 의 시스템 프롬프트와 도구 정의만
약 10k 토큰인데, LM Studio 가 JIT 로 모델을 올리면 기본 context(4k~8k)라 프롬프트가 잘립니다. 그래서
래퍼가 모델을 64k context 로 먼저 올립니다.

- 모델은 로컬입니다. 여기서 Claude(Anthropic 의 모델)가 도는 것은 아닙니다. 그냥 `claude` 는 여전히 Anthropic 로그인이 필요합니다.
- 4B 모델은 에이전트 작업에 약합니다. 쓸 도구를 명시하고("calc.py 를 Read 로 읽고 Edit 로 고친 뒤 Bash 로
  실행") 결과를 매번 확인하세요.
- 외부 통신 0건은 설계 목표이며, 완전 차단 상태에서의 검증은 남은 과제입니다.
- 따로 설치하려면 `claude` 바이너리, 그 버전을 적은 `VERSION`, `install-claude-code.sh`, `claude-lms` 를
  한 폴더에 두고 `./install-claude-code.sh` 를 실행합니다(통합 번들은 마지막 단계에서 이를 실행).

## 완성 번들은 직접 만든다

내려받을 완성 번들(Release)은 없습니다. 이 저장소에는 **소스와 빌드 스크립트만** 있고, 대용량 바이너리는
git에 넣지 않습니다. 인터넷이 되는 빌드 Mac에서 번들을 만든 뒤 대상 Mac으로 옮깁니다.

**openwebui-wiki 번들** — `openwebui-packages/`(macOS arm64, cp311·cp312 wheel)를 채운 뒤 `./package.sh`.

```bash
# 빌드 Mac (macOS arm64 · Python 3.12 · OCR 헬퍼용 Xcode Command Line Tools · 인터넷 연결)
# 예시. 보충 wheel 목록은 INSTALL.md 부록 참고 (SKIP_OCR=1 이면 OCR 없이 패키징)
python3.12 -m pip download open-webui==0.12.3 mcpo==0.0.20 ./wiki-mcp -d openwebui-packages
./package.sh                        # → dist/openwebui-wiki-bundle-<버전>-macos-arm64.tar.gz (+ .sha256)
```

**통합 번들** — `build-llm-bundle.sh` 가 만든 기반 번들과 공식 LM Studio dmg 를
`guardian/build-merged-bundle.sh` 로 합칩니다. 자세한 절차는 [`guardian/README.md`](guardian/README.md).

```bash
guardian/build-merged-bundle.sh dist/build/<기반 번들> \
    --lmstudio-dmg=LM-Studio-<버전>-arm64.dmg --name=llm-wiki-bundle-<UTC시각>-macos-arm64
```

만든 openwebui-wiki 번들을 대상 Mac에 옮겨 설치합니다.

```bash
shasum -a 256 -c openwebui-wiki-bundle-<버전>-macos-arm64.tar.gz.sha256
tar -xzf openwebui-wiki-bundle-<버전>-macos-arm64.tar.gz
cd openwebui-wiki-bundle-<버전>-macos-arm64
./install.sh
```

대상 Mac 에서는 sudo 도 다운로드도 필요 없습니다.

## 빠른 시작

```bash
./install.sh              # 오프라인 설치 (uv + 로컬 wheel) → .venv
source .venv/bin/activate
export HF_HUB_OFFLINE=1 OFFLINE_MODE=1
open-webui serve          # http://localhost:8080
./run-wiki-mcp.sh watch   # raw/ 감시 → 위키화
```

raw → wiki 변환은 기본으로 꺼져 있습니다. 먼저 `WIKI_INGEST_ENABLED=1`, `WIKI_INGEST_MODEL`,
`WIKI_INGEST_API_KEY` 를 설정하세요(INSTALL.md 참고). 설정이 없으면 `watch` 는 재인덱싱만 합니다.

## 문서

| 문서 | 내용 |
| --- | --- |
| [`INSTALL.md`](INSTALL.md) | **설치·설정** — 오프라인 설치, 도구 15개, 템플릿, raw 변환, 청킹, 문서추출, OCR |
| [`docs/USAGE.md`](docs/USAGE.md) | **실사용 매뉴얼** — 설치 후 장치별 연동·검증·사용 (Open WebUI 연결) |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | **상시 운영** — 서비스 기동, launchd 자동 시작, 헬스체크, 백업 |
| [`docs/TESTING.md`](docs/TESTING.md) | **테스트 전략** — 대상·우선순위·실행 |
| [`docs/KNOWLEDGE-BASE.md`](docs/KNOWLEDGE-BASE.md) | **지식 구축** — 원자 노트 원칙, 투입 전략, 품질 튜닝, 유지보수 |
| [`docs/LM-STUDIO.md`](docs/LM-STUDIO.md) | **LM Studio 연동** — 채팅·Knowledge 임베딩·Wiki MCP 공동 사용, 에어갭 설정 |
| [`docs/INSTALL-ISSUES.md`](docs/INSTALL-ISSUES.md) | **설치 문제 기록** — 클린 Mac 에서 만난 문제와 해결 |

설치 후 처음 할 일은 [`docs/USAGE.md`](docs/USAGE.md)의 연동 체크리스트입니다.

## 사전 요구사항 (대상 장비에 미리 준비)

| 항목 | 비고 |
| --- | --- |
| macOS (Apple Silicon / arm64) | 번들 wheel이 arm64 전용 |
| `uv` 0.5+ | 에어갭이면 바이너리 미리 반입 |
| Python 3.11 또는 3.12 | uv가 오프라인에서 내려받을 수 없으므로 사전 설치 |
| `openwebui-packages/` | **오프라인 wheel 저장소(~834MB)** — 이 저장소에는 없음(위 참조) |

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
guardian/             # 통합 번들 — 병합 스크립트, 설치기, claude-lms
.env.example          # 환경 변수 예시 (cp .env.example .env)
run-openwebui.sh      # Open WebUI 실행기 (.env 자동 로드)
load-env.sh           # .env 로더 (공용)
```

> **`openwebui-packages/`(wheel ~834MB)와 배포 tar.gz는 저장소에 포함하지 않습니다.**
> 대용량 바이너리는 git에 부적합하므로 빌드 Mac에서 만들어 옮깁니다(위 "완성 번들은 직접 만든다").

번들은 **경로에 종속되지 않습니다** — 어느 위치에 풀어도 스크립트가 자기 위치를 기준으로 동작합니다.

## 배포 (관리자)

관리자가 자기 Gitea 서버의 Release에 번들을 올리는 절차입니다.

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

## 라이선스

[MIT](LICENSE)
