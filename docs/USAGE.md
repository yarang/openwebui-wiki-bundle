# 실사용 매뉴얼 — 설치 이후 장치별 연동·검증

`install.sh`로 설치를 마친 **각 장치에서** 수행하는 절차입니다.
Open WebUI 채팅에서 wiki 도구를 실제로 쓸 수 있게 만드는 것이 목표입니다.

> 설치 자체는 [`../INSTALL.md`](../INSTALL.md)를 참조하세요.
> 이 문서는 **설치 후 연결·검증·사용**만 다룹니다.

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
# 원문을 raw/ 에 넣으면 LLM이 자동으로 노트화 (watch 데몬 기동 시)
cp 보고서.pdf raw/
./run-wiki-mcp.sh watch
```
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
