# 지식 구축 가이드 — 실제 위키 만들기

현재 `wiki/`에는 **예제 노트 4개**만 있습니다. 이 문서는 실제 지식을 쌓아
검색·활용 가능한 위키로 키우는 방법과, 그 과정에서 마주칠 문제를 다룹니다.

> 도구·설정 레퍼런스는 [`../INSTALL.md`](../INSTALL.md) 7장, 사용법은 [`USAGE.md`](USAGE.md).

---

## 1. 원칙 — 원자 노트

**노트 1개 = 개념 1개.** 이 원칙이 검색 품질과 링크 그래프의 가치를 결정합니다.

| 좋음 | 나쁨 |
| --- | --- |
| `rag` — RAG의 정의·원리·장단점을 한 노트에 | `rag-definition`, `rag-benefits`, `rag-examples`로 쪼갬 (중복 서술) |
| `fine-tuning` — 파인튜닝 개념 | `llm-methods` — RAG와 파인튜닝을 한 노트에 (원자성 위반) |

- **너무 잘게 쪼개면**: 같은 내용이 여러 노트에 반복되고, 검색이 중복 결과를 냄
- **너무 뭉치면**: 링크 그래프가 무의미해지고, 부분 검색이 안 됨
- 기준: **"이 노트만 읽어도 하나의 개념이 이해되는가"**

원자 노트는 원문의 대체물이 아니라 파생 지식입니다. ingest는 먼저 추출 원문 전체를
`wiki/sources/concepts/source-*.md`에 보존하고, 원자 노트에는 해당 Source 링크와
원문에서 실제로 확인된 인용을 기록합니다. 따라서 요약 결과가 의심스러우면 항상
Source 노트로 돌아가 확인할 수 있습니다.

---

## 2. 투입 전략

### 2-1. 소규모 시작 (권장)

처음부터 대량 투입하지 마세요. **문서 2~3개로 품질을 먼저 확인**합니다.

```bash
cp 문서1.pdf raw/
./run-wiki-mcp.sh watch          # 로그를 지켜보며 결과 확인
```

확인할 것:
- 노트 수가 적절한가 (개념 수와 비슷한가, 과분할은 아닌가)
- 태그가 주제 키워드인가 (노트 id가 태그에 들어가지 않았는가)
- 상호 링크가 형성됐는가
- 원문에 없는 내용을 지어내지 않았는가
- 각 파생 노트의 `## 원문 근거` 인용이 주장을 실제로 뒷받침하는가
- `source_url: wiki://source-...`와 Source 링크가 존재하는가

문제가 있으면 **3장(품질 튜닝)** 을 먼저 적용한 뒤 본격 투입합니다.

### 2-2. 도메인별 정리

`wiki/<도메인>/concepts/<id>.md` 구조를 씁니다.

```bash
# create_note 호출 시 domain 지정 (또는 자동 추정)
create_note(id="graphrag", title="GraphRAG", domain="rag", ...)
# → wiki/rag/concepts/graphrag.md
```

도메인을 명시하면 자동추정보다 예측 가능합니다. `list_domains` 도구로 현황을 봅니다.

### 2-3. 기존 문서 대량 이관

이미 마크다운 문서가 있다면 LLM 변환 없이 바로 넣을 수 있습니다.

```bash
# 각 파일에 frontmatter id 만 추가하면 노트가 됩니다
cp -r 기존문서/*.md wiki/legacy/
# 각 파일 상단에:  ---\nid: <kebab-case>\ntitle: "..."\n---
# 그 후
reindex   # 도구 호출
```

`[[id]]` 링크를 붙이면 그래프에 편입됩니다.

---

## 3. 품질 튜닝

실측에서 드러난 문제와 해결책입니다.

### 3-1. 과분할 (가장 흔함)

**증상**: 2개 개념 문서에서 8개 노트가 생성되고, 같은 내용이 반복 서술됨.

**해결**: 아웃라인 프롬프트에 이미 억제 규칙이 들어가 있습니다
(`ingest.py`의 `_outline_prompts`). 그래도 과분할되면:

```bash
export WIKI_INGEST_MAX_NOTES=5        # 문서당 노트 상한을 낮춤
export WIKI_INGEST_MAX_CHARS=12000    # 창을 키워 아웃라인이 전체를 보게 함
```

> 창이 작으면 각 창이 독립적으로 노트를 뽑아 **과분할이 심해집니다.**
> 문서가 모델 컨텍스트에 들어간다면 창을 크게 잡는 편이 품질에 유리합니다.

**실측**: 튜닝 전 8개 노트(중복 서술) → 튜닝 후 2개 노트(개념 수와 일치), 처리 시간도 314초 → 111초로 감소.

### 3-2. 모델 선택

| 모델 | 노트당 시간 | 품질 |
| --- | --- | --- |
| 로컬 12B (`gemma-4-12b`) | ≈ 77초 | 높음 |
| 로컬 소형 (`gemma-4-e4b`) | ≈ 46초 | 실용적 |

**처리 시간 = 아웃라인 1회 + 노트당 1회**. 노트 5개면 6회 호출 ≈ 5분(소형 모델).
대량 투입 시 소형 모델을 쓰고, 중요한 문서만 큰 모델로 다시 돌리는 방식이 현실적입니다.

