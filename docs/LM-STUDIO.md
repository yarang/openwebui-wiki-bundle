# Open WebUI + Wiki MCP에서 LM Studio 사용

LM Studio의 OpenAI 호환 API를 Open WebUI의 채팅 모델과 내장 Knowledge 임베딩,
Wiki MCP의 hybrid 검색에서 공동으로 사용하는 방법을 설명합니다.

## 1. 구성

```text
LM Studio :1234
├── /v1/chat/completions  ─▶ Open WebUI 채팅·raw ingest 생성 LLM
└── /v1/embeddings       ─▶ Open WebUI Knowledge
                         └▶ Wiki MCP hybrid 검색
```

Open WebUI와 Wiki MCP는 같은 임베딩 서버와 모델을 공유할 수 있지만 벡터 DB는
각각 유지합니다.

- Open WebUI: 자체 Knowledge vector DB
- Wiki MCP: `wiki-data/chroma`

## 2. LM Studio 준비

1. LM Studio에 채팅 모델과 임베딩 모델을 설치합니다.
2. 필요한 모델을 로드합니다.
3. **Local Server**를 기본 포트 `1234`로 실행합니다.
4. OpenAI-compatible API가 활성화됐는지 확인합니다.

모델 목록 확인:

```bash
curl -s http://localhost:1234/v1/models
```

응답의 모델 `id`를 이후 설정에 정확히 사용해야 합니다.

## 3. Open WebUI 채팅 모델 연결

Open WebUI에서 다음 메뉴로 이동합니다.

```text
Admin Settings → Connections → OpenAI → Add Connection
```

설정값:

```text
URL: http://localhost:1234/v1
API Key: lm-studio
```

LM Studio에서 인증을 사용하지 않더라도 Open WebUI 입력을 위해 임의의 비밀이 아닌
값을 사용할 수 있습니다.

## 4. Open WebUI 내장 Knowledge 임베딩

LM Studio에 `/v1/embeddings`를 지원하는 임베딩 모델을 로드합니다. 채팅 모델만
로드한 상태에서는 내장 Knowledge 검색이 동작하지 않습니다.

API 검증:

```bash
curl http://localhost:1234/v1/embeddings \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer lm-studio" \
  -d '{
    "model": "<LM Studio 모델 ID>",
    "input": "한국어 지식 검색 테스트"
  }'
```

`data[0].embedding` 배열이 반환되어야 합니다.

Open WebUI에서 다음 메뉴를 설정합니다.

```text
Admin Settings → Settings → Documents
Embedding Model Engine: OpenAI
Base URL: http://localhost:1234/v1
API Key: lm-studio
Embedding Model: <LM Studio 모델 ID>
```

`.env`로 설정할 수도 있습니다.

```bash
RAG_EMBEDDING_ENGINE=openai
RAG_OPENAI_API_BASE_URL=http://localhost:1234/v1
RAG_OPENAI_API_KEY=lm-studio
RAG_EMBEDDING_MODEL=<LM Studio 모델 ID>

RAG_EMBEDDING_MODEL_AUTO_UPDATE=false
RAG_RERANKING_MODEL=
RAG_RERANKING_MODEL_AUTO_UPDATE=false
```

Open WebUI의 Documents 설정은 DB에 저장될 수 있습니다. 기존 UI 설정이 있으면
환경변수와 함께 관리자 화면의 실제 적용값도 확인합니다.

## 5. Wiki MCP 임베딩 공유

Open WebUI와 같은 LM Studio 모델을 Wiki MCP에도 지정합니다.

```bash
EMBEDDING_DISABLED=0
EMBEDDING_PROVIDER=openai
OLLAMA_URL=http://localhost:1234
EMBEDDING_MODEL=<동일한 LM Studio 모델 ID>
EMBEDDING_API_KEY=lm-studio
```

`OLLAMA_URL`은 기존 호환성을 위해 유지된 변수명입니다.
`EMBEDDING_PROVIDER=openai`일 때는 OpenAI 호환 API의 base URL로 사용됩니다.

## 6. raw ingest 생성 모델

LM Studio의 채팅 모델로 raw 원문을 Source·원자 노트로 변환하려면 다음을 설정합니다.

