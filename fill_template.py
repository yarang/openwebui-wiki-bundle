#!/usr/bin/env python3
"""템플릿 기반 문서 자동화 — 콘텐츠 템플릿(.md)의 각 섹션을 mock 데이터로
채워서 docx / pptx / md 파일을 생성한다. (오프라인 환경 전용 — LLM 연동 없음)

동작 흐름:
    tpl-*.md (콘텐츠 템플릿)
        │
        ├─ 1. frontmatter(meta) + 섹션 구조({{섹션명}}) 추출
        │
        ├─ 2. 각 섹션을 mock 데이터로 채움 (더미 텍스트, 즉시 생성)
        │
        └─ 3. type 에 따라 출력:
              · report  → build_report_docx() → .docx
              · slides  → build_slides_pptx() → .pptx
              (항상 .md 도 함께 출력 — 검토용)

사용법:
    .venv/bin/python fill_template.py tpl-report-quarterly.md \\
        --topic "2026년 2분기 AI 서비스 운영"

    # 템플릿 목록
    .venv/bin/python fill_template.py --list

    # 주제만 주면 자동 선택 템플릿 추천
    .venv/bin/python fill_template.py --suggest "분기 보고서"
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
TEMPLATE_DIR = ROOT / "document-templates"
OUTPUT_DIR = ROOT / "filled-output"

# document_generator.py import
sys.path.insert(0, str(ROOT / "open-webui-tools"))
from document_generator import (  # noqa: E402
    build_report_docx,
    build_minutes_docx,
    build_slides_pptx,
    build_table_xlsx,
)

try:
    import frontmatter  # python-frontmatter
except ImportError:
    frontmatter = None  # 폴백: 수동 파서 사용


# ══════════════════════════════════════════════════════════════════════
#  1. 템플릿 로드 — frontmatter(meta) + 본문(섹션 구조)
# ══════════════════════════════════════════════════════════════════════

_FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n(.*)", re.DOTALL)
_SECTION_RE = re.compile(r"\{\{(.+?)\}\}")


def _simple_yaml(text: str) -> dict:
    """간단한 YAML 평탄 파서 (python-frontmatter 없을 때 폴백).
    중첩 dict(instructions:) 까지만 지원."""
    result: dict[str, Any] = {}
    current_key = None
    for line in text.splitlines():
        stripped = line.rstrip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        m = re.match(r"^(\w[\w\s-]*?):\s*(.*)$", stripped)
        if not m:
            continue
        key, val = m.group(1).strip(), m.group(2).strip()
        if indent == 0:
            if val:
                result[key] = val.strip('"').strip("'")
            else:
                current_key = key
                result[current_key] = {}
        elif current_key and indent >= 2:
            if isinstance(result.get(current_key), dict):
                result[current_key][key] = val.strip('"').strip("'")
    return result


def load_template(path: Path) -> tuple[dict, str]:
    """템플릿 파일을 로드. (metadata dict, body text) 반환.

    metadata: type, visual_theme, title, subtitle, instructions{섹션: 지시문}, ...
    body: {{섹션명}} 플레이스홀더가 포함된 마크다운
    """
    text = path.read_text(encoding="utf-8")
    if frontmatter:
        post = frontmatter.load(str(path))
        return dict(post.metadata), post.content
    # 폴백
    m = _FM_RE.match(text)
    if not m:
        return {}, text
    meta = _simple_yaml(m.group(1))
    return meta, m.group(2)


def extract_sections(body: str) -> list[str]:
    """본문에서 {{섹션명}} 플레이스홀더를 추출 (순서 유지, 중복 제거)."""
    seen: list[str] = []
    for m in _SECTION_RE.finditer(body):
        name = m.group(1).strip()
        if name not in ("title", "subtitle") and name not in seen:
            seen.append(name)
    return seen


# ══════════════════════════════════════════════════════════════════════
#  2. 섹션 채우기 — Mock 데이터
# ══════════════════════════════════════════════════════════════════════

# ── Mock 데이터 생성기 ─────────────────────────────────────────────────

def _mock_table(headers: list[str], rows: list[list[str]]) -> str:
    """마크다운 표 생성."""
    lines = ["| " + " | ".join(headers) + " |"]
    lines.append("|" + "|".join(["---"] * len(headers)) + "|")
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def fill_with_mock(topic: str, sections: list[str]) -> dict[str, str]:
    """LLM 없이 더미 데이터로 각 섹션을 채운다 (구조 검증용)."""
    today = date.today().isoformat()
    mock_data: dict[str, str] = {
        "개요": (
            f"**{topic}**에 대한 분기 운영 현황을 보고한다.\n\n"
            f"본 보고 기간({today} 기준) 동안 주요 시스템은 안정적으로 운영되었으며, "
            "사용자 요청 증가에도 불구하고 서비스 품질 지표를 목표치 내로 유지했다."
        ),
        "핵심 지표": _mock_table(
            ["지표", "전분기", "당분기", "증감"],
            [
                ["일평균 요청", "12,500", "18,300", "+46%"],
                ["평균 응답시간", "2.1s", "1.8s", "-14%"],
                ["에러율", "0.8%", "0.3%", "-62%"],
                ["활성 사용자", "3,200", "4,100", "+28%"],
            ],
        ),
        "주요 이슈": (
            "1. **DB 디스크 사용률 임계치 접근** — 67% 도달, 확장 계획 수립 완료\n"
            "2. **트래픽 급증 구간 발생** — 오토스케일링 정상 작동으로 무사히 처리"
        ),
        "개선 과제": (
            "1. DB-01 디스크 확장 (2TB→4TB) — 담당: 김개발, 기한: 2026-08-05\n"
            "2. Redis 응답 캐싱 도입 — 담당: 이연구, 기한: 2026-08-12\n"
            "3. 모니터링 대시보드 통합 — 담당: 박운영, 기한: 2026-08-19"
        ),
        "향후 계획": (
            "- 3분기 캐싱 시스템 전면 도입\n"
            "- 모니터링 고도화 (실시간 알림 연동)\n"
            "- 사용자 피드백 기반 UI 개선"
        ),
        "배경 및 목적": (
            f"**{topic}** 제안의 배경은 다음과 같다.\n\n"
            "현재 시스템의 응답 지연과 비용 증가가 대두됨에 따라, "
            "효율적인 추론 캐싱 시스템 도입을 제안한다."
        ),
        "현황 분석": (
            "현재 시스템은 매 요청마다 LLM 추론을 수행하여 평균 1.8초의 응답시간이 발생한다. "
            "유사 질문의 반복 비율이 약 35%로 추정되며, 이를 캐싱으로 단축 가능하다."
        ),
        "제안 내용": (
            "Redis 기반 semantic + exact 캐싱 이중 계층을 제안한다.\n\n"
            "- **Exact 캐싱**: 동일 질문 즉시 반환 (TTL 1시간)\n"
            "- **Semantic 캐싱**: 임베딩 유사도 0.92 이상 시 반환 (TTL 24시간)\n"
            "- 캐시 적중률 목표: 30% 이상"
        ),
        "기대 효과": _mock_table(
            ["항목", "현재", "도입 후"],
            [
                ["평균 응답시간", "1.8s", "1.2s"],
                ["GPU 사용률", "72%", "50%"],
                ["월 운영비", "500만원", "350만원"],
                ["사용자 만족도", "78점", "90점 예상"],
            ],
        ),
        "추진 일정": _mock_table(
            ["단계", "기간", "주요 활동"],
            [
                ["1. 설계", "1~2주차", "아키텍처 설계, POC"],
                ["2. 개발", "3~6주차", "캐싱 모듈 개발, 통합"],
                ["3. 테스트", "7~8주차", "성능 검증, 버그 수정"],
                ["4. 배포", "9주차", "프로덕션 적용, 모니터링"],
            ],
        ),
        "소요 예산": _mock_table(
            ["항목", "금액(천원)", "비고"],
            [
                ["개발 인건비", "8,000", "2인 × 8주"],
                ["Redis 서버", "1,500", "월 500 × 3개월"],
                ["테스트 환경", "500", "임시 인프라"],
                ["합계", "10,000", ""],
            ],
        ),
        "현황 요약": (
            "- 일평균 요청 **18,300건** (전분기 대비 +46%)\n"
            "- 에러율 **0.3%** 달성 (전분기 0.8% → 62% 개선)\n"
            "- 활성 사용자 **4,100명** 돌파\n"
            "- 시스템 가동률 **99.7%** 유지"
        ),
        "주요 성과": (
            "- 응답시간 **1.8s** 달성 (목표 2.0s 대비 10% 개선)\n"
            "- 에러율 **0.3%** (목표 0.5% 대비 40% 개선)\n"
            "- 비용 절감 **15%** (GPU 최적화 효과)"
        ),
        "이슈 및 대응": (
            "- **DB 디스크 67%** → 4TB 확장 완료 예정 (8월)\n"
            "- **트래픽 피크** → 오토스케일링으로 대응 완료"
        ),
    }
    result: dict[str, str] = {}
    for sec in sections:
        result[sec] = mock_data.get(
            sec,
            f"_{sec} 섹션 — 등록된 mock 데이터 없음. fill_with_mock()에 항목을 추가하세요._",
        )
    return result


# ══════════════════════════════════════════════════════════════════════
#  3. 템플릿 치환 + 문서 생성
# ══════════════════════════════════════════════════════════════════════

def fill_template_body(body: str, sections: dict[str, str]) -> str:
    """{{섹션명}} 플레이스홀더를 실제 내용으로 치환."""
    result = body
    for name, content in sections.items():
        result = result.replace(f"{{{{{name}}}}}", content)
    # 미처리 플레이스홀더 정리 (title/subtitle 등)
    result = _SECTION_RE.sub(lambda m: f"_{m.group(1)}_", result)
    return result


def render_docx(meta: dict, body: str, title: str, subtitle: str,
                org: str = "", header: str = "", footer: str = "") -> bytes:
    """채워진 본문을 docx로 변환."""
    doc_type = meta.get("type", "report")
    theme = meta.get("visual_theme", "default")
    table_style = meta.get("table_style", "grid")

    if doc_type == "minutes":
        return build_minutes_docx(
            title=title, agenda_markdown=body, theme_dir=str(TEMPLATE_DIR),
            template=theme, org_name=org, header_text=header, footer_text=footer,
            table_style=table_style,
        )
    return build_report_docx(
        title=title, body_markdown=body, subtitle=subtitle,
        theme_dir=str(TEMPLATE_DIR), template=theme,
        org_name=org, header_text=header, footer_text=footer,
        table_style=table_style,
    )


def render_pptx(meta: dict, body: str, title: str, subtitle: str) -> bytes:
    """채워진 본문을 pptx로 변환."""
    theme = meta.get("visual_theme", "default")
    return build_slides_pptx(
        title=title, subtitle=subtitle, slides_markdown=body,
        theme_dir=str(TEMPLATE_DIR), template=theme,
    )


# ══════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════

def list_templates() -> None:
    """사용 가능한 콘텐츠 템플릿 목록."""
    tpls = sorted(TEMPLATE_DIR.glob("tpl-*.md"))
    if not tpls:
        print("템플릿 없음. document-templates/tpl-*.md 파일을 만드세요.")
        return
    print(f"콘텐츠 템플릿 ({len(tpls)}개) — {TEMPLATE_DIR}/\n")
    for p in tpls:
        meta, body = load_template(p)
        sections = extract_sections(body)
        t = meta.get("type", "?")
        v = meta.get("visual_theme", "default")
        title = meta.get("title", "(제목 없음)")
        print(f"  {p.name}")
        print(f"    종류: {t} | 테마: {v} | 제목: {title}")
        print(f"    섹션: {', '.join(sections)}")
        print()


def suggest_template(keyword: str) -> None:
    """키워드로 템플릿 추천."""
    tpls = sorted(TEMPLATE_DIR.glob("tpl-*.md"))
    kw = keyword.lower()
    scored: list[tuple[int, Path, dict]] = []
    for p in tpls:
        meta, body = load_template(p)
        text = f"{p.name} {meta.get('title','')} {' '.join(meta.get('instructions',{}).keys())}".lower()
        score = sum(1 for w in kw.split() if w in text)
        scored.append((score, p, meta))
    scored.sort(key=lambda x: -x[0])
    if scored and scored[0][0] > 0:
        print(f"추천 템플릿: {scored[0][1].name}\n")
    else:
        print("매칭 템플릿 없음. 목록을 확인하세요:\n")
    list_templates()


def main():
    ap = argparse.ArgumentParser(
        description="템플릿 기반 문서 자동화 — 섹션별 mock 채우기 → docx/pptx/md",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예제:
  %(prog)s tpl-report-quarterly.md --topic "2분기 운영 보고"

  # 발표자료
  %(prog)s tpl-briefing-slides.md --topic "2분기 브리핑"
""",
    )
    ap.add_argument("template", nargs="?", help="콘텐츠 템플릿 파일명 (tpl-*.md)")
    ap.add_argument("--topic", default="샘플 주제", help="문서의 주제/제목")
    ap.add_argument("--org", default="AX 36사업단", help="머리글 기관명")
    ap.add_argument("--header", default="", help="머리글 오른쪽 문구")
    ap.add_argument("--footer", default="", help="바닥글 왼쪽 문구")
    ap.add_argument("--list", action="store_true", help="사용 가능한 템플릿 목록")
    ap.add_argument("--suggest", metavar="KEYWORD", help="키워드로 템플릿 추천")
    ap.add_argument("--open", action="store_true", help="생성 후 Finder에서 열기 (macOS)")
    ap.add_argument("--out", default="", help="출력 디렉토리 (기본: filled-output/)")
    args = ap.parse_args()

    if args.list:
        list_templates()
        return
    if args.suggest:
        suggest_template(args.suggest)
        return
    if not args.template:
        ap.error("template 인자 필요. --list 로 목록 확인.")

    # 템플릿 로드
    tpl_path = TEMPLATE_DIR / args.template
    if not tpl_path.exists():
        # 사용자가 전체 경로를 줬을 수도 있음
        tpl_path = Path(args.template)
    if not tpl_path.exists():
        print(f"✗ 템플릿 없음: {args.template}")
        print(f"  검색 위치: {TEMPLATE_DIR}")
        list_templates()
        sys.exit(1)

    meta, body = load_template(tpl_path)
    sections = extract_sections(body)
    doc_type = meta.get("type", "report")
    visual_theme = meta.get("visual_theme", "default")

    print(f"템플릿: {tpl_path.name}")
    print(f"  종류: {doc_type} | 시각 테마: {visual_theme}")
    print(f"  섹션 ({len(sections)}개): {', '.join(sections)}")
    print(f"  주제: {args.topic}")
    print()

    # 섹션 채우기 (mock 데이터)
    filled = fill_with_mock(args.topic, sections)
    print()

    # 템플릿 치환
    final_body = fill_template_body(body, filled)
    title = args.topic
    subtitle = meta.get("subtitle", "")

    # 출력 디렉토리
    out_dir = Path(args.out) if args.out else OUTPUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    safe_name = re.sub(r"[^\w가-힣 .-]", "", title).strip() or "document"

    # 1) 항상 Markdown 출력 (검토용)
    md_path = out_dir / f"{safe_name}.md"
    md_content = f"# {title}\n\n"
    if subtitle:
        md_content += f"_{subtitle}_\n\n"
    md_content += final_body
    md_path.write_text(md_content, encoding="utf-8")
    print(f"✓ Markdown: {md_path.name}")

    # 2) 문서 타입별 출력
    if doc_type == "slides":
        data = render_pptx(meta, final_body, title, subtitle)
        ext = "pptx"
    else:
        data = render_docx(meta, final_body, title, subtitle,
                           org=args.org, header=args.header, footer=args.footer)
        ext = "docx"

    doc_path = out_dir / f"{safe_name}.{ext}"
    doc_path.write_bytes(data)
    print(f"✓ {ext.upper()}: {doc_path.name} ({len(data):,} bytes)")

    print(f"\n✅ 완료 — {out_dir.resolve()}/")
    for f in sorted(out_dir.iterdir()):
        if f.is_file():
            print(f"   {f.name:30s} {f.stat().st_size:>8,} bytes")

    if args.open:
        import subprocess
        subprocess.run(["open", str(out_dir)])
        print("\n📂 Finder에서 열었습니다.")


if __name__ == "__main__":
    main()
