# Open WebUI + Wiki MCP 오프라인 설치 가이드 (자체 완결형)

인터넷이 차단된(에어갭) 환경에서 **Open WebUI 0.12.3** 와 **wiki-mcp**(LLM Wiki를 MCP tool로
노출) + **mcpo**(REST 브리지)를 하나로 설치하는 절차입니다. 소스·wiki 콘텐츠·의존성이 모두
이 디렉토리(`openwebui/`) 안에 있어 외부 저장소 없이 단독 운영됩니다.

> 검증 환경: macOS arm64 · uv 0.11.7 · Python 3.12.13 · open-webui 0.12.3 (번들 wheel 기준)
>
> 아래 3장 설치 명령은 `.venv`를 삭제 후 처음부터 **완전 오프라인으로 재구성하여
> end-to-end 검증**되었습니다. 패키지 관리자는 **uv** 를 사용합니다.
>
> **설치 경로 (중요)**: 번들은 **어느 경로에 풀어도 동작**합니다(경로 종속 없음).
> 이 문서는 번들을 푼 디렉토리를 **`$OW`** 로 표기합니다. 압축 해제 후 그 안에서
> 아래 한 줄을 실행하면 이후 모든 명령을 그대로 복사해 쓸 수 있습니다.
>
> ```bash
> cd <번들을 푼 경로> && OW=$(pwd)     # 예: cd ~/openwebui-wiki-bundle && OW=$(pwd)
> ```

---

## 1. 사전 요구사항

| 항목 | 요구사항 |
| --- | --- |
| OS | macOS (Apple Silicon / arm64) |
| uv | 0.5 이상 (검증: 0.9.21) — **대상 장비에 미리 설치되어 있어야 함** |
| Python | 3.11 또는 3.12 인터프리터가 **대상 장비에 미리 존재해야 함** (검증: 3.12.12) |
| 디스크 | 약 3GB 이상 여유 공간 (`.venv` 약 1.9GB + 번들 약 834MB) |
| 네트워크 | **완전 불필요** — 모든 wheel이 로컬 번들에 포함 |

> ⚠️ 이 번들의 wheel은 **macOS arm64 + Python 3.11/3.12** 전용입니다.
> Linux/Windows 또는 x86_64(Intel) 환경에서는 동작하지 않습니다.

### 에어갭(완전 오프라인) 필수 전제

인터넷이 전혀 없는 장비에서는 아래 두 가지가 **설치 전에 이미 준비**되어 있어야 합니다.
wheel 번들만으로는 해결되지 않는 부분입니다.

1. **uv 바이너리** — 대상 장비에 미리 반입/설치 (`uv --version` 으로 확인)
2. **호환 Python(3.11/3.12) 인터프리터** — 시스템 Python(예: Homebrew) 또는
   uv 관리형 Python 중 **이미 로컬에 존재하는 것**. uv는 요청한 버전이 없으면
   인터넷에서 Python을 내려받으려 하므로, 에어갭에서는 반드시
   `--no-python-downloads`(또는 `UV_PYTHON_DOWNLOADS=never`)로 다운로드를 차단하고
   **이미 있는 인터프리터**를 사용해야 합니다.

확인:

```bash
uv --version                    # uv 0.5.x 이상 (검증: 0.9.21)
uv python list --only-installed # 로컬에 실제 존재하는 인터프리터만 표시
```

> 위 목록에 3.11.x 또는 3.12.x 가 없으면, 오프라인에서는 진행 불가입니다.
> 대상 장비에 해당 Python을 먼저 설치하세요(시스템 패키지 또는 미리 받아둔 uv Python).

---

## 2. 번들 구성

```text
$OW/                          # 번들을 푼 디렉토리 (이름·위치 자유)
├── openwebui-packages/       # 오프라인 wheel 저장소 (300개, ~834MB, cp311·cp312)
│   ├── open_webui-0.12.3-py3-none-any.whl
│   └── ... (전체 의존성 + wiki-mcp 보충 wheel)
├── wiki-mcp/                 # ★ wiki-mcp 소스 (복사본, editable 설치 대상)
│   ├── pyproject.toml
│   └── src/wiki_mcp/
├── wiki/                     # ★ wiki 콘텐츠 (예제로 seed됨 — 여기에 새로 구축)
│   └── .templates/           # 노트 양식 템플릿 (concept, guide) — 7-4 참고
├── raw/                      # 원문 투입 → LLM이 노트로 자동 변환 — 7-6 참고
├── ocr/                      # Apple Vision OCR 헬퍼 (vision-ocr 바이너리) — 7-9 참고
├── wiki-data/                # ChromaDB + 인덱스 캐시 (자동 생성, gitignore 권장)
├── .venv/                    # (선택) 이미 설치된 가상환경
├── install.sh                # ★ 원커맨드 오프라인 설치 (3-0)
├── run-wiki-mcp.sh           # ★ wiki-mcp 통합 실행기 (serve|mcpo|watch)
├── .env.example              # 환경 변수 예시 → cp .env.example .env
├── load-env.sh               # .env 로더 (실행 스크립트가 공용으로 사용)
├── run-openwebui.sh          # Open WebUI 실행기 (.env 자동 로드)
└── INSTALL.md                # 이 문서
```