기존 노트 연결은 모델이 Wiki 전체를 이해한다고 가정하지 않습니다. ingest가 먼저 로컬
BM25/hybrid 검색으로 관련 후보를 최대 8개 고르고, 모델은 그 후보 안에서만 링크를
선택합니다. 후보에는 ID뿐 아니라 제목과 태그도 포함됩니다. 모델이 후보 밖 ID를
만들어도 실제 링크에는 반영되지 않습니다. 이 방식은 추가 LLM 호출 없이 작은
컨텍스트에서 동작하지만, 검색 단계가 놓친 관련 노트까지 모델이 찾아내지는 못합니다.

### 3-3. 양식 강제

```bash
export WIKI_INGEST_TEMPLATE=concept   # 모든 생성 노트에 양식 적용
```
미설정 시 LLM이 자유 구조로 작성합니다. 일관성이 필요하면 반드시 설정하세요.
양식 자체는 `wiki/.templates/concept.md`를 편집해 바꿉니다(재설치 불필요).

---

## 4. 유지보수

정기적으로 아래 도구를 돌려 위키 건강도를 점검합니다.

| 도구 | 무엇을 잡는가 | 조치 |
| --- | --- | --- |
| `find_broken_links` | 존재하지 않는 `[[id]]` 참조 | 노트 생성 또는 링크 수정 |
| `get_wiki_stats` | 노트 수, 링크 수, 허브 노트 | 고아 노트(링크 0) 발견 |
| `verify_citations` | LLM 답변의 인용이 실제 노트인지 | 환각 인용 탐지 |
| `list_domains` | 도메인별 노트 분포 | 편중 확인 |
| `suggest_new_note` | 새 주제의 권장 ID·경로·cross-link | 중복 노트 생성 방지 |

**고아 노트**(들어오는 링크도 나가는 링크도 없는 노트)는 검색으로만 닿을 수 있어
그래프의 가치를 떨어뜨립니다. `add_link` 도구로 연결하세요.

---

## 5. 확장 (선택) — 의미 검색

기본값은 **BM25-only**(키워드 검색)입니다. 오프라인·경량이지만
"같은 뜻 다른 표현"을 못 잡습니다. 임베딩을 켜면 BM25 + dense를
**하이브리드(RRF fusion)** 로 합쳐 검색합니다.

임베딩 백엔드는 두 가지를 지원합니다.

### LM Studio (OpenAI 호환) — 실측 검증됨

```bash
export EMBEDDING_DISABLED=0
export EMBEDDING_PROVIDER=openai                              # OpenAI 호환 API
export OLLAMA_URL=http://localhost:1234                       # base URL (변수명은 OLLAMA지만 재사용됨)
export EMBEDDING_MODEL=text-embedding-nomic-embed-text-v1.5
# EMBEDDING_API_KEY 는 LM Studio(로컬)에서는 불필요
```

**실측**: `text-embedding-nomic-embed-text-v1.5` → **768차원**, 노트 4개 임베딩 0.5초,
하이브리드 검색이 BM25와 다른 랭킹을 정상 산출.

### Ollama

```bash
export EMBEDDING_DISABLED=0
export EMBEDDING_PROVIDER=ollama       # 기본값
export OLLAMA_URL=http://localhost:11434
export EMBEDDING_MODEL=bge-m3          # 한국어에 강함, 1024차원
```
Ollama에 모델을 미리 받아둬야 합니다 (에어갭이면 사전 반입).

### ⚠️ 함정 1 — 켜도 벡터가 안 쌓인다

인덱서는 **내용이 바뀐 노트만 임베딩**합니다(`wiki-data/index_cache.json`으로 판단).
BM25-only로 운영하다 임베딩을 켜면, 캐시가 "변경 없음"이라 판단해 **임베딩 큐가 비고
벡터 0개인 채로 조용히 넘어갑니다.**

```bash
rm wiki-data/index_cache.json     # 캐시를 비워야 전체 재임베딩됨
```

확인 방법:

```bash
python -c "
import chromadb; from chromadb.config import Settings
c=chromadb.PersistentClient(path='wiki-data/chroma', settings=Settings(anonymized_telemetry=False))
print('벡터:', c.get_or_create_collection('wiki').count(), '개')"
```

### ⚠️ 함정 2 — 모델을 바꾸면 차원이 충돌한다

ChromaDB 컬렉션은 차원이 고정됩니다. `nomic`(768) ↔ `bge-m3`(1024)처럼 **차원이 다른
모델로 바꾸면 로드 에러**가 납니다. 모델을 바꿀 때는:

```bash
rm -rf wiki-data/          # 인덱스 전체 초기화 (노트는 wiki/에 있으므로 안전)
```
또는 `WIKI_DATA_DIR`를 모델별로 분리하세요.

> **성능 주의**: 노트가 많으면 최초 임베딩에 시간이 걸립니다(노트당 1회 임베딩 호출).
> 이후에는 변경된 노트만 갱신하므로 빠릅니다.

---

## 6. 로드맵 — 아직 없는 것

| 항목 | 현재 | 필요해지는 시점 |
| --- | --- | --- |
| 중복 노트 탐지 | 없음 (아웃라인의 id 누적으로 부분 방지) | 노트 100개 이상 |
| 노트 병합 도구 | 없음 (수동) | 과분할된 노트 정리 시 |
| 변환 재시도 | 없음 (`raw/.failed/`에 방치) | 대량 투입 시 |
| 변환 비동기화 | watch가 변환 중 블록 | 대량 투입 시 |
| 노트 버전 관리 | `.bak` 파일만 | 협업 시 (git으로 `wiki/` 관리 권장) |

`wiki/`를 **별도 git 저장소로 관리**하면 노트 이력·협업·롤백이 해결됩니다.
번들 저장소와 분리하는 것을 권장합니다(데이터와 코드의 분리).
