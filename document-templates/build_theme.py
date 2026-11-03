#!/usr/bin/env python3
"""문서 생성 Tool이 쓰는 '구조형 테마'(참조 Office 파일)를 만든다.

산출물 (같은 디렉토리):
    theme-<이름>.docx   표지 + 머리글/바닥글 + 스타일을 갖춘 문서 틀
    theme-<이름>.pptx   발표자료용 베이스 덱 (16:9)

구조형 테마 docx 는 다음을 담는다:
    - 스타일: T Cover / T Title / T Subtitle / T Meta / T H1 / T H2 / T Body
    - 머리글: {{ORG}} (좌) + 하단 경계선
    - 바닥글: 가운데 페이지 번호
    - 표지: {{LOGO}} · {{TITLE}} · {{SUBTITLE}} · 강조선 · {{META}} + 페이지 나눔
  생성기(document_generator.py)가 {{...}} 자리표시자를 실제 값으로 치환한다.

사용:
    python3 build_theme.py                 # theme-default (슬레이트블루)
    python3 build_theme.py corporate 1F4E79  # theme-corporate (남색)
"""
from __future__ import annotations

import sys
from pathlib import Path

from docx import Document
from docx.enum.style import WD_STYLE_TYPE
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING, WD_TAB_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor

from pptx import Presentation
from pptx.util import Inches

KR_FONT = "Apple SD Gothic Neo"
EN_FONT = "Helvetica Neue"
INK = RGBColor(0x1A, 0x1A, 0x1A)
MUTED = RGBColor(0x6B, 0x72, 0x80)

HERE = Path(__file__).resolve().parent


def _apply(style, size_pt, color, *, bold=False):
    f = style.font
    f.name, f.size, f.bold = EN_FONT, Pt(size_pt), bold
    f.color.rgb = color
    style.element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), KR_FONT)


def _bottom_border(p, color_hex: str, sz: int = 6):
    pPr = p._p.get_or_add_pPr()
    pBdr = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), str(sz))
    bottom.set(qn("w:space"), "3")
    bottom.set(qn("w:color"), color_hex)
    pBdr.append(bottom)
    pPr.append(pBdr)


def _page_field(p):
    """단락에 PAGE 필드(페이지 번호)를 삽입."""
    run = p.add_run()
    begin = OxmlElement("w:fldChar"); begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText"); instr.set(qn("xml:space"), "preserve"); instr.text = "PAGE"
    end = OxmlElement("w:fldChar"); end.set(qn("w:fldCharType"), "end")
    run._r.append(begin); run._r.append(instr); run._r.append(end)
    run.font.name = EN_FONT
    run.font.size = Pt(9)
    run.font.color.rgb = MUTED


def build_docx(name: str, accent: RGBColor) -> Path:
    accent_hex = str(accent)
    doc = Document()

    # ── 스타일 ──
    _apply(doc.styles["Normal"], 11, INK)
    doc.styles["Normal"].paragraph_format.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
    doc.styles["Normal"].paragraph_format.line_spacing = 1.3
    specs = [
        ("T Cover", 36, accent, True), ("T Title", 26, accent, True),
        ("T Subtitle", 13, MUTED, False), ("T Meta", 10, MUTED, False),
        ("T H1", 16, accent, True), ("T H2", 13, INK, True), ("T Body", 11, INK, False),
    ]
    for sname, size, color, bold in specs:
        st = doc.styles.add_style(sname, WD_STYLE_TYPE.PARAGRAPH)
        _apply(st, size, color, bold=bold)
        pf = st.paragraph_format
        pf.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
        pf.line_spacing = 1.25 if sname == "T Body" else 1.1
        if sname == "T H1":
            pf.space_before, pf.space_after = Pt(14), Pt(6)
        elif sname == "T H2":
            pf.space_before, pf.space_after = Pt(10), Pt(4)

    sec = doc.sections[0]
    usable = sec.page_width - sec.left_margin - sec.right_margin

    def _hf_run(p, text):
        r = p.add_run(text)
        r.font.name, r.font.size, r.font.color.rgb = EN_FONT, Pt(9), MUTED
        r.font.element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), KR_FONT)
        return r

    # ── 머리글: {{ORG}} (좌) · {{HEADER}} (우) + 하단 경계선 ──
    hp = sec.header.paragraphs[0]
    hp.paragraph_format.tab_stops.add_tab_stop(usable, WD_TAB_ALIGNMENT.RIGHT)
    _hf_run(hp, "{{ORG}}"); _hf_run(hp, "\t"); _hf_run(hp, "{{HEADER}}")
    _bottom_border(hp, accent_hex, sz=4)

    # ── 바닥글: {{FOOTER}} (좌) · 페이지 번호 (가운데) ──
    fp = sec.footer.paragraphs[0]
    fp.paragraph_format.tab_stops.add_tab_stop(int(usable / 2), WD_TAB_ALIGNMENT.CENTER)
    _hf_run(fp, "{{FOOTER}}"); _hf_run(fp, "\t")
    _page_field(fp)

    # ── 표지 ──
    doc.add_paragraph("{{LOGO}}", style="T Meta")     # 로고 자리 (없으면 비움)
    for _ in range(6):
        doc.add_paragraph()                            # 상단 여백
    doc.add_paragraph("{{TITLE}}", style="T Cover")
    doc.add_paragraph("{{SUBTITLE}}", style="T Subtitle")
    rule = doc.add_paragraph()
    _bottom_border(rule, accent_hex, sz=12)
    doc.add_paragraph("{{META}}", style="T Meta")
    doc.add_page_break()

    out = HERE / f"theme-{name}.docx"
    doc.save(str(out))
    return out


def build_pptx(name: str) -> Path:
    prs = Presentation()
    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)
    out = HERE / f"theme-{name}.pptx"
    prs.save(str(out))
    return out


def main() -> None:
    name = sys.argv[1] if len(sys.argv) > 1 else "default"
    accent_hex = sys.argv[2] if len(sys.argv) > 2 else "2F5D8A"
    accent = RGBColor.from_string(accent_hex.lstrip("#"))
    d = build_docx(name, accent)
    p = build_pptx(name)
    print(f"생성됨: {d.name}  (강조색 #{accent_hex.lstrip('#').upper()}, 표지+머리글/바닥글 포함)")
    print(f"생성됨: {p.name}")
    print(f"디렉토리: {HERE}")


if __name__ == "__main__":
    main()
