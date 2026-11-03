# wiki-mcp (번들 소스)

LLM Wiki를 [MCP](https://modelcontextprotocol.io/) tool로 노출하는 서버입니다.
이 디렉토리는 **오프라인 번들에 포함된 wiki-mcp 소스**이며, 번들 루트에서
**editable(`-e`)로 설치**되어 소스 수정이 즉시 반영됩니다.

## 설치·설정·사용법

번들 최상위 **`INSTALL.md`** 를 참조하세요. 이 문서가 단일 기준(single source of truth)입니다.

| 내용 | 위치 |
| --- | --- |
| 오프라인 설치 | `INSTALL.md` 3장 (`install.sh` 원커맨드) |
| 실행 (serve / mcpo / watch) | `INSTALL.md` 4장, 번들 루트 `run-wiki-mcp.sh` |
| MCP 클라이언트 등록 | `INSTALL.md` 5장 |
| 노출 도구 목록 | `INSTALL.md` 6장 |
| 데이터 넣기·노트 양식·raw 자동 변환·청킹·문서추출·OCR | `INSTALL.md` 7장 |
| 환경 변수 | `INSTALL.md` 7장 + 번들 루트 `.env.example` |

> 실행은 번들 루트의 `run-wiki-mcp.sh` 를 사용하세요(wiki/raw/템플릿 경로와 오프라인
> 모드가 자동 주입됩니다). 이 디렉토리 안에 별도 실행 스크립트는 두지 않습니다.

## 소스 구성

```text
src/wiki_mcp/
├── server.py      # FastMCP 서버 — MCP tool 정의/등록
├── indexer.py     # 인덱싱 + 하이브리드 검색 (BM25 / 임베딩)
├── graph.py       # [[id]] 링크 그래프
├── writer.py      # 노트 생성·수정·삭제 (검증·백업·템플릿)
├── ingest.py      # raw 원문 → 노트 변환 (LLM, 아웃라인→작성 청킹)
├── extract.py     # 문서 텍스트 추출 (PDF/docx/pptx/xlsx/html) + OCR 연동
├── watch.py       # 파일 감시 — 자동 재인덱싱 + raw 자동 변환
├── config.py      # 환경 변수 / 경로 해석
└── auth.py        # HTTP 모드 Bearer 인증

examples/sample-wiki/   # WIKI_PATH 미지정 시 폴백용 예제 (번들에서는 미사용)
```

경로는 모두 **번들 루트 기준으로 자동 해석**되므로, 번들을 어느 위치에 풀어도 동작합니다.