```bash
WIKI_INGEST_ENABLED=1
WIKI_INGEST_URL=http://localhost:1234/v1/chat/completions
WIKI_INGEST_MODEL=<LM Studio 채팅 모델 ID>
WIKI_INGEST_API_KEY=lm-studio
```

임베딩 모델과 채팅 모델은 역할이 다릅니다.

| 모델 | 역할 |
| --- | --- |
| 채팅 모델 | 답변 생성, raw 원자 노트 작성 |
| 임베딩 모델 | Knowledge 및 Wiki 관련 문서 검색 |

## 7. Docker 주소

Open WebUI가 호스트에서 직접 실행되면 `localhost:1234`를 사용합니다. Docker에서
실행되면 `localhost`는 컨테이너 자신을 가리키므로 다음 주소를 사용합니다.

```text
http://host.docker.internal:1234/v1
```

Docker 환경의 Open WebUI 설정 예:

```bash
RAG_OPENAI_API_BASE_URL=http://host.docker.internal:1234/v1
```

Wiki MCP도 Docker 안에서 실행한다면 `OLLAMA_URL`과 `WIKI_INGEST_URL`에 같은 호스트
변환을 적용합니다.

## 8. 모델 변경과 재인덱싱

임베딩 모델이 달라지면 벡터 차원과 공간이 달라질 수 있으므로 기존 인덱스를 혼용하면
안 됩니다.

### Open WebUI

```text
Admin Settings → Settings → Documents → Reindex
```

- Knowledge에 등록된 문서는 전체 재인덱싱합니다.
- 채팅에 직접 첨부했던 파일은 재인덱싱 대상이 아니므로 다시 업로드합니다.

### Wiki MCP

1. `wiki/`를 백업합니다.
2. 실행 중인 Wiki MCP와 watcher를 중지합니다.
3. `wiki-data/`의 기존 파생 인덱스를 제거합니다.
4. 새 모델 설정으로 Wiki MCP를 기동하고 전체 재인덱싱합니다.

`wiki/`는 원본이고 `wiki-data/`는 재생성 가능한 파생 데이터입니다. `wiki/`를 삭제하면
안 됩니다.

## 9. 에어갭 운영

- LM Studio 애플리케이션과 모델 파일을 인터넷 연결 장비에서 미리 준비합니다.
- 대상 장비에 모델을 반입한 후 네트워크를 차단하기 전에 Local Server와 두 API를
  검증합니다.
- Open WebUI는 다음 설정을 유지합니다.

```bash
OFFLINE_MODE=true
HF_HUB_OFFLINE=1
RAG_EMBEDDING_MODEL_AUTO_UPDATE=false
RAG_RERANKING_MODEL_AUTO_UPDATE=false
```

이 설정은 Hugging Face 자동 다운로드를 차단하지만 `localhost`의 LM Studio API 호출은
막지 않습니다.

## 10. 문제 해결

| 증상 | 확인 사항 |
| --- | --- |
| 채팅 모델이 안 보임 | `/v1/models`, OpenAI connection URL, LM Studio 서버 상태 |
| Knowledge 업로드 실패 | 임베딩 모델 로드 여부와 `/v1/embeddings` 응답 |
| `NoneType ... encode` | Documents의 engine/model 설정 불일치 또는 임베딩 서버 미기동 |
| 검색 결과가 이상함 | 임베딩 모델 변경 후 전체 Reindex 여부 |
| Wiki dense 결과 없음 | `EMBEDDING_DISABLED=0`, 모델 ID, `wiki-data` 재구축 여부 |
| Docker 연결 실패 | `localhost` 대신 `host.docker.internal` 사용 |
| 401 오류 | LM Studio 인증 설정과 API Key 일치 여부 |

## 11. 권장 운영 순서

1. LM Studio에서 임베딩 모델 로드 및 `/v1/embeddings` 확인
2. LM Studio에서 채팅 모델 로드 및 `/v1/chat/completions` 확인
3. Open WebUI Documents 임베딩 설정
4. Wiki MCP 동일 임베딩 모델 설정
5. Open WebUI Knowledge Reindex
6. Wiki MCP 인덱스 재구축
7. 같은 한국어 질의로 두 검색 경로 검증