- wiki-mcp는 `openwebui/wiki-mcp` 복사본을 **editable(`-e`)로 설치** — 소스 수정 즉시 반영
- wiki 콘텐츠는 **이전 데이터를 가져오지 않고** 예제 노트로 시작, 이 위에 새로 구축
- 무거운 공통 의존성(`chromadb`·`mcp`·`rank-bm25`·`uvicorn` 등)은 Open WebUI 번들과 공유

---

## 3. 설치 절차

### 3-0. 빠른 설치 (원커맨드) — 권장

압축을 푼 디렉토리에서 아래 한 줄이면 됩니다. `install.sh`가 3-1의 5단계를
그대로 **오프라인으로 자동 실행**하고 설치를 검증합니다.

```bash
cd <번들을 푼 경로>
./install.sh                 # 기존 .venv 있으면 재사용
# ./install.sh --recreate    # .venv를 새로 만들어 설치
# PYVER=3.11 ./install.sh     # Python 버전 지정 (기본: 3.12 우선)
```

- 사전 요구사항(uv 바이너리, 로컬 Python 3.11/3.12)을 점검하고 없으면 안내 후 중단합니다(1장 참조).
- 완료 후 실행 방법을 출력합니다. 세부 원리·문제 해결은 아래 3-1 및 4장 이후를 참고하세요.

### 3-1. 전체 설치 (검증된 명령 — 수동/이해용)

`install.sh`가 실행하는 것과 동일한 명령입니다. 수동 설치하거나 각 단계를 이해할 때 참고하세요.
모든 명령에 `--offline --no-index --find-links` 를 지정해 **네트워크를 완전히 차단**합니다.
(`--offline` = 모든 네트워크 차단, `--no-index` = PyPI 접속 차단, `--find-links` = 로컬 저장소)

```bash
cd <번들을 푼 경로>
OW=$(pwd)

# 1) 가상환경 생성 (에어갭: Python 자동 다운로드 차단)
uv venv --offline --no-python-downloads --python 3.12 "$OW/.venv"

# 2) Open WebUI 오프라인 설치
uv pip install --python "$OW/.venv/bin/python" \
  --offline --no-index --find-links="$OW/openwebui-packages" \
  open-webui==0.12.3

# 3) 빌드 도구 선(先)설치 — editable(-e) 설치의 --no-build-isolation 전제.
#    새로 만든 uv venv에는 setuptools/wheel이 없으므로 번들에서 먼저 설치해야 함.
uv pip install --python "$OW/.venv/bin/python" \
  --offline --no-index --find-links="$OW/openwebui-packages" \
  setuptools wheel

# 4) wiki-mcp (복사본) editable 설치
uv pip install --python "$OW/.venv/bin/python" \
  --offline --no-index --find-links="$OW/openwebui-packages" \
  --no-build-isolation -e "$OW/wiki-mcp"

# 5) mcpo (REST 브리지) 설치
uv pip install --python "$OW/.venv/bin/python" \
  --offline --no-index --find-links="$OW/openwebui-packages" mcpo
```

> `--python "$OW/.venv/bin/python"` 을 쓰면 activate 없이 실행됩니다.
> 대신 `source .venv/bin/activate` 후 `--python` 을 생략해도 됩니다.

각 단계 주의점:

- **3.12가 로컬에 없고 3.11만 있다면** 1)에서 `--python 3.11` 로 대체하세요.
  `Because no interpreter was found ...` 오류는 에어갭에서 uv가 Python을 못 받는 경우입니다.
- **3) 단계를 건너뛰면** 4)의 `-e` 빌드가 setuptools를 찾지 못해 실패합니다.
  (`uv venv --seed` 로는 pip만 들어가고 setuptools/wheel은 포함되지 않음.)
- Open WebUI 본체(2)는 순수 wheel이라 빌드 도구 없이도 설치됩니다.

### 3-2. 설치 확인

```bash
OW=$(pwd)      # 번들을 푼 디렉토리에서 실행

# 버전 확인
"$OW/.venv/bin/python" - <<'EOF'
from importlib.metadata import version
for p in ["open-webui","wiki-mcp","mcpo","python-frontmatter","watchdog","passlib"]:
    print(f"{p:20s} {version(p)}")
EOF
# 예상: open-webui 0.12.3 / wiki-mcp 0.2.0 / mcpo 0.0.20 / python-frontmatter 1.3.0
#       watchdog 6.0.0 / passlib 1.7.4

# editable 경로가 번들 내부를 가리키는지 (자체 완결 확인)
"$OW/.venv/bin/python" -c "import open_webui, wiki_mcp.server; print(wiki_mcp.server.__file__)"
# → .../openwebui/wiki-mcp/src/wiki_mcp/server.py

# CLI 동작
"$OW/.venv/bin/open-webui" --help
```

