# 테스트 전략

## 현재 상태

| 항목 | 현재 |
| --- | --- |
| 코드 규모 | wiki-mcp 9개 모듈 |
| 자동화 테스트 | **117개** (`wiki-mcp/tests/`) |
| 실행 시간 | **0.3초** — LLM·네트워크·ChromaDB 없이 |
| 커버리지 | graph 100% · ingest 87% · writer 84% · extract 61% |

### 이 테스트가 고정하는 것 — 과거에 실제로 났던 버그들

아래는 모두 **수동 검증으로 우연히** 발견됐던 것들로, 지금은 회귀 테스트가 지킵니다.

| 과거 버그 | 지키는 테스트 |
| --- | --- |
| `concepts/concepts/` 이중 경로 | `test_domain_ending_in_subtype_not_doubled` |
| `raw/README.md`를 원문으로 삼킴 | `test_readme_excluded` |
| `raw/` 하위 폴더 미탐지 | `test_recursive_scan` |
| 아웃라인 과분할(2개념 → 8노트) | `TestPromptRules::test_outline_*` |
| 태그에 노트 id 오염 | `test_write_prompt_forbids_id_in_tags` |
| 템플릿 섹션이 빈 채로 생성 | `test_template_sections_applied` |

### 테스트가 새로 찾아낸 버그

**추출 실패 원문이 `.failed`로 이동하지 않던 문제** — `ingest_file`이 추출 실패 시
이동 로직 **앞에서 early return** 하여, 스캔 PDF·손상 파일이 `raw/`에 영구히 남고
watch 재시작·`ingest_raw` 호출마다 무한 재시도되고 있었습니다
(`raw/README.md`에 문서화된 계약 위반). `test_image_without_ocr_reports_extraction_error`가
잡아냈고 수정 완료.

## 전제 — 오프라인 번들에는 pytest가 없다

`wiki-mcp/pyproject.toml`에 dev 의존성은 선언돼 있지만(`pytest`, `ruff`, `build`),
**`openwebui-packages/`(오프라인 wheel)에는 pytest가 없습니다.**

- **에어갭 대상 장비**: 테스트 불필요 — 운영만 함
- **개발 환경**: 네트워크로 dev 의존성 설치

```bash
uv pip install --python .venv/bin/python -e "wiki-mcp[dev]"   # 네트워크 필요
```

에어갭에서도 테스트를 돌려야 한다면 `pytest`·`pluggy`·`iniconfig` wheel을
`openwebui-packages/`에 추가로 반입하면 됩니다.

---

## 설계상 유리한 점 — 이미 테스트하기 쉽다

LLM 호출이 **주입식**(`complete_fn`)으로 설계돼 있어, **LLM 없이 전 경로를 테스트**할 수 있습니다.

```python
def fake(system, user):
    return '{"id":"x","title":"X","tags":["t"],"body":"본문","links":[]}'

ingest.ingest_text(idx, graph, "원문", complete_fn=fake, ...)   # 네트워크·모델 불필요
```

순수 함수도 많아 단위 테스트 대상이 명확합니다.

---

## 우선순위별 테스트 대상

### P0 — 순수 함수 (빠르고, 버그가 실제로 났던 곳)

| 대상 | 모듈 | 검증할 것 |
| --- | --- | --- |
| `_build_note_path` | `writer` | **회귀**: `domain=concepts` → `concepts/x.md` (이중 중첩 없음), `ai` → `ai/concepts/x.md` |
| `validate_note_id` | `writer` | kebab-case 강제, 한글 거부, 길이 상한 |
| `build_frontmatter` | `writer` | 표준 6필드 + 템플릿 extra 필드, 값 이스케이프 |
| `_fill_sections` | `writer` | `## 제목` 아래 내용 교체, 없는 섹션은 보존(`{{links}}`) |
| `parse_note_json` | `ingest` | 코드펜스/설명문 섞인 LLM 출력에서 JSON 추출, 실패 시 예외 |
| `split_into_windows` | `ingest` | 헤딩 경계 우선, 크기 상한 준수, 작은 조각 병합 |
| `template_section_headings` | `ingest` | `{{links}}` 든 섹션은 제외 |
| `is_ingestable` | `ingest` | **회귀**: `README.md`·숨김 파일 제외, 확장자 필터 |
| `extract_links` / `domain_of` | `indexer`/`graph` | `[[id]]` 추출, 앵커 제거, 도메인 판정 |

### P1 — 쓰기 경로 (안전장치)

| 시나리오 | 기대 |
| --- | --- |
| `create_note` ID 충돌 | `force=False`면 거부, 파일 미변경 |
| `create_note` 템플릿 적용 | frontmatter extra + 섹션 구조 + `{{links}}` 배치 |
| `create_note(sections=...)` | 각 `##` 섹션이 채워짐 (**회귀**: 빈 섹션 방지) |
| `update_note` | `.bak` 백업 생성, `last_updated` 갱신, `append` 모드 |
| `delete_note` | `confirm=True` 없으면 거부, 백업 후 삭제 |
| `dry_run=True` | 파일 시스템 미변경 |

### P2 — 인제스트 (fake LLM)

