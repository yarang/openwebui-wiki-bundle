# 실사용 매뉴얼 — 설치 이후 장치별 연동·검증

설치를 마친 **각 장치에서** 수행하는 절차입니다.
Open WebUI 채팅에서 wiki 도구를 실제로 쓸 수 있게 만드는 것이 목표입니다.
오프라인 Claude Code(`claude-lms`)와 문서 skill, 선택 구성인 llm-router는 [4장](#4-일상-사용)에서 요약하고 각 매뉴얼로 안내합니다.

> 설치는 [`../guardian/README.md`](../guardian/README.md)(통합 번들, 현행)를 참조하세요.
> 구 단독 번들 설치는 [`../INSTALL.md`](../INSTALL.md)에 참고용으로 남아 있습니다. 0 ~ 2장의 수동 절차는 그 흐름 기준입니다.
> 이 문서는 **설치 후 연결·검증·사용**만 다룹니다.

---

## guardian 번들 — 설치 직후의 모습

guardian 통합 번들로 설치했다면, 아래 0 ~ 2장의 수동 절차는 **필요 없습니다**.
설치 스크립트가 서비스 기동과 도구 서버 등록을 모두 마친 상태로 둡니다.

**돌아가는 서비스 (LaunchAgent 3개)**

| 서비스 | 라벨 | 주소 |
| --- | --- | --- |
| Open WebUI | `dev.guardian.openwebui` | http://localhost:8080 |
| mcpo (위키 도구 브리지) | `dev.guardian.wiki-mcpo` | http://127.0.0.1:8766 |
| raw 자동 변환 watch | `dev.guardian.wiki-watch` | — (감시 데몬) |

Claude Code 키트를 `--router-load`로 설치한 Mac에는 네 번째 LaunchAgent `dev.guardian.llm-router`(http://127.0.0.1:1240)가 더 있습니다. 선택 구성이며 [4장](#선택-큰-모델-llm-router)을 참고하세요.

**도구 서버 자동 등록**

- 설치 시 Open WebUI LaunchAgent에 `TOOL_SERVER_CONNECTIONS` 환경변수로
  mcpo 주소·키가 주입되어, 첫 기동부터 "wiki-mcp" 도구 서버가 등록되어 있습니다.
- 재설치·업데이트 때는 Open WebUI DB의 `tool_server.connections`도 갱신됩니다.
- 채팅 입력창의 도구 목록에 **15개 도구**가 보이면 정상입니다 (3장 체크리스트로 확인).

**파일 위치**

| 경로 | 내용 |
| --- | --- |
| `~/llm-wiki/wiki/` | 원자 노트 — 설치 시 시드 위키가 복사됨 |
| `~/llm-wiki/raw/` | 원문 투입 폴더 — watch가 자동으로 노트화 |
| `~/llm-wiki/wiki-data/` | 검색 인덱스 (지워도 재인덱싱으로 복구) |
| `~/llm-wiki/.env` | 위키 설정 (권한 600, mcpo 키 포함) — 아래 "환경 변수" 절 |
| `~/llm-wiki/logs/` | `mcpo.log`, `watch.log` |
| `~/.guardian-llm/venv` | Open WebUI·wiki-mcp가 쓰는 Python venv |

**LLM·임베딩 — LM Studio (http://127.0.0.1:1234)**

- 채팅·raw 변환: `gemma-4-e4b-it-mlx`
- 임베딩: `text-embedding-bge-m3` (1024차원) — BM25 + dense **하이브리드 검색**이 기본

**운영 명령**

```bash
launchctl kickstart -k gui/$(id -u)/dev.guardian.wiki-mcpo    # 위키 재기동
launchctl kickstart -k gui/$(id -u)/dev.guardian.wiki-watch
tail -f ~/llm-wiki/logs/mcpo.log ~/llm-wiki/logs/watch.log    # 로그 보기
```

설치·번들 구성은 [`../guardian/README.md`](../guardian/README.md)를 참조하세요.

## 아키텍처 요약

```text
Open WebUI (:8080) ──도구 호출──▶ mcpo (:8766, OpenAPI) ──▶ wiki-mcp (15개 MCP 도구)
      │                                                        │
      │ 채팅·RAG                                                ├─ wiki/      원자 노트 + [[id]] 링크
      ▼                                                         ├─ wiki-data/ BM25 + bge-m3 하이브리드 인덱스
LM Studio (127.0.0.1:1234)                                      └─ raw/ ──watch──▶ 노트 자동 생성
  gemma-4-e4b-it-mlx (채팅·raw 변환)                                  (gemma 호출)
  text-embedding-bge-m3 (임베딩)
```

- Open WebUI는 도구 서버로 mcpo를 바라보고, mcpo가 wiki-mcp의 15개 MCP 도구를 REST로 노출합니다.
- watch(LaunchAgent `dev.guardian.wiki-watch`)가 `raw/`를 감시해 원문을 노트로 변환합니다.
- 노트 파일이 바뀌면 mcpo 쪽 wiki-mcp가 스스로 감지해 재인덱싱합니다(임베딩 포함).

## 환경 변수

guardian 번들에서 설정은 `~/llm-wiki/.env` 한 곳에 모여 있습니다 (권한 600).
바꾼 뒤에는 위키 서비스 두 개(`dev.guardian.wiki-mcpo`, `dev.guardian.wiki-watch`)를 재기동합니다.
전체 목록은 `wiki-mcp/src/wiki_mcp/config.py`와 `guardian/wiki.env.example`을 참조하세요.

| 변수 | guardian 기본값 | 의미 |
| --- | --- | --- |
| `WIKI_PATH` | `~/llm-wiki/wiki` | 노트 폴더 |
| `WIKI_RAW_DIR` | `~/llm-wiki/raw` | 원문 투입 폴더 (watch 감시 대상) |
| `WIKI_DATA_DIR` | `~/llm-wiki/wiki-data` | 검색 인덱스 위치 |
| `EMBEDDING_DISABLED` | `0` | `1`이면 BM25-only |
| `EMBEDDING_MODEL` | `text-embedding-bge-m3` | 임베딩 모델 (1024차원) |
| `OLLAMA_URL` | `http://127.0.0.1:1234` | LM Studio OpenAI 호환 엔드포인트 |
| `WIKI_MCPO_PORT` / `WIKI_MCPO_KEY` | `8766` / 설치 시 자동 생성 | mcpo 브리지 주소·인증 키 |
| `WIKI_INGEST_ENABLED` | `1` | raw 자동 변환 활성화 |
| `WIKI_INGEST_MODEL` | `gemma-4-e4b-it-mlx` | raw 변환 LLM |
| `WIKI_INGEST_URL` | `http://127.0.0.1:1234/v1/chat/completions` | 변환 LLM 엔드포인트 (키 불필요) |
| `WIKI_MCP_TRANSPORT` | `stdio` (mcpo가 실행) | `http`면 직접 serve도 가능 |

> 아래 0 ~ 2장은 **구 방식(단독 번들)의 수동 절차**입니다. guardian 번들은 위처럼 자동으로
> 등록하므로 해당하지 않습니다. 수동 구성을 직접 다룰 때만 참고하세요.

---

## 0. 전체 그림

```text
Open WebUI (:8080)  ──①연결──▶  wiki-mcp  ──▶  wiki/ (노트)
     채팅 UI                     15개 도구        raw/ (원문 자동 변환)
```

연결 방식은 두 가지입니다. **어느 하나만** 선택하면 됩니다.

| 방식 | 구성 | 프로세스 | 상태 |
| --- | --- | --- | --- |
| **A. mcpo (OpenAPI)** | Open WebUI → mcpo(:8766) → wiki-mcp | 2개 | **권장** — 충분히 검증됨 |
| **B. MCP 직접** | Open WebUI → wiki-mcp(:8765/mcp) | 1개 | 더 단순. 엔드포인트 검증됨 |

---

## 1. 서비스 기동

### 방식 A — mcpo (권장)

```bash
cd <번들 경로>
./run-wiki-mcp.sh mcpo          # :8766 에서 REST 브리지 기동
```

기동 확인:

```bash
curl -s http://localhost:8766/openapi.json | python3 -c "import sys,json; print(len(json.load(sys.stdin)['paths']), '개 도구')"
# → 15 개 도구
```

### 방식 B — MCP 직접 (mcpo 불필요)

```bash
export WIKI_MCP_TRANSPORT=http
export WIKI_MCP_HOST=127.0.0.1
export WIKI_MCP_PORT=8765
export WIKI_MCP_API_KEY=<임의의 키>     # 미설정 시 무인증 — 127.0.0.1 외 바인딩 금지
./run-wiki-mcp.sh serve
# → Streamable HTTP endpoint: http://127.0.0.1:8765/mcp
```

### Open WebUI

```bash
export HF_HUB_OFFLINE=1 OFFLINE_MODE=1
open-webui serve                # http://localhost:8080
```

---

## 2. Open WebUI에 도구 서버 등록

### 2-1. UI에서 등록 (기본)

**Settings → Tools → Add Tool Server** 에서 아래 값을 입력합니다.

| 방식 A (mcpo) | 값 |
| --- | --- |
| URL | `http://localhost:8766` |
| Type | `openapi` |
| Auth | Bearer |
| Key | `.env`의 `WIKI_MCPO_KEY` 값 (기본값 없음) |

| 방식 B (MCP 직접) | 값 |
| --- | --- |
| URL | `http://127.0.0.1:8765/mcp` |
| Type | `mcp` |
| Key | `WIKI_MCP_API_KEY` 로 설정한 값 |

> Docker로 Open WebUI를 띄웠다면 `localhost` 대신 **`host.docker.internal`** 을 쓰세요.

### 2-2. 환경변수로 자동 등록 (장치 여러 대일 때)

Open WebUI는 `TOOL_SERVER_CONNECTIONS` 환경변수(JSON 배열)로 도구 서버를 **기동 시 자동 등록**합니다.
장치마다 UI를 클릭할 필요가 없어집니다.

```bash
export TOOL_SERVER_CONNECTIONS='[{
  "url": "http://localhost:8766",
  "path": "openapi.json",
  "type": "openapi",
  "auth_type": "bearer",
  "key": "<WIKI_MCPO_KEY>"
}]'
open-webui serve
```

필드는 Open WebUI의 `ToolServerConnection` 스키마를 따릅니다:
`url`, `path`, `type`(`openapi`|`mcp`), `auth_type`, `key`, `headers`.

---

## 3. 동작 확인 (체크리스트)

순서대로 통과하면 연동 완료입니다.

**① 브리지가 도구를 노출하는가** (방식 A)

```bash
curl -s -H "Authorization: Bearer $WIKI_MCPO_KEY" \
  -X POST http://localhost:8766/get_wiki_stats -H "Content-Type: application/json" -d '{}'
# → 노트 수·링크 수·도메인 통계가 반환되어야 함
```

**② 인증이 걸려 있는가** (보안)

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST http://localhost:8766/get_wiki_stats -H "Content-Type: application/json" -d '{}'
# → 401 이어야 정상 (무인증 접근 차단)
```

**③ Open WebUI가 도구를 인식하는가**
채팅 입력창의 도구(⚙️/🔧) 목록에 **15개 도구**가 보이면 등록 성공입니다.

**④ 실제로 도구가 호출되는가**
채팅에 다음과 같이 입력합니다.

```text
get_wiki_stats 도구로 위키 현황을 알려줘
search_wiki 로 "위키"를 검색해줘
```

→ 모델이 도구를 호출하고 결과를 인용해 답하면 **연동 완료**입니다.

---

## 4. 일상 사용

### 지식 넣기

```bash
# guardian 번들: watch(LaunchAgent dev.guardian.wiki-watch)가 이미 돌고 있어 넣기만 하면 됩니다
cp 보고서.pdf ~/llm-wiki/raw/

# 구 방식(단독 번들): 번들 폴더에서 watch 데몬을 직접 띄웁니다
cp 보고서.pdf raw/
./run-wiki-mcp.sh watch
```

원문을 raw/ 에 넣으면 LLM이 자동으로 노트화합니다.

- 지원: 텍스트, PDF/Word/Excel/PowerPoint/HTML, 이미지(OCR)
- 긴 문서는 여러 원자 노트로 자동 분할되고 서로 `[[id]]`로 링크됩니다
- 설정은 [`../INSTALL.md`](../INSTALL.md) 7-6 ~ 7-9 참조

### 채팅에서 활용

| 하고 싶은 것 | 이렇게 말하면 됩니다 |
| --- | --- |
| 검색 | "search_wiki로 GraphRAG 관련 노트 찾아줘" |
| 원문 읽기 | "read_note로 `rag` 노트 내용 보여줘" |
| 관련 탐색 | "find_related로 `rag`와 연결된 노트들 알려줘" |
| 노트 작성 | "이 내용을 create_note로 `concept` 양식에 맞춰 정리해줘" |
| 현황 파악 | "get_wiki_stats로 위키 규모 알려줘" |
| 원문 변환 | "ingest_raw로 raw 폴더의 문서를 노트로 만들어줘" |

도구 15개 전체 목록은 [`../INSTALL.md`](../INSTALL.md) 6장을 참조하세요.

### 문서(docx/pptx/xlsx) 생성

채팅에서 **Word 보고서·회의록, PowerPoint 발표자료, Excel 표**를 만들어 다운로드하려면
별도의 네이티브 Tool "문서 생성기"를 등록합니다. 등록·사용법은
[`DOCUMENT-TOOL.md`](DOCUMENT-TOOL.md)를 참조하세요. (wiki-mcp와 독립적으로 동작)

### 오프라인 Claude Code와 문서 skill (`claude-lms`)

터미널에서 `claude-lms`를 실행하면 Claude Code가 LM Studio의 gemma로 동작합니다. 인터넷은 쓰지 않습니다.
번들에는 한글·오피스 문서를 만드는 skill 네 개가 함께 설치됩니다(`~/.claude/skills/`).

| skill | 하는 일 |
| --- | --- |
| `hwpx` | 한글 문서 읽기, Markdown으로 새 문서 만들기, 누름틀 양식 채우기, 검증 |
| `docx` · `xlsx` · `pptx` | Markdown으로 Word·Excel·PowerPoint 파일 만들기, 기존 파일 읽기 |

```bash
claude-lms -p "/docx 주간 보고서를 워드로 만들어 줘. 추진 실적 3개와 예산 표 포함" --allowedTools "Bash,Read,Write,Skill"
```

- **skill 이름을 직접 지목하세요.** gemma는 요청만 보고 알맞은 skill을 스스로 고르지 못할 때가 많습니다. `/hwpx …`, `/docx …`처럼 슬래시 명령으로 부르면 확실합니다.
- `-p`로 쓸 때는 `Write`도 허용하세요. 허용하지 않으면 저장이 거부되어 변환이 `ERROR 파일 없음`으로 끝날 수 있습니다.
- claude-lms는 실행할 때 **skill-guard hook**을 붙입니다(`CLAUDE_LMS_SKILL_GUARD=0`을 주거나 `--settings`를 직접 지정하면 붙이지 않습니다). 같은 skill을 되풀이해 부르거나, 오피스 파일을 글자로 직접 쓰거나, 안내만 읽고 멈추면 hook이 막고 실행할 명령을 알려 줍니다. `~/.claude/settings.json`은 건드리지 않습니다.
- skill은 이렇게 직접 실행할 수도 있습니다(모델이 쓰는 명령과 같습니다): `~/.claude/skills/docx/scripts/docx from-md ./주간보고.md`

자세한 사용법과 제한은 [`CLAUDE-LMS-MANUAL.md`](CLAUDE-LMS-MANUAL.md)(§3 claude-lms, §3.4 skill-guard, §5 hwpx, §11 오피스 skill)를 보세요.
설계와 실전 시험 기록은 [`CLAUDE-LMS-SKILLS.md`](dev/CLAUDE-LMS-SKILLS.md)(개발 문서, 설치본에 없음)에 있습니다.

### (선택) 큰 모델: llm-router

LAN에 Spark(vLLM 서버)가 있으면 llm-router를 통해 claude-lms가 더 큰 모델을 쓸 수 있습니다.
라우터는 운영 Mac의 `127.0.0.1:1240`에서 요청의 모델 이름을 보고 Spark나 LM Studio로 보냅니다.
Spark가 안 되면 LM Studio로 넘어가므로, Spark가 없어도 claude-lms는 그대로 동작합니다.

| 모델 이름 | 목적지 |
| --- | --- |
| `spark-large` | Spark가 지금 서빙 중인 큰 모델. Spark가 다운이면 로컬 |
| `local-fast` | 로컬 LM Studio의 gemma |

라우터를 켜면(`~/.config/claude-lms/env`의 `CLAUDE_LMS_ROUTER=http://127.0.0.1:1240`) claude-lms는 주 모델과 하위 에이전트를 `spark-large`로, 가벼운 백그라운드 호출을 `local-fast`로 보냅니다.

```bash
spark-model status                     # 지금 Spark 모델과 상태
spark-model use gpt-oss-120b --wait    # 다른 프로필로 교체 (몇 분 걸림)
spark-model default                    # 기본 프로필로 되돌리기
```

- 응답 헤더 `X-Route`가 실제로 간 곳(`spark`, `local`, `local (spark-down)`, `local (retry)`)을 알려 줍니다.
- 키트 설치 때 `--with-router`(파일만) 또는 `--router-load`(파일 + 서비스 시작)를 줘야 들어갑니다. 기본 설치에는 없습니다.
- 설치 절차, 장애 시 동작, 보안은 [`LLM-ROUTER.md`](LLM-ROUTER.md)를 보세요.

---

## 5. 문제 해결

| 증상 | 원인 / 조치 |
| --- | --- |
| Open WebUI에 도구가 안 보임 | mcpo 미기동 → `lsof -i :8766` 으로 확인. 또는 등록 URL/키 불일치 |
| 도구 호출 시 401 | Key 불일치 — `.env`의 `WIKI_MCPO_KEY`와 등록한 Key가 같아야 함 |
| Docker에서 연결 실패 | `localhost` → **`host.docker.internal`** 로 변경 |
| 검색 결과 0개 | `wiki/`가 비었거나 인덱싱 전 → 노트 추가 후 `reindex` 도구 호출 |
| 모델이 도구를 안 부름 | 도구 이름을 직접 지목해 요청 (예: "search_wiki로 …"). 도구 사용을 지원하는 모델인지 확인 |
| 첫 기동이 느림/멈춤 | 외부 모델 다운로드 시도 → `HF_HUB_OFFLINE=1 OFFLINE_MODE=1` 설정 |
| 포트 충돌 | `WIKI_MCPO_PORT=<포트> ./run-wiki-mcp.sh mcpo` / `open-webui serve --port <포트>` |

---

## 6. 검증 현황 (이 매뉴얼의 근거)

| 항목 | 상태 |
| --- | --- |
| mcpo가 15개 도구를 OpenAPI로 노출 | ✅ 실측 |
| Bearer 인증 동작 / 무인증 401 차단 | ✅ 실측 |
| 도구 실호출 (`search_wiki` 등) | ✅ 실측 |
| wiki-mcp Streamable HTTP(`/mcp`) 응답 | ✅ 실측 |
| `TOOL_SERVER_CONNECTIONS` 스키마 | ✅ 소스 확인 |
| **Open WebUI UI 등록 → 채팅 호출** | **장치별 확인 필요** (3장 체크리스트) |

UI 등록은 장치·계정마다 1회 수행하는 절차라, 이 문서의 체크리스트로 대체합니다.