---

## 4. 실행

### 4-0. 설정 파일 (`.env`) — 먼저 만들면 편합니다

`run-openwebui.sh` 와 `run-wiki-mcp.sh` 는 번들 루트의 **`.env` 를 자동으로 읽습니다.**
매번 `export` 하지 않아도 됩니다.

```bash
cp .env.example .env       # 필요한 값만 주석 해제/수정
```

- **우선순위**: 셸 환경변수 > `.env` > 스크립트 기본값
  → 일회성 오버라이드 가능: `WIKI_INGEST_MODEL=other ./run-wiki-mcp.sh watch`
- `.env` 는 **gitignore 대상**입니다 (로컬 설정·비밀값이 커밋되지 않음)
- `.env.example` 에 Open WebUI·wiki-mcp 설정이 **모두** 정리돼 있습니다

### 4-1. Open WebUI

```bash
./run-openwebui.sh                  # .env 로드 + 오프라인 기본값 적용
./run-openwebui.sh --port 3000      # 인자는 open-webui serve 로 전달됨
```

- 기본 접속 주소: <http://localhost:8080> (`.env`의 `WEBUI_PORT`로 변경)
- DB·업로드는 번들 안 `data/`에 저장됩니다(`DATA_DIR` 기본값).
- 최초 접속 시 관리자 계정을 생성합니다.
- `HF_HUB_OFFLINE=1`, `OFFLINE_MODE=1` 이 자동 적용됩니다(외부 호출 차단 → 첫 기동 지연/오류 방지)

> 직접 실행하려면 `open-webui serve` 도 됩니다. 다만 위 오프라인 변수와 `.env` 는
> 수동으로 설정해야 합니다.

> 세션 암호화 키(`WEBUI_SECRET_KEY`)는 지정하지 않으면 첫 기동 시 자동 생성됩니다.
> 재기동 간 세션을 유지하려면 고정 키를 지정하세요(1회 생성 후 재사용):
>
> ```bash
> [ -f .webui_secret_key ] || python -c "import secrets; open('.webui_secret_key','w').write(secrets.token_hex(16))"
> export WEBUI_SECRET_KEY="$(cat .webui_secret_key)"
> ```

### 4-2. Wiki MCP

`run-wiki-mcp.sh`는 번들 내부 경로만 사용합니다. 기본 BM25-only(Ollama 불필요).

```bash
cd "$OW"        # 번들을 푼 디렉토리

# (A) Open WebUI 연결용 REST 브리지 (:8766)
./run-wiki-mcp.sh mcpo

# (B) Claude Code / Cursor 직접 연결 (stdio)
./run-wiki-mcp.sh serve

# (C) wiki 변경 감지 자동 재인덱싱
./run-wiki-mcp.sh watch
```

기본 환경 변수(스크립트 내장, 필요 시 오버라이드):

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `WIKI_PATH` | `./wiki` | wiki 콘텐츠 경로 |
| `WIKI_DATA_DIR` | `./wiki-data` | 인덱스/벡터 DB 저장 |
| `EMBEDDING_DISABLED` | `1` | BM25-only. 의미검색(하이브리드) 쓰려면 `0` — [docs/KNOWLEDGE-BASE.md](docs/KNOWLEDGE-BASE.md) 5장 |
| `WIKI_MCPO_PORT` | `8766` | mcpo 포트 |
| `WIKI_MCPO_KEY` | (없음 — `.env` 필수) | mcpo API 키 |

---

## 5. Wiki MCP 등록

### Claude Code / Cursor (stdio)

`command`를 `run-wiki-mcp.sh serve`로 지정하면 wiki 경로·모드 env가 스크립트에서 주입됩니다
(별도 env 설정 불필요 — 자체 완결).

MCP 클라이언트는 `command`에 **절대 경로**를 요구합니다. 번들에서 아래로 값을 얻으세요:

```bash
echo "$OW/run-wiki-mcp.sh"     # 이 출력값을 command에 그대로 붙여넣기
```

```json
// ~/.claude/settings.json 또는 프로젝트 .mcp.json / ~/.cursor/mcp.json
{
  "mcpServers": {
    "wiki": {
      "command": "<위에서 출력된 절대경로>/run-wiki-mcp.sh",
      "args": ["serve"]
    }
  }
}
```

> 직접 `wiki-mcp` 바이너리를 command로 쓰면 env 미주입 시 기본값(예제 wiki/Ollama)을
> 바라보므로, 반드시 `run-wiki-mcp.sh serve`를 경유하거나 `env` 블록으로 `WIKI_PATH`/
> `WIKI_DATA_DIR`/`EMBEDDING_DISABLED`를 명시하세요.

### Open WebUI

Open WebUI에서 **Settings → Tools → +Add Tool Server** 로 이동해 등록합니다.

