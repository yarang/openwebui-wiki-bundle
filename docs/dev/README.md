# 개발 문서 (docs/dev)

이 폴더는 현장 설치·운영 문서가 아니라 **개발·검증 기록**을 담는다. 공개본에는 들어가고, 현장 번들에는 실리지 않는다
(`guardian/build-merged-bundle.sh` 의 `EXCL_DOCS`). 공개하지 않는 문서는 `../internal/`에 둔다.

## 문서 목록

| 문서 | 설명 |
| --- | --- |
| [CLAUDE-LMS-SKILLS.md](CLAUDE-LMS-SKILLS.md) | 오피스 skill(hwpx·docx·xlsx·pptx)과 skill-guard의 설계·구현 상태·실측 기록 |
| [TESTING.md](TESTING.md) | wiki-mcp·guardian 인수 테스트 전략과 실행법 |
| [LLM-ROUTER-TESTING.md](LLM-ROUTER-TESTING.md) | llm-router·Spark 코드의 단위 테스트 묶음과 실행법, 직접 돌려 본 결과 |
| [SPARK-BENCH-REPORT.md](SPARK-BENCH-REPORT.md) | DGX Spark 성능 측정 보고서: 동시 요청별 처리량·지연, 수강 인원 환산, 권고 |

## 하위 폴더

| 폴더 | 설명 |
| --- | --- |
| [bench/](bench/) | Spark 벤치 결과 JSON(1차·재벤치). [SPARK-BENCH-REPORT.md](SPARK-BENCH-REPORT.md)가 참조한다. |
| [diagrams/](diagrams/) | 이 폴더 문서들의 mermaid 원본(`.mmd`)과 SVG. 공용 그림은 [`../diagrams/`](../diagrams/)에 있다. |
