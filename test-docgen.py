#!/usr/bin/env python3
"""문서 생성기 단독 테스트 — Open WebUI 없이 docx/pptx/xlsx 생성을 검증한다.

사용법:
    .venv/bin/python test-docgen.py
    .venv/bin/python test-docgen.py --theme corporate
    .venv/bin/python test-docgen.py --open    # 생성 후 자동 열기 (macOS)

출력: test-output/ 디렉토리에 샘플 파일 4종 생성.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# document_generator.py 를 import 경로에 추가
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "open-webui-tools"))

from document_generator import (  # noqa: E402
    build_report_docx,
    build_minutes_docx,
    build_slides_pptx,
    build_table_xlsx,
)

TEMPLATE_DIR = str(ROOT / "document-templates")
OUT_DIR = ROOT / "test-output"


# ── 샘플 데이터 ────────────────────────────────────────────────────────

REPORT_BODY = """\
## 1. 개요

본 보고서는 **2026년 2분기** AI 서비스 운영 현황을 정리한 것이다.
주요 지표와 인프라 상태, 개선 과제를 포함한다.

## 2. 핵심 지표

표: 분기별 핵심 지표 (단위: 천 건)
너비: 2, 2, 2, 2

| 지표 | 1Q | 2Q | 증감율 |
|:-----|---:|---:|:-----:|
| 일평균 요청 | 12,500 | 18,300 | +46% |
| 평균 응답시간 | 2.1s | 1.8s | -14% |
| 에러율 | 0.8% | 0.3% | -62% |
| 활성 사용자 | 3,200 | 4,100 | +28% |

## 3. 인프라 현황

표: 서버 리소스 사용률

| 서버 | CPU | 메모리 | 디스크 | 상태 |
|:-----|----:|------:|------:|:----:|
| API-01 | 45% | 62% | 38% | 정상 |
| API-02 | 51% | 58% | 41% | 정상 |
| DB-01 | 38% | 71% | 67% | 주의 |
| GPU-01 | 72% | 80% | 45% | 정상 |

## 4. 개선 과제

1. **DB-01 디스크 확장** — 사용률 67%로 임계치 접근, 8월 중 확대 예정
2. **응답시간 최적화** — 캐싱 도입으로 추가 20% 단축 목표
3. **에러율 모니터링 강화** — 실시간 알림 연동 완료

자세한 내용은 [[llm-monitoring-items]] 및 [[monitoring-plan-setup]] 참고.
"""

MINUTES_AGENDA = """\
- AI 서비스 2분기 운영 결과 검토
- DB 용량 확장 계획 수립 (DB-01 디스크 사용률 67%)
- 응답시간 최적화 방안 논의 (캐싱 전략)
- 다음 분기 모니터링 고도화 방향
"""

MINUTES_DECISIONS = """\
- DB-01 디스크는 8월 첫째 주에 2TB → 4TB 확장 (예산 승인 완료)
- Redis 기반 응답 캐싱 도입, 8월 중 개발 착수
- 모니터링 대시보드를 Grafana로 일원화
"""

ACTION_ITEMS = """\
| 담당 | 내용 | 기한 |
|------|------|------|
| 김개발 | DB-01 디스크 확장 작업 | 2026-08-05 |
| 이연구 | Redis 캐싱 프로토타입 구현 | 2026-08-12 |
| 박운영 | Grafana 대시보드 마이그레이션 | 2026-08-19 |
| 최기획 | 3분기 모니터링 계획서 작성 | 2026-08-26 |
"""

SLIDES_MD = """\
# 2분기 운영 현황

- 일평균 요청 **18,300건** (전분기 대비 +46%)
- 에러율 **0.3%** 로 62% 개선
- 활성 사용자 4,100명 돌파

---

# 인프라 상태

- API 서버: 평균 CPU 48% — 안정
- DB-01 디스크 67% — **확장 필요**
- GPU 서버: 추론 부하 정상