- URL: `http://localhost:8766` (Docker면 `http://host.docker.internal:8766`)
- API Key: `.env`의 `WIKI_MCPO_KEY` 값

→ 15개 tool 자동 등록. (먼저 `./run-wiki-mcp.sh mcpo` 로 브리지를 띄워야 함)

---

## 6. 노출되는 15개 도구

`search_wiki`, `read_note`, `find_related`, `list_domains`, `find_broken_links`,
`suggest_new_note`, `get_wiki_stats`, `verify_citations`, `reindex`,
`create_note`, `update_note`, `add_link`, `delete_note`, `list_templates`,
`ingest_raw`

---

## 7. 데이터 넣기와 사용법

### 데이터 모델

**최종 데이터는 `wiki/` 안의 마크다운 노트**입니다. 검색 인덱스(`wiki-data/`)는 이
노트들로부터 자동 생성됩니다. 노트를 채우는 경로는 두 가지입니다:

- **`raw/` (원문 투입 → 자동 변환)** — 원문 파일(텍스트/PDF/이미지 등)을 `raw/`에 넣으면
  LLM이 추출·변환해 `wiki/`에 노트를 생성합니다. "원문 → 노트"의 staging 겸 입력구입니다.
  (7-6 ~ 7-9)
- **`wiki/` (노트 직접 작성)** — 마크다운 노트를 직접/도구로 `wiki/`에 두면 그대로 데이터가
  됩니다. (원본 출처는 노트 frontmatter의 `source_url`로 기록.)

```text
raw/                  ← (선택) 원문 투입 → LLM이 wiki/ 노트로 자동 변환
├── .processed/          성공한 원문 이동 (자동 생성)
└── .failed/             실패한 원문 이동 (자동 생성)
wiki/                 ← 데이터(노트) 위치. .md를 직접 두거나 raw 변환 결과가 쌓임
├── index.md
├── concepts/*.md
└── .templates/       ← 양식 파일 (노트 아님, 인덱싱 제외)
wiki-data/            ← 자동 생성 검색 인덱스 (지워도 재인덱싱으로 복구)
```

현재 `wiki/`에는 예제 노트 4개(`index.md`, `concepts/*` 3개)가 있습니다.
(`README.md`는 frontmatter `id`가 없어 노트로 인덱싱되지 않는 안내 문서입니다.)

### 7-1. 노트 파일 형식

노트는 **YAML frontmatter + 마크다운 본문**이며, 하위 디렉토리 어디에 두어도 됩니다
(인덱서가 `wiki/` 전체를 재귀 스캔). **`id`만 필수**이고 나머지는 선택입니다.

```markdown
---
id: prompt-chaining          # 필수. kebab-case (소문자/숫자/하이픈), 한글 불가
title: "프롬프트 체이닝"      # 선택
source_url: "https://..."    # 선택 — 원본 출처
tags: [prompt, technique]    # 선택 — inline 리스트
created_at: "2026-07-11"     # 선택
last_updated: "2026-07-11"   # 선택
---

본문 마크다운. 다른 노트는 `[[note-id]]` 로 링크하면 그래프에 자동 반영됩니다.
예: 자세한 내용은 [[rag]] 및 [[few-shot]] 참고.
```

- `id`가 없는 `.md`는 노트로 취급되지 않습니다(안내 문서로 방치 가능).
- 링크는 본문의 `[[id]]` 패턴으로 추출됩니다. 표시 텍스트는 `[[id|보일 제목]]`.

### 7-2. 데이터 넣는 4가지 방법

1. **raw 원문 자동 변환 (권장)** — 원문 파일(텍스트/PDF/Word/이미지 등)을 `raw/`에
   넣으면 LLM이 위키 노트로 **자동 생성**합니다. 문서 추출·긴 문서 분할·OCR까지
   포함한 무인 파이프라인입니다. (상세: **7-6 ~ 7-9**)
2. **마크다운 파일 직접 추가** — 위 형식의 `.md`를 `wiki/`(또는 `wiki/<도메인>/`)에
   복사/작성. 대량 반입 시 각 파일에 `id` frontmatter만 갖추면 됩니다.
3. **LLM 도구로 생성** — Claude Code / Cursor / Open WebUI에서 `create_note`(양식은
   `template=` 지정), `update_note`, `add_link` tool 호출. (7-4 템플릿 참고)
4. **기존 문서 이관** — 다른 곳의 마크다운을 옮긴 뒤, `id` frontmatter를 추가하고
   `[[id]]` 링크를 붙이면 그래프에 편입됩니다.

> 1번(raw 자동 변환)이 원래 "원문 → 위키" 개념의 핵심 흐름입니다. 2~4번은 노트를
> 직접/도구로 작성하는 수동 경로입니다.

### 7-3. 변경 반영 (재인덱싱)

파일을 추가/수정한 뒤에는 인덱스를 갱신해야 검색에 반영됩니다.