| 시나리오 | 기대 |
| --- | --- |
| `ingest_text` 단일 노트 | 템플릿·섹션 적용된 노트 생성 |
| `ingest_long_text` 청킹 | 아웃라인 → 노트별 작성, 형제 `[[id]]` 상호링크 |
| LLM이 깨진 JSON 반환 | `ExtractionError`/`ValueError`로 안전 실패, 파일 미생성 |
| 부분 성공 (3/5 노트) | 1개↑ 성공 시 원문 `.processed/`, 전부 실패 시 `.failed/` |
| ID 충돌 노트 포함 | 해당 노트만 실패, 나머지는 진행 |

### P3 — 문서 추출

| 포맷 | 픽스처 생성 방법 (모두 번들 라이브러리로 가능) |
| --- | --- |
| PDF | `fpdf2`로 생성 |
| 스캔 PDF | `PIL`로 텍스트 이미지 → `fpdf2`로 이미지만 삽입 → OCR 폴백 검증 |
| xlsx | `openpyxl`로 다중 시트 생성 → `## 시트명` + 마크다운 표 |
| pptx | `python-pptx`로 슬라이드 생성 → `## 제목` + 본문 |
| html | 문자열 → 헤딩 매핑, `script` 제거 |
| 빈/스캔 | 최소 길이 미만 → `ExtractionError` |

> OCR 테스트는 **macOS + `ocr/vision-ocr` 바이너리**가 있을 때만 실행하도록 스킵 마킹.

---

## 구조 (구현됨)

```text
wiki-mcp/
  tests/
    conftest.py          # FakeIndex/WikiGraph 픽스처, echo_note(fake LLM)
    test_writer.py       # ID 검증·frontmatter 포맷·경로·CRUD 생애주기
    test_ingest.py       # JSON 방어·청킹·재귀 스캔·인제스트·프롬프트 규칙
    test_extract.py      # 포맷별 추출·OCR 게이트 (픽스처를 코드로 생성)
    test_graph.py        # 링크 그래프 탐색·broken link·허브
```

### 설계 원칙

- **LLM은 주입** — `complete_fn`에 `echo_note(...)`를 넣어 결정적으로 검증.
  네트워크·모델 없이 인제스트 전 경로를 돌린다.
- **`FakeIndex`는 디스크를 rescan** — 실제 indexer의 계약(`notes`/`all_ids`/
  `in_links`/`out_links`/`build`)만 재현. `create → add_link → delete` 흐름이
  실제와 동일하게 동작한다. ChromaDB·임베딩은 테스트 범위 밖.
- **`WikiGraph`는 진짜를 사용** — 흉내내지 않는다(가짜를 검증하는 함정 회피).
- **모든 테스트는 `tmp_path`에서** — 실제 `wiki/`를 건드리지 않는다.
- **문서 추출 라이브러리 미설치 시 skip** — 오프라인 번들에는 모두 포함되므로
  번들 환경에서는 전부 실행된다.

---

## 실행

```bash
# 개발 환경 (네트워크 필요, 최초 1회)
uv pip install --python .venv/bin/python pytest pytest-cov

# 전체 (wiki-mcp/ 에서 실행 — pyproject.toml의 pytest 설정을 사용)
cd wiki-mcp && ../.venv/bin/python -m pytest

# 상세 출력
cd wiki-mcp && ../.venv/bin/python -m pytest -v

# 커버리지
cd wiki-mcp && ../.venv/bin/python -m pytest --cov=wiki_mcp --cov-report=term-missing

# 특정 파일/클래스만
cd wiki-mcp && ../.venv/bin/python -m pytest tests/test_ingest.py::TestPromptRules
```

> `pyproject.toml`의 `[tool.pytest.ini_options]`가 `pythonpath=["src","tests"]`를
> 잡아주므로 별도 설치 없이 `src` 레이아웃과 `conftest` 헬퍼가 import 됩니다.

---

## 진행 상황

| 단계 | 범위 | 상태 |
| --- | --- | --- |
| 1차 | P0 순수 함수 (ID·frontmatter·경로·JSON·청킹) | **완료** |
| 2차 | P1 쓰기 안전장치 (백업·충돌 거부·dry_run) | **완료** |
| 3차 | P2 인제스트 (fake LLM) + 프롬프트 규칙 | **완료** |
| 4차 | P3 추출 (html/xlsx/pptx) + OCR 게이트 | **완료** |
| 5차 | `server.py` MCP 도구 래퍼 · `watch.py` 데몬 | 미착수 |
| 6차 | `indexer.py` 검색·임베딩 (ChromaDB 필요) | 미착수 |

**커버리지 수치보다 "고쳤던 버그가 다시 살아나지 않는 것"**이 우선입니다.
`server.py`/`watch.py`는 얇은 래퍼라 우선순위가 낮고, `indexer.py`의 검색 랭킹은
ChromaDB 픽스처가 필요해 비용 대비 효과가 낮습니다.

## 남은 리스크

- **`indexer.py` 15%** — 임베딩 캐시 함정(`index_cache.json`으로 0벡터가 되는 문제)은
  아직 테스트가 없습니다. 재현하려면 ChromaDB 픽스처가 필요합니다.
- **OCR 실경로** — `vision-ocr` 바이너리 호출은 게이트(바이너리 없음/OCR 미설정)만
  검증합니다. 실제 인식 품질은 macOS + 바이너리 환경에서 수동 확인이 필요합니다.
- **CI 없음** — 현재는 로컬 실행에 의존합니다. Gitea Actions 연결이 다음 후보입니다.
