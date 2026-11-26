# raw — 원문 투입 디렉토리

여기에 원문 파일을 넣으면 watch 데몬(LaunchAgent `dev.guardian.wiki-watch`)이
LLM으로 위키 노트를 자동 생성합니다.

지원 형식: 텍스트(`.txt`/`.md`/…) + **문서(`.pdf`/`.docx`/`.pptx`/`.xlsx`/`.html`)** + **이미지(`.png`/`.jpg`)**.
문서는 오프라인으로 텍스트를 추출하고, **스캔 PDF·이미지는 Apple Vision OCR**로 인식합니다(모두 오프라인).

- **하위 폴더로 정리해 넣어도 됩니다** — 재귀적으로 스캔합니다
  (예: `raw/anthropic/api/concepts/*.md`)
- 추출 원문 전체 → `wiki/sources/concepts/source-*.md`에 먼저 보존 (LLM 미사용)
- 짧은 원문 → 파생 노트 1개. **긴 원문(`WIKI_INGEST_MAX_CHARS` 초과)은 여러 원자 노트로 자동 분할**
- 파생 노트는 원문에 실제 존재하는 인용 근거와 Source 링크가 있어야 생성됨
- 성공한 원문 → `raw/.processed/` 로 이동 (**폴더 구조 보존**: `raw/a/b.md` → `.processed/a/b.md`)
- 실패한 원문 → `raw/.failed/` 로 이동 (사유는 watch 로그 참고)
- `README.md`·숨김 파일·`.processed`/`.failed` 하위는 원문으로 취급하지 않습니다

수동 실행: `ingest_raw` MCP 도구 호출 (watch 없이도 즉시 변환).

자동 변환은 guardian 설치 때 이미 활성화되어 있습니다. 설정 파일은 `~/llm-wiki/.env`입니다:

- `WIKI_INGEST_MODEL=gemma-4-e4b-it-mlx` — LM Studio(`http://127.0.0.1:1234`)의 채팅·변환 모델
- `WIKI_INGEST_API_KEY`는 비워 둬도 됩니다. LM Studio는 로컬이라 키가 필요 없습니다.

> 이 디렉토리는 wiki 인덱싱 대상이 아닙니다(노트가 아님).