- 수동: `reindex` tool 호출
- 자동: `./run-wiki-mcp.sh watch` 상시 실행 (파일 변경 감지 → 자동 재인덱싱)

> `create_note` / `update_note` 등 쓰기 도구는 실행 시 **자동으로 재인덱싱**하므로
> 별도 `reindex`가 필요 없습니다. 직접 파일을 편집한 경우에만 위 절차가 필요합니다.

### 7-4. 노트 양식(템플릿) 지정

`create_note`가 만드는 노트의 **frontmatter 필드와 본문 섹션 구조**를 템플릿 파일로
고정할 수 있습니다. 템플릿은 `wiki/.templates/<이름>.md` 에 두며(숨김 디렉토리라
인덱싱 대상에서 자동 제외됨), **양식 변경은 이 파일만 수정**하면 됩니다(재설치 불필요).

기본 제공 템플릿: `concept`, `guide`. 목록은 `list_templates` tool로 확인합니다.

템플릿 예 (`wiki/.templates/concept.md`):

```text
---
tags: []
status: draft
category: concept
---

## 개요

{{body}}

## 핵심 내용

## 예시

## 관련 노트

{{links}}
```

- **frontmatter**: 표준 6필드(`id`/`title`/`source_url`/`tags`/`created_at`/`last_updated`)는
  `create_note` 인자로 자동 채워지고, 템플릿에 적은 **추가 필드**(예: `status`, `category`)가
  그대로 붙습니다. 인덱서는 `id`만 필수라 추가 필드는 안전하게 무시됩니다.
- **본문 플레이스홀더**: `{{body}}`(호출 시 넘긴 본문), `{{links}}`(cross-link 목록),
  `{{id}}` · `{{title}}` · `{{date}}` · `{{tags}}`.
- `{{links}}`가 있으면 링크를 그 자리에 배치하고, 없으면 `## 관련 노트` 섹션을 자동 추가합니다.

사용:

```text
list_templates()                                  # 사용 가능한 양식 확인
create_note(id="graphrag", title="GraphRAG",
            body="...", tags=["rag"], template="concept")
```

모든 노트에 특정 양식을 강제하려면 기본 템플릿을 지정합니다(스크립트 실행 전 export):

```bash
export WIKI_DEFAULT_TEMPLATE=concept   # template 미지정 시 이 양식 적용
export WIKI_TEMPLATE_DIR=./wiki/.templates   # (선택) 템플릿 경로 변경
```

### 7-5. 검색·활용 (읽기 도구)

넣은 데이터는 Open WebUI 채팅 또는 Claude Code / Cursor에서 아래 도구로 활용합니다.

| 도구 | 용도 |
| --- | --- |
| `search_wiki(query, top_k)` | BM25+임베딩 하이브리드 검색 (한/영, `[[id]]` 정확매칭) |
| `read_note(note_id)` | 특정 노트 원문 읽기 |
| `find_related(note_id, depth)` | 링크 그래프 기반 관련 노트 탐색 |
| `suggest_new_note(topic)` | 새 노트의 권장 ID·경로·cross-link 제안 |
| `list_domains` / `get_wiki_stats` | 도메인 목록 / 전체 통계(노트 수·링크·허브) |
| `find_broken_links` / `verify_citations` | 깨진 `[[id]]` 링크 / 출처 검증 |
| `list_templates` | 사용 가능한 노트 양식 목록 |

예: Open WebUI 채팅에서 "search_wiki로 GraphRAG 관련 노트를 찾아줘" → 검색 후
`read_note`로 원문을 읽고 답변에 인용하는 식으로 자연어 사용이 가능합니다.

### 7-6. raw 원문 자동 위키화 (LLM 변환)

`raw/` 디렉토리에 **원문 텍스트를 넣으면 LLM이 위키 노트로 자동 변환**합니다.
(7-2의 수동 작성과 별개인, 원래 "원문 → 위키" 개념의 무인 파이프라인.)

```text
raw/ (원문 drop)  ─추출→  Source 노트 보존  ─LLM+근거검증→  원자 노트  →  자동 reindex
                              │                            │
                    wiki/sources/concepts/        검증된 원문 인용 + Source 링크
     성공: raw/.processed/ 로 이동 · 실패: raw/.failed/ 로 이동 (로그 확인)
```

변환 지능은 **Open WebUI에 연결된 모델(OpenAI 호환 API)**이 담당합니다
(wiki-mcp 자체에는 생성 LLM이 없음). 따라서 Open WebUI 서버와 API 키가 필요합니다.

**설정** (기본 off — 아래를 설정해야 활성화):

```bash
export WIKI_INGEST_ENABLED=1
export WIKI_INGEST_MODEL="<Open WebUI에 등록된 모델명>"   # 필수
export WIKI_INGEST_API_KEY="<Open WebUI API 키>"          # Settings → Account → API Keys
# 기본값으로 충분한 항목 (필요 시만 변경):
# export WIKI_INGEST_URL=http://localhost:8080/api/chat/completions
# export WIKI_INGEST_TEMPLATE=concept   # 생성 노트에 양식 적용 (선택)
```