---

# 개선 과제

- DB-01 디스크 4TB 확장 (8월)
- Redis 응답 캐싱 도입 (8월)
- Grafana 대시보드 통합 (8월)
"""

SPREADSHEET = """\
월,요청수,에러수,에러율,평균응답(s)
4월,485000,3880,0.80,2.1
5월,532000,2260,0.42,1.9
6월,536000,1608,0.30,1.7
"""


# ── 메인 ────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="문서 생성기 단독 테스트")
    ap.add_argument("--theme", default="default",
                    help="테마 이름 (default / corporate)")
    ap.add_argument("--org", default="AX 36사업단",
                    help="머리글 기관명 ({{ORG}})")
    ap.add_argument("--open", action="store_true",
                    help="생성 후 macOS Finder에서 열기")
    args = ap.parse_args()

    theme = args.theme
    org = args.org
    out_dir = OUT_DIR / theme
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"테마: {theme}  |  기관: {org}")
    print(f"출력: {out_dir}/")
    print()

    # 1) 보고서 (헤더 + 푸터 + 표 2개)
    print("▶ 보고서 (report.docx) 생성 중...")
    data = build_report_docx(
        title="2026년 2분기 AI 서비스 운영 보고서",
        subtitle="인프라 현황 및 개선 과제",
        author="작성자: 운영팀",
        body_markdown=REPORT_BODY,
        theme_dir=TEMPLATE_DIR,
        template=theme,
        org_name=org,
        header_text="대외비",
        footer_text=f"© 2026 {org}",
        table_style="grid",
    )
    out = out_dir / "report.docx"
    out.write_bytes(data)
    print(f"   ✓ {out.name} ({len(data):,} bytes)")

    # 2) 회의록 (정보표 + 안건 + 액션아이템표)
    print("▶ 회의록 (minutes.docx) 생성 중...")
    data = build_minutes_docx(
        title="2분기 운영 검토회의",
        meeting_date="2026-07-28 14:00",
        location="제1회의실 / 화상",
        attendees="김개발, 이연구, 박운영, 최기획",
        author="박운영",
        agenda_markdown=MINUTES_AGENDA,
        decisions_markdown=MINUTES_DECISIONS,
        action_items_table=ACTION_ITEMS,
        theme_dir=TEMPLATE_DIR,
        template=theme,
        org_name=org,
        header_text="회의록",
        footer_text=f"© 2026 {org}",
        table_style="grid",
    )
    out = out_dir / "minutes.docx"
    out.write_bytes(data)
    print(f"   ✓ {out.name} ({len(data):,} bytes)")

    # 3) 발표자료 (pptx)
    print("▶ 발표자료 (slides.pptx) 생성 중...")
    data = build_slides_pptx(
        title="2분기 AI 서비스 운영 현황",
        subtitle="2026년 7월 운영팀",
        slides_markdown=SLIDES_MD,
        theme_dir=TEMPLATE_DIR,
        template=theme,
    )
    out = out_dir / "slides.pptx"
    out.write_bytes(data)
    print(f"   ✓ {out.name} ({len(data):,} bytes)")

    # 4) 표 (xlsx)
    print("▶ 표 (data.xlsx) 생성 중...")
    data = build_table_xlsx(
        title="월별 지표",
        table_text=SPREADSHEET,
        sheet_name="2분기 지표",
    )
    out = out_dir / "data.xlsx"
    out.write_bytes(data)
    print(f"   ✓ {out.name} ({len(data):,} bytes)")

    print(f"\n✅ 완료 — {out_dir.resolve()}/")
    for f in sorted(out_dir.iterdir()):
        if f.is_file():
            print(f"   {f.name:20s} {f.stat().st_size:>8,} bytes")

    if args.open:
        import subprocess
        subprocess.run(["open", str(out_dir)])
        print("\n📂 Finder에서 열었습니다.")


if __name__ == "__main__":
    main()