**사용**:

```bash
# (A) 무인 자동 — watch 데몬이 raw/ 감시하며 자동 변환
./run-wiki-mcp.sh watch

# (B) 수동/에이전트 — ingest_raw 도구 즉시 실행 (watch 불필요)
#     ingest_raw()              # raw/ 전체 (최대 10개)
#     ingest_raw(file="a.txt")  # 특정 파일만
```

- **하위 폴더 지원** — `raw/` 를 재귀적으로 스캔합니다(예: `raw/도메인/주제/*.md`).
  원문 이동 시 폴더 구조가 보존됩니다(`raw/a/b.md` → `raw/.processed/a/b.md`).
- 처리 대상 확장자: 텍스트 + **문서(`.pdf`/`.docx`/`.pptx`/`.xlsx`/`.html`)** + **이미지(`.png`/`.jpg`)**
  (`WIKI_INGEST_EXT`로 변경). `README.md`와 숨김 파일은 원문으로 취급하지 않습니다.
- **문서는 텍스트 자동 추출**(7-8), **스캔 PDF·이미지는 OCR**(7-9). 모두 오프라인 동작.
- **원문 우선 보존** — LLM 호출 전에 추출 텍스트 전체를
  `wiki/sources/concepts/source-<파일명>-<hash>.md`에 저장합니다. 파생 노트 생성이
  실패해도 Source 노트는 남아 원문 내용이 누락되지 않습니다.
- **근거 검증** — LLM은 각 파생 노트에 원문에서 그대로 복사한 `evidence` 구절을
  제출해야 합니다. 구절이 실제 참고 원문에 없거나 너무 짧으면 파생 노트를 만들지
  않고 실패 처리합니다. 생성 노트에는 Source 링크와 검증된 인용문이 기록됩니다.
- **기존 노트 연결** — 전체 Wiki 목록을 로컬 모델에 넣지 않습니다. 현재
  BM25/hybrid 검색으로 관련 후보를 최대 8개 선정하고 `ID | 제목 | 태그`만 전달합니다.
  LLM이 후보에 없는 ID를 반환하면 시스템이 해당 링크를 제거하고 경고를 남깁니다.
  별도 LLM 판정 호출은 추가하지 않아 로컬 추론 시간과 JSON 실패 가능성을 억제합니다.
- 생성 노트는 `create_note` 안전장치를 그대로 거칩니다(ID 검증·충돌 거부·백업).
  ID가 기존 노트와 충돌하면 실패로 처리되어 원문이 `raw/.failed/`로 이동합니다.
- **양식 적용**: `WIKI_INGEST_TEMPLATE=concept` 설정 시 LLM이 템플릿의 각 섹션
  (`## 개요`/`## 핵심 내용`/`## 예시`)을 채웁니다. 미설정 시 LLM이 자유 구조로 작성.
- 미설정(모델/키 없음) 상태에서 `watch`는 **기존처럼 재인덱싱만** 수행합니다(하위호환).
- 변환은 모델 크기에 비례해 시간이 걸립니다(예: 로컬 12B 모델 약 1~1.5분/노트).
  변환 중에는 다른 감지 이벤트가 대기합니다. 대량 처리 시 더 작은 모델 권장.

### 7-7. 긴 문서 청킹 (여러 노트로 분할)

원문이 길면(`WIKI_INGEST_MAX_CHARS` 초과) 한 문서를 **여러 원자 노트로 자동 분할**합니다.
"원자 노트 = 개념 1개" 원칙을 지키기 위한 **아웃라인 → 노트별 작성** 2단계 방식입니다.

```text
긴 원문 ─▶ ① 아웃라인(LLM): 노트 목록 계획  ─▶ ② 노트별 작성(LLM): 각 노트 본문
                    │                                    │
        헤딩/크기로 창 분할해 계획              형제 노트 id를 알려줘 [[id]] 상호링크 유도
```

- 짧은 문서(임계값 이하)는 기존처럼 **1문서 → 1노트**로 처리됩니다.
- 각 노트는 `WIKI_INGEST_TEMPLATE` 양식을 그대로 적용받고, 같은 문서에서 나온
  노트끼리 `[[id]]`로 상호 링크됩니다.
- **부분 성공 정책**: 계획된 파생 노트가 1개 이상 성공하면 원문을
  `raw/.processed/`로, 전부 실패하면 `raw/.failed/`로 이동합니다. 어느 경우에도
  먼저 생성된 Source 노트는 보존되어 재검토와 재처리의 기준이 됩니다.

**파라미터**:

```bash
export WIKI_INGEST_MAX_CHARS=6000   # 이 문자 수 초과 시 청킹(분할). 0=항상 단일 노트
export WIKI_INGEST_MAX_NOTES=20     # 문서당 생성 노트 상한 (폭주 방지)
```

> 처리 시간은 **노트 수에 비례**합니다(아웃라인 + 노트당 1회 호출). 예: 개념 2개
> 문서 → 노트 2개 → 약 4회 LLM 호출. 큰 문서·대량 처리 시 작은 모델을 권장합니다.

### 7-8. 문서 파일 지원 (PDF 등, 오프라인 추출)

`raw/`에 **PDF·Word·PowerPoint·Excel·HTML**을 넣으면 텍스트를 자동 추출한 뒤
위 파이프라인(단일/청킹)으로 노트화합니다. 추출은 **완전 오프라인**입니다 —
open-webui에 이미 포함된 순수 파이썬 라이브러리만 사용하며 네트워크·모델 다운로드가 없습니다.

| 포맷 | 라이브러리 | 처리 방식 |
| --- | --- | --- |
| `.pdf` | pypdf | 페이지별 텍스트 추출 (표는 선형화됨) |
| `.docx` | docx2txt | 전체 텍스트 |
| `.pptx` | python-pptx | 슬라이드마다 `## 제목` + 본문 |
| `.xlsx` | openpyxl | 시트마다 `## 시트명` + 마크다운 표(시트당 최대 200행) |
| `.html`/`.htm` | beautifulsoup4 | 헤딩(`h1~h6`)→`#` 매핑, script/style 제거 |
| `.pdf`(스캔) · `.png`/`.jpg` | **Apple Vision (OCR)** | 텍스트 없는 PDF/이미지를 OS 내장 OCR로 인식 |

- **스캔/이미지 PDF와 이미지 파일도 OCR로 처리**합니다(7-9 참고). 텍스트 PDF는 그대로 추출하고,
  텍스트가 빈약하면 자동으로 OCR로 폴백합니다.
- 표 구조는 PDF에서 손실될 수 있습니다(내용은 보존). 정밀 표는 `.xlsx` 경로가 유리합니다.

**파라미터**:

```bash
export WIKI_INGEST_MAX_EXTRACT_CHARS=200000   # 추출 텍스트 상한(초과 시 잘라냄)
export WIKI_INGEST_XLSX_MAX_ROWS=200          # xlsx 시트당 직렬화 행 상한
```

### 7-9. OCR (스캔 PDF·이미지, Apple Vision)

텍스트 레이어가 없는 **스캔 PDF**나 **이미지 파일(`.png`/`.jpg`)**은 **Apple Vision**으로
텍스트를 인식합니다. Vision은 **macOS에 내장된 OCR 엔진**이라 모델 다운로드가 없고
한국어·영어를 높은 정확도로 처리하며 **완전 오프라인**입니다.

```text
스캔 PDF ─▶ pypdf 추출 시도(빈약) ─▶ OCR 폴백(vision-ocr) ─▶ 인식 텍스트 ─▶ 파이프라인
이미지    ─▶ 바로 OCR ─▶ 인식 텍스트 ─▶ 파이프라인
```

- 구현: 번들 `ocr/vision-ocr`(사전 컴파일된 arm64 네이티브 바이너리)가 PDFKit으로 페이지를
  렌더링하고 Vision으로 인식합니다. **대상 Mac에 Xcode/파이썬 추가 설치 불필요**
  (Vision·PDFKit·Swift 런타임은 macOS 기본 포함).
- 기본 **활성화**(`WIKI_INGEST_OCR=1`). 텍스트 PDF에는 영향 없이, 스캔본에만 폴백으로 작동합니다.
- 바이너리가 없으면 조용히 건너뜁니다(스캔본은 `.failed/`로 이동).

```bash
export WIKI_INGEST_OCR=1                       # OCR 폴백 (기본 on)
# export WIKI_INGEST_OCR_BIN=/경로/vision-ocr  # 바이너리 경로 (기본: <번들>/ocr/vision-ocr)
```

> 재빌드가 필요하면(예: 소스 수정): `swiftc -O -o ocr/vision-ocr ocr/vision_ocr.swift`
> (빌드에는 Xcode CLT가 필요하지만, **배포된 바이너리 실행에는 불필요**합니다.)

---

## 8. 데이터 위치

- **Open WebUI**: 런타임 데이터(DB, 업로드 파일 등)는 `run-openwebui.sh`가 정하는
  `DATA_DIR`(기본 `$OW/data`)에 생성됩니다. `.venv`를 다시 만들어도 지워지지 않습니다.
- **0.10.2 번들에서 올리는 경우**: 0.10.2는 `DATA_DIR` 없이 `.venv/lib/python3.*/site-packages/open_webui/data`에
  데이터를 두었습니다. Open WebUI를 끈 뒤 그 폴더를 `$OW/data`로 옮기세요. 옮기지 않으면
  `run-openwebui.sh`가 경고하고 멈춥니다. 0.12.3이 한 번 연 DB는 0.10.2로 되돌릴 수 없으니
  `webui.db`·`webui.db-wal`·`webui.db-shm`을 함께 백업해 두세요.

- **wiki-mcp**: 인덱스/벡터 DB는 `wiki-data/`(기본)에 생성됩니다. 삭제해도 다음 실행 시
  `wiki/`를 다시 인덱싱해 자동 재생성됩니다.

---

## 9. 다른 장비로 이관 (에어갭 포함)

**openwebui 디렉토리 전체를 복사**하면 그대로 동작합니다(외부 wheel 의존 없음).
단, 에어갭 대상 장비에는 **uv 바이너리**와 **호환 Python(3.11/3.12)**이 미리 준비되어
있어야 합니다(1장 참조). 이 둘은 wheel 번들로 해결되지 않습니다.

1. `openwebui/` 전체를 대상 장비로 복사 (`.venv`는 제외 권장 — 장비마다 재생성)
2. 3장 명령으로 Open WebUI + wiki-mcp + mcpo 설치 (setuptools 선설치 포함)
3. `open-webui serve` / `./run-wiki-mcp.sh mcpo` 로 실행

> `wiki/`와 `wiki-mcp/` 소스가 번들 안에 있으므로 editable 경로가 깨지지 않습니다.

---

## 10. 문제 해결

| 증상 | 원인 / 조치 |
| --- | --- |
| `No matching distribution found` | Python 버전이 3.11/3.12가 아니거나 arm64가 아님 → 버전/아키텍처 확인 |
| `uv`가 인터넷에 접속하려 함 | `--offline --no-index` 옵션 누락 → 명령 재확인 |
| uv가 Python을 내려받으려 함 / `No interpreter found` | 로컬에 3.11/3.12 인터프리터 없음 → `--no-python-downloads`로 차단하고 `uv python list --only-installed`의 버전으로 `--python` 지정. 없으면 대상 장비에 Python 먼저 설치 |
| `wheel was not found` / `Failed to build ... -e wiki-mcp` | 새 venv에 setuptools 없음 → 3장 3)단계로 `setuptools wheel` 선설치 후 `--no-build-isolation` 재실행 |
| `No module named pip` | 번들 `.venv`는 pip 없음 → `uv pip install` 사용 |
| `command not found: mcpo` | mcpo 미설치 → 3장 5)단계 실행 |
| Open WebUI 첫 기동이 느리거나 멈춤 | 외부 모델 다운로드 시도 → 4-1의 오프라인 환경 변수 설정 |
| Open WebUI에서 tool 안 보임 | mcpo 미기동 또는 API 키 불일치 → `lsof -i :8766` |
| 검색 결과 0개 | `wiki/`가 비었거나 인덱싱 전 → 노트 추가 후 `reindex` |
| 한국어 의미검색 필요 | `EMBEDDING_DISABLED=0` + 임베딩 백엔드(LM Studio/Ollama) — [docs/KNOWLEDGE-BASE.md](docs/KNOWLEDGE-BASE.md) 5장 |
| LM Studio로 Open WebUI·Wiki MCP 통합 | 채팅·Knowledge 임베딩·재인덱싱 — [docs/LM-STUDIO.md](docs/LM-STUDIO.md) |
| 의미검색 켰는데 벡터가 0개 | 캐시가 "변경 없음"으로 판단 → `rm wiki-data/index_cache.json` 후 재인덱싱 |
| 포트 충돌 (8080 / 8766) | `open-webui serve --port <포트>` / `WIKI_MCPO_PORT=<포트> ./run-wiki-mcp.sh mcpo` |

---

## 부록: 번들에 추가된 것 (wiki-mcp 통합)

- `openwebui-packages/` 보충 wheel 5개:
  `python_frontmatter-1.3.0`, `watchdog-6.0.0`, `mcpo-0.0.20`, `passlib-1.7.4`, `wheel-0.47.0`
- `.venv`: `wiki-mcp==0.2.0`(openwebui/wiki-mcp 복사본), `mcpo==0.0.20`,
  `python-frontmatter`, `watchdog`, `passlib`, `setuptools`
- 신규 디렉토리/파일: `wiki-mcp/`(소스 복사본), `wiki/`(예제 seed),
  `wiki/.templates/`(노트 양식), `raw/`(원문 투입), `run-wiki-mcp.sh`, `run-openwebui.sh`, `.env.example`
- wiki-mcp 기능 추가: 노트 템플릿(`list_templates` + `create_note(template=)`),
  raw→wiki LLM 자동 변환(`ingest_raw` 도구 + `watch` 데몬 통합),
  긴 문서 청킹(아웃라인→노트별 작성으로 1문서 → 다중 원자 노트),
  문서 파일 오프라인 추출(PDF/docx/pptx/xlsx/html — open-webui 번들 라이브러리 사용),
  스캔 PDF·이미지 OCR(Apple Vision 내장 엔진 — `ocr/vision-ocr` 네이티브 바이너리)
