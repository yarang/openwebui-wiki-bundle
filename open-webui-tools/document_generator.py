"""
title: 문서 생성기 (docx/pptx/xlsx)
author: example
version: 0.1.7
description: 대화 내용을 Word 보고서·회의록, PowerPoint 발표자료, Excel 표로 만들어 다운로드 링크를 준다.
required_open_webui_version: 0.5.0
"""

# Open WebUI 네이티브 Tool — Workspace → Tools 에 그대로 붙여넣어 등록한다.
#
# 다운로드 원리 (소스 검증): 생성한 바이너리를 upload_file_handler(process=False)로
# Files 스토리지에 저장 → /api/v1/files/{id}/content 링크 반환. docx/pptx/xlsx 는
# PDF·텍스트가 아니므로 이 엔드포인트가 Content-Disposition: attachment 를 붙여
# 브라우저 다운로드를 강제한다.
#
# 양식: '실제 Office 파일 기반' — document-templates/theme-<이름>.docx 의 스타일을
# 열어 채운다. create_*(template="<이름>") 로 선택(기본 default). 없으면 default →
# 코드 스타일 순으로 폴백. 테마 추가 = document-templates 에 theme-<이름>.docx 넣기.

from __future__ import annotations

import csv
import io
import os
import re
from datetime import date
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field

# ── 디자인 상수 (테마 파일이 없을 때 폴백 + pptx/xlsx 프로그램 스타일) ──
KR_FONT = "Apple SD Gothic Neo"
EN_FONT = "Helvetica Neue"
INK = (0x1A, 0x1A, 0x1A)
ACCENT = (0x2F, 0x5D, 0x8A)
MUTED = (0x6B, 0x72, 0x80)

# 표 스타일 친화명 → docx 내장 스타일 (없으면 Table Grid 폴백)
_TABLE_STYLES = {
    "grid": "Light Grid Accent 1",
    "plain": "Table Grid",
    "striped": "Light List Accent 1",
    "minimal": "Light List",
}


# ══════════════════════════════════════════════════════════════════════
#  파서 — 모델이 만들기 쉬운 Markdown 을 문서 구조로
# ══════════════════════════════════════════════════════════════════════
def parse_slides(md: str) -> list[dict]:
    """'---' 로 구분된 슬라이드. 각 슬라이드: 첫 '# 제목', '- 불릿', 나머지 본문."""
    slides: list[dict] = []
    for chunk in re.split(r"^\s*---\s*$", md or "", flags=re.MULTILINE):
        title, bullets, body = "", [], []
        for raw in chunk.splitlines():
            line = raw.rstrip()
            if not line.strip():
                continue
            if line.startswith("# ") and not title:
                title = line[2:].strip()
            elif re.match(r"^\s*[-*]\s+", line):
                bullets.append(re.sub(r"^\s*[-*]\s+", "", line).strip())
            else:
                body.append(line.strip())
        if title or bullets or body:
            slides.append({"title": title, "bullets": bullets, "body": body})
    return slides


def parse_table(text: str) -> list[list[str]]:
    """Markdown 표 | CSV | TSV → 행렬. 구분자 자동 감지."""
    lines = [ln for ln in (text or "").splitlines() if ln.strip()]
    if not lines:
        return []
    if "|" in lines[0]:  # markdown table
        rows = []
        for ln in lines:
            if re.match(r"^\s*\|?\s*:?-{2,}", ln):  # 구분선 (---)
                continue
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            rows.append(cells)
        return rows
    delim = "\t" if "\t" in lines[0] else ","
    return [row for row in csv.reader(lines, delimiter=delim)]


# 인라인 서식 토큰: 굵게 → 코드 → 위키링크 → 링크 → 기울임 (순서 중요)
_INLINE_RE = re.compile(r"(\*\*.+?\*\*|`.+?`|\[\[.+?\]\]|\[[^\]]+?\]\([^)]+?\)|\*.+?\*)")


def _strip_md(text: str) -> str:
    """인라인 마크다운 표기를 제거한 순수 텍스트 (pptx 등 런 분리가 어려운 곳)."""
    t = text or ""
    t = re.sub(r"\*\*(.+?)\*\*", r"\1", t)          # 굵게
    t = re.sub(r"`(.+?)`", r"\1", t)                # 코드
    t = re.sub(r"\[\[(.+?)\]\]", r"\1", t)          # [[위키링크]]
    t = re.sub(r"\[([^\]]+?)\]\([^)]+?\)", r"\1", t)  # [텍스트](url)
    t = re.sub(r"\*(.+?)\*", r"\1", t)              # 기울임
    return t


def _add_inline(paragraph, text: str) -> None:
    """문단에 인라인 마크다운을 해석해 run 들로 추가 (굵게/기울임/코드/링크)."""
    text = text or ""
    pos = 0
    for m in _INLINE_RE.finditer(text):
        if m.start() > pos:
            paragraph.add_run(text[pos:m.start()])
        tok = m.group(0)
        if tok.startswith("**"):
            paragraph.add_run(tok[2:-2]).bold = True
        elif tok.startswith("`"):
            paragraph.add_run(tok[1:-1]).font.name = "Menlo"
        elif tok.startswith("[["):
            paragraph.add_run(tok[2:-2])                       # 위키링크 → 텍스트
        elif tok.startswith("[") and "](" in tok:
            paragraph.add_run(tok[1:tok.index("]")])           # 링크 → 라벨
        elif tok.startswith("*"):
            paragraph.add_run(tok[1:-1]).italic = True
        else:
            paragraph.add_run(tok)
        pos = m.end()
    if pos < len(text):
        paragraph.add_run(text[pos:])


def _is_table_sep(line: str) -> bool:
    return bool(re.match(r"^\s*\|?[\s:\-|]+\|?\s*$", line)) and "-" in line


def _parse_align(sep_line: str) -> list[str]:
    """구분선(:---: 등)에서 열 정렬 추출 → 'left'|'center'|'right'."""
    aligns = []
    for c in sep_line.strip().strip("|").split("|"):
        c = c.strip()
        left, right = c.startswith(":"), c.endswith(":")
        aligns.append("center" if left and right else "right" if right else "left")
    return aligns


def _add_md_table(doc, tbl_lines: list[str], *, style: str = "Light Grid Accent 1",
                  caption: Optional[str] = None, widths: Optional[list] = None) -> None:
    """마크다운 표 → docx 표. 첫 행 굵게 + 정렬 마커·스타일·캡션·열너비 지원."""
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.oxml.ns import qn
    from docx.shared import Pt, RGBColor

    aln_map = {"left": WD_ALIGN_PARAGRAPH.LEFT, "center": WD_ALIGN_PARAGRAPH.CENTER,
               "right": WD_ALIGN_PARAGRAPH.RIGHT}
    rows, aligns = [], []
    for ln in tbl_lines:
        if _is_table_sep(ln):
            aligns = _parse_align(ln)
            continue
        rows.append([c.strip() for c in ln.strip().strip("|").split("|")])
    if not rows:
        return
    ncol = max(len(r) for r in rows)

    if caption:
        cp = doc.add_paragraph()
        cr = cp.add_run(caption)
        cr.italic, cr.bold = True, True
        cr.font.size, cr.font.color.rgb, cr.font.name = Pt(9.5), RGBColor(*MUTED), EN_FONT
        cr.font.element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), KR_FONT)

    t = doc.add_table(rows=len(rows), cols=ncol)
    try:
        t.style = style
    except Exception:
        t.style = "Table Grid"

    colw = None
    if widths and len(widths) >= ncol and sum(widths[:ncol]) > 0:
        from docx.shared import Inches
        total = int(Inches(6.5)); s = sum(widths[:ncol])
        colw = [int(total * widths[c] / s) for c in range(ncol)]

    for r, row in enumerate(rows):
        for c in range(ncol):
            cell = t.rows[r].cells[c]
            p = cell.paragraphs[0]
            if aligns and c < len(aligns):
                p.alignment = aln_map[aligns[c]]
            _add_inline(p, row[c] if c < len(row) else "")
            if r == 0:
                for run in p.runs:
                    run.bold = True
            if colw:
                cell.width = colw[c]
    if colw:
        for c in range(ncol):
            t.columns[c].width = colw[c]
    doc.add_paragraph()


def _render_md(doc, md: str, *, h1: str = "T H1", h2: str = "T H2", body: str = "T Body",
               table_style: str = "Light Grid Accent 1") -> None:
    """마크다운 본문을 docx 블록으로 렌더. 표 앞 '표: 캡션' / '너비: 2,5,3' 지시문 지원."""
    lines = (md or "").split("\n")
    n = len(lines)
    i = 0
    cap = None      # 대기 중인 표 캡션
    widths = None   # 대기 중인 열 너비

    def flush():
        nonlocal cap, widths
        if cap is not None:
            _add_inline(doc.add_paragraph(style=body), "표: " + cap)
            cap = None
        widths = None

    while i < n:
        line = lines[i].rstrip()
        if not line.strip():
            i += 1
            continue
        is_table = "|" in line and i + 1 < n and _is_table_sep(lines[i + 1])
        mcap = re.match(r"^표:\s*(.+)$", line)
        mw = re.match(r"^너비:\s*([\d.,\s]+)$", line)
        if mcap and not is_table:
            flush(); cap = mcap.group(1).strip(); i += 1; continue
        if mw and not is_table:
            widths = [float(x) for x in re.split(r"[,\s]+", mw.group(1).strip()) if x]; i += 1; continue
        if is_table:
            blk = []
            while i < n and "|" in lines[i] and lines[i].strip():
                blk.append(lines[i]); i += 1
            _add_md_table(doc, blk, style=table_style, caption=cap, widths=widths)
            cap, widths = None, None
            continue
        flush()
        mh = re.match(r"^(#{1,6})\s+(.*)$", line)
        if mh:
            style = h1 if len(mh.group(1)) == 1 else h2
            _add_inline(doc.add_paragraph(style=style), mh.group(2).strip())
            i += 1
            continue
        if re.match(r"^\s*[-*+]\s+", line):
            _add_inline(doc.add_paragraph(style="List Bullet"), re.sub(r"^\s*[-*+]\s+", "", line).strip())
            i += 1
            continue
        if re.match(r"^\s*\d+\.\s+", line):
            _add_inline(doc.add_paragraph(style="List Number"), re.sub(r"^\s*\d+\.\s+", "", line).strip())
            i += 1
            continue
        _add_inline(doc.add_paragraph(style=body), line.strip())
        i += 1
    flush()


# ══════════════════════════════════════════════════════════════════════
#  docx — 테마 스타일로 채우기
# ══════════════════════════════════════════════════════════════════════
# 커스텀 단락 스타일 스펙 (이름, 크기pt, 색, 굵기) — 테마 파일에 없으면 코드로 보강
_STYLE_SPECS = [
    ("T Cover", 36, ACCENT, True), ("T Title", 26, ACCENT, True),
    ("T Subtitle", 13, MUTED, False), ("T Meta", 10, MUTED, False),
    ("T H1", 16, ACCENT, True), ("T H2", 13, INK, True), ("T Body", 11, INK, False),
]


def _theme_path(theme_dir: Optional[str], template: str, ext: str) -> Optional[Path]:
    """theme-<template>.<ext> 를 찾고, 없으면 theme-default.<ext> 로 폴백. 둘 다 없으면 None."""
    if not theme_dir:
        return None
    names = [template, "default"] if template and template != "default" else ["default"]
    for name in names:
        p = Path(theme_dir) / f"theme-{name}.{ext}"
        if p.exists():
            return p
    return None


def _list_themes(theme_dir: Optional[str]) -> list[str]:
    """document-templates 에 있는 theme-*.docx / theme-*.pptx 의 <이름> 목록."""
    names: set[str] = set()
    if theme_dir and Path(theme_dir).is_dir():
        for ext in ("docx", "pptx"):
            for p in Path(theme_dir).glob(f"theme-*.{ext}"):
                names.add(p.stem[len("theme-"):])
    return sorted(names)


def _theme_accent(theme_dir: Optional[str], template: str = "default") -> tuple:
    """pptx 강조색 = 해당 테마 docx 의 T Title 색 (docx·pptx 단일 소스). 없으면 기본 ACCENT."""
    p = _theme_path(theme_dir, template, "docx")
    if p is not None:
        try:
            from docx import Document
            c = Document(str(p)).styles["T Title"].font.color.rgb
            if c is not None:
                h = str(c)
                return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
        except Exception:
            pass
    return ACCENT


def _ensure_docx_styles(doc):
    """문서에 T-* 커스텀 스타일이 없으면 코드로 추가 (테마 파일이 일부 스타일을 빠뜨려도 안전)."""
    from docx.enum.style import WD_STYLE_TYPE
    from docx.enum.text import WD_LINE_SPACING
    from docx.oxml.ns import qn
    from docx.shared import Pt, RGBColor

    def apply(style, size, color, bold):
        f = style.font
        f.name, f.size, f.bold = EN_FONT, Pt(size), bold
        f.color.rgb = RGBColor(*color)
        style.element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), KR_FONT)

    existing = {s.name for s in doc.styles}
    for name, size, color, bold in _STYLE_SPECS:
        if name in existing:
            continue
        st = doc.styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
        apply(st, size, color, bold)
        st.paragraph_format.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
        st.paragraph_format.line_spacing = 1.25 if name == "T Body" else 1.1
    return doc


def _new_docx_with_styles():
    """테마 파일 폴백 — 빈 문서 + 코드 스타일."""
    from docx import Document
    from docx.oxml.ns import qn
    from docx.shared import Pt, RGBColor

    doc = Document()
    nf = doc.styles["Normal"].font
    nf.name, nf.size, nf.color.rgb = EN_FONT, Pt(11), RGBColor(*INK)
    doc.styles["Normal"].element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), KR_FONT)
    return _ensure_docx_styles(doc)


def _load_docx(theme_dir: Optional[str], template: str = "default"):
    """선택한 테마 docx 를 열어 스타일 확보. 없으면 default → 코드 폴백. 스타일은 항상 보강."""
    p = _theme_path(theme_dir, template, "docx")
    if p is not None:
        from docx import Document
        return _ensure_docx_styles(Document(str(p)))
    return _new_docx_with_styles()


def _has_cover(doc) -> bool:
    """구조형 테마인지 — 표지 자리표시자 {{TITLE}} 유무로 판단."""
    return any("{{TITLE}}" in p.text for p in doc.paragraphs)


def _fill_placeholders(doc, mapping: dict) -> None:
    """본문·머리글·바닥글 단락의 {{...}} 자리표시자를 치환 (자리표시자는 단일 run)."""
    def fill(paras):
        for p in paras:
            for run in p.runs:
                for k, v in mapping.items():
                    if k in run.text:
                        run.text = run.text.replace(k, v)
    fill(doc.paragraphs)
    for sec in doc.sections:
        fill(sec.header.paragraphs)
        fill(sec.footer.paragraphs)


def _fill_cover(doc, *, title="", subtitle="", meta="", logo_path="") -> None:
    """구조형 테마의 표지 자리표시자를 채운다. {{LOGO}} 는 이미지로 교체. (머리글/바닥글은 _apply_branding)"""
    from docx.shared import Inches
    for p in doc.paragraphs:
        if "{{LOGO}}" in p.text:
            for r in list(p.runs):
                r.text = ""
            if logo_path and Path(logo_path).exists():
                try:
                    p.add_run().add_picture(logo_path, height=Inches(0.5))
                except Exception:
                    pass
            break
    _fill_placeholders(doc, {
        "{{TITLE}}": title or "", "{{SUBTITLE}}": subtitle or "",
        "{{META}}": meta or "",
    })


def _apply_branding(doc, org="", header="", footer="") -> None:
    """머리글·바닥글 자리표시자 치환 ({{ORG}}/{{HEADER}}/{{FOOTER}}). 구조형 테마에만 존재."""
    _fill_placeholders(doc, {
        "{{ORG}}": org or "", "{{HEADER}}": header or "", "{{FOOTER}}": footer or "",
    })


def _add(doc, text, style):
    return doc.add_paragraph(text, style=style)


def build_report_docx(title: str, body_markdown: str, subtitle: str = "",
                      author: str = "", theme_dir: Optional[str] = None,
                      template: str = "default", org_name: str = "", logo_path: str = "",
                      header_text: str = "", footer_text: str = "", table_style: str = "grid") -> bytes:
    doc = _load_docx(theme_dir, template)
    _apply_branding(doc, org=org_name, header=header_text, footer=footer_text)
    meta = " · ".join(x for x in [author, date.today().isoformat()] if x)
    if _has_cover(doc):
        _fill_cover(doc, title=title, subtitle=subtitle, meta=meta, logo_path=logo_path)
    else:
        _add(doc, title, "T Title")
        if subtitle:
            _add(doc, subtitle, "T Subtitle")
        if meta:
            _add(doc, meta, "T Meta")
        doc.add_paragraph()
    _render_md(doc, body_markdown, table_style=_TABLE_STYLES.get(table_style, table_style))
    buf = io.BytesIO()
    doc.save(buf)
    return buf.getvalue()


def build_minutes_docx(title: str, meeting_date: str = "", location: str = "",
                       attendees: str = "", author: str = "",
                       agenda_markdown: str = "", decisions_markdown: str = "",
                       action_items_table: str = "", theme_dir: Optional[str] = None,
                       template: str = "default", org_name: str = "", logo_path: str = "",
                       header_text: str = "", footer_text: str = "", table_style: str = "grid") -> bytes:
    from docx.shared import Pt

    tstyle = _TABLE_STYLES.get(table_style, table_style)
    doc = _load_docx(theme_dir, template)
    _apply_branding(doc, org=org_name, header=header_text, footer=footer_text)
    if _has_cover(doc):
        _fill_cover(doc, title=title or "회의록", subtitle="회의록",
                    meta=date.today().isoformat(), logo_path=logo_path)
    else:
        _add(doc, title or "회의록", "T Title")
        doc.add_paragraph()

    # 머리 정보 표
    rows = [("일시", meeting_date or date.today().isoformat()), ("장소", location),
            ("참석자", attendees), ("작성자", author)]
    tbl = doc.add_table(rows=len(rows), cols=2)
    try:
        tbl.style = tstyle
    except Exception:
        tbl.style = "Table Grid"
    for i, (k, v) in enumerate(rows):
        tbl.rows[i].cells[0].text = k
        tbl.rows[i].cells[1].text = v
        tbl.rows[i].cells[0].width = Pt(90)
    doc.add_paragraph()

    def section(heading, md):
        if not md.strip():
            return
        _add(doc, heading, "T H1")
        _render_md(doc, md, h1="T H2", h2="T H2", table_style=tstyle)

    section("안건", agenda_markdown)
    section("결정 사항", decisions_markdown)

    # 액션 아이템 표 (담당|내용|기한)
    ai = parse_table(action_items_table)
    if ai:
        _add(doc, "액션 아이템", "T H1")
        header = ["담당", "내용", "기한"]
        first_is_header = [c.strip() for c in ai[0][:3]] == header
        data = ai if first_is_header else [header] + ai
        t = doc.add_table(rows=len(data), cols=3)
        try:
            t.style = tstyle
        except Exception:
            t.style = "Table Grid"
        for r, row in enumerate(data):
            for c in range(3):
                t.rows[r].cells[c].text = row[c] if c < len(row) else ""
    buf = io.BytesIO()
    doc.save(buf)
    return buf.getvalue()


# ══════════════════════════════════════════════════════════════════════
#  pptx — blank 레이아웃에 깔끔한 제목 바 + 불릿 (프로그램 스타일)
# ══════════════════════════════════════════════════════════════════════
def build_slides_pptx(title: str, subtitle: str, slides_markdown: str,
                      theme_dir: Optional[str] = None, template: str = "default") -> bytes:
    from pptx import Presentation
    from pptx.dml.color import RGBColor
    from pptx.enum.text import PP_ALIGN
    from pptx.util import Inches, Pt

    p = _theme_path(theme_dir, template, "pptx")
    base = str(p) if p is not None else None
    prs = Presentation(base) if base else Presentation()
    if not base:
        prs.slide_width = Inches(13.333)
        prs.slide_height = Inches(7.5)
    W, H = prs.slide_width, prs.slide_height
    blank = prs.slide_layouts[6]
    accent = _theme_accent(theme_dir, template)   # 테마 강조색 (docx T Title 색)

    def rgb(t):
        return RGBColor(*t)

    def textbox(slide, left, top, width, height):
        tb = slide.shapes.add_textbox(left, top, width, height)
        tf = tb.text_frame
        tf.word_wrap = True
        return tf

    def style_run(run, size, color, bold=False):
        run.font.name = KR_FONT
        run.font.size = Pt(size)
        run.font.bold = bold
        run.font.color.rgb = rgb(color)

    # 표지
    cover = prs.slides.add_slide(blank)
    bar = cover.shapes.add_shape(1, 0, Inches(3.0), W, Inches(0.08))
    bar.fill.solid(); bar.fill.fore_color.rgb = rgb(accent); bar.line.fill.background()
    tf = textbox(cover, Inches(0.9), Inches(2.0), W - Inches(1.8), Inches(1.0))
    style_run(tf.paragraphs[0].add_run(), 40, accent, True)
    tf.paragraphs[0].runs[0].text = title or "제목"
    if subtitle:
        stf = textbox(cover, Inches(0.9), Inches(3.2), W - Inches(1.8), Inches(0.8))
        r = stf.paragraphs[0].add_run(); r.text = subtitle
        style_run(r, 18, MUTED)

    # 내용 슬라이드
    for s in parse_slides(slides_markdown):
        sl = prs.slides.add_slide(blank)
        # 제목 + 짧은 강조선
        ttf = textbox(sl, Inches(0.7), Inches(0.5), W - Inches(1.4), Inches(1.0))
        r = ttf.paragraphs[0].add_run(); r.text = _strip_md(s["title"] or "")
        style_run(r, 28, accent, True)
        rule = sl.shapes.add_shape(1, Inches(0.75), Inches(1.5), Inches(1.6), Inches(0.05))
        rule.fill.solid(); rule.fill.fore_color.rgb = rgb(accent); rule.line.fill.background()
        # 본문/불릿
        body_tf = textbox(sl, Inches(0.9), Inches(1.9), W - Inches(1.8), H - Inches(2.6))
        first = True
        for line in s["body"]:
            para = body_tf.paragraphs[0] if first else body_tf.add_paragraph()
            first = False
            rr = para.add_run(); rr.text = _strip_md(line); style_run(rr, 18, INK)
        for b in s["bullets"]:
            para = body_tf.paragraphs[0] if first else body_tf.add_paragraph()
            first = False
            para.level = 0
            rr = para.add_run(); rr.text = "•  " + _strip_md(b); style_run(rr, 18, INK)

    buf = io.BytesIO()
    prs.save(buf)
    return buf.getvalue()


# ══════════════════════════════════════════════════════════════════════
#  xlsx — openpyxl 코드 스타일 프로파일
# ══════════════════════════════════════════════════════════════════════
def build_table_xlsx(title: str, table_text: str, sheet_name: str = "Sheet1") -> bytes:
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Font, PatternFill

    rows = parse_table(table_text)
    wb = Workbook()
    ws = wb.active
    ws.title = (sheet_name or "Sheet1")[:31]

    if rows:
        header_fill = PatternFill("solid", fgColor="2F5D8A")
        header_font = Font(bold=True, color="FFFFFF", name=KR_FONT)
        body_font = Font(name=KR_FONT)
        for r, row in enumerate(rows, start=1):
            for c, val in enumerate(row, start=1):
                cell = ws.cell(row=r, column=c, value=val)
                if r == 1:
                    cell.fill = header_fill
                    cell.font = header_font
                    cell.alignment = Alignment(horizontal="center")
                else:
                    cell.font = body_font
        # 열 너비 자동
        for c in range(1, len(rows[0]) + 1):
            width = max((len(str(row[c - 1])) for row in rows if c - 1 < len(row)), default=8)
            ws.column_dimensions[ws.cell(row=1, column=c).column_letter].width = min(max(width + 2, 10), 50)
        ws.freeze_panes = "A2"
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


# ══════════════════════════════════════════════════════════════════════
#  Open WebUI Tool
# ══════════════════════════════════════════════════════════════════════
_MIME = {
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
}


class Tools:
    class Valves(BaseModel):
        templates_dir: str = Field(
            default=os.environ.get("DOCUMENT_TEMPLATES_DIR", ""),
            description="theme-*.docx/pptx 가 있는 디렉토리 절대경로. "
                        "비우면 코드 내장 스타일로 폴백합니다.",
        )
        org_name: str = Field(
            default="",
            description="구조형 테마의 머리글·표지에 넣을 기관/팀 이름({{ORG}}). 비우면 표시 안 함.",
        )
        logo_path: str = Field(
            default="",
            description="구조형 테마 표지 로고 이미지 절대경로(PNG/JPG). 비우면 로고 없음.",
        )
        table_style: str = Field(
            default="grid",
            description="표 기본 스타일: grid / plain / striped / minimal (또는 docx 내장 스타일명).",
        )

    def __init__(self):
        self.valves = self.Valves()

    # ── 내부: 바이너리 저장 → 다운로드 링크 ──────────────────────────
    async def _save_and_link(self, request, user, data: bytes, filename: str, ext: str) -> str:
        from fastapi import UploadFile
        from starlette.datastructures import Headers
        from open_webui.routers.files import upload_file_handler
        from open_webui.models.users import Users

        u = user
        if isinstance(user, dict):
            u = await Users.get_user_by_id(user.get("id"))  # get_user_by_id 는 async
        f = UploadFile(
            file=io.BytesIO(data),
            filename=filename,
            headers=Headers({"content-type": _MIME[ext]}),
        )
        # metadata 를 반드시 dict 로 넘긴다. 생략하면 기본값이 FastAPI Form(None)
        # 객체가 되어 내부 file_metadata.get(...) 에서 예외 → 400 "Error uploading file".
        item = await upload_file_handler(request, file=f, metadata={}, process=False, user=u)
        # url_path_for는 스킴/호스트가 없는 상대경로만 반환 — 채팅 밖(export한 마크다운 등)에서
        # file:// 로 오인되므로 url_for로 절대 URL(스킴+호스트 포함)을 사용한다.
        url = request.url_for("get_file_content_by_id", id=item.id)
        return f"[{filename}]({url})"

    def _safe(self, name: str, ext: str) -> str:
        base = re.sub(r"[^\w가-힣 .-]", "", (name or "document")).strip() or "document"
        return f"{base}.{ext}"

    # ── 도구 ─────────────────────────────────────────────────────────
    def list_document_templates(self) -> str:
        """생성 가능한 문서 종류와 사용 가능한 시각 테마(template) 목록을 알려준다. 문서 작성 전에 참고한다."""
        themes = _list_themes(self.valves.templates_dir) or ["default (코드 내장 폴백)"]
        first = themes[0].split(" ")[0]
        return (
            "문서 종류: report(보고서 docx), minutes(회의록 docx), "
            "slides(발표자료 pptx), spreadsheet(표 xlsx)\n"
            f"사용 가능한 테마(template): {', '.join(themes)}\n"
            f"예) create_report(..., template=\"{first}\") — 생략 시 default"
        )

    async def create_report(
        self, title: str, body_markdown: str, subtitle: str = "", author: str = "",
        template: str = "default", header: str = "", footer: str = "",
        __request__=None, __user__=None,
    ) -> str:
        """제목과 Markdown 본문으로 Word(.docx) 보고서를 만들어 다운로드 링크를 반환한다.

        :param title: 보고서 제목
        :param body_markdown: 본문. '# 대제목', '## 소제목', '- 불릿', '| a | b |' 표, **굵게** 지원.
            표 정렬은 구분선 ':---:'(가운데)/'---:'(오른쪽). 표 앞 '표: 캡션' / '너비: 2,5,3' 지시문 가능.
        :param subtitle: 부제(선택)
        :param author: 작성자(선택)
        :param template: 시각 테마 이름(list_document_templates 참고). 생략 시 default.
        :param header: 머리글 오른쪽 문구(선택, 예: '대외비', 문서번호)
        :param footer: 바닥글 왼쪽 문구(선택, 예: '© 2026 …')
        """
        data = build_report_docx(title, body_markdown, subtitle, author,
                                 self.valves.templates_dir or None, template,
                                 self.valves.org_name, self.valves.logo_path,
                                 header, footer, self.valves.table_style)
        return await self._save_and_link(__request__, __user__, data, self._safe(title, "docx"), "docx")

    async def create_minutes(
        self, title: str, meeting_date: str = "", location: str = "", attendees: str = "",
        author: str = "", agenda_markdown: str = "", decisions_markdown: str = "",
        action_items_table: str = "", template: str = "default", header: str = "", footer: str = "",
        __request__=None, __user__=None,
    ) -> str:
        """회의록 Word(.docx)를 만들어 다운로드 링크를 반환한다.

        :param title: 회의명
        :param meeting_date: 일시(예 2026-07-22 14:00)
        :param location: 장소
        :param attendees: 참석자(쉼표 구분)
        :param author: 작성자
        :param agenda_markdown: 안건 ('- ' 불릿 또는 문단)
        :param decisions_markdown: 결정 사항
        :param action_items_table: 액션아이템 표. 'markdown 표/CSV/TSV', 열=담당,내용,기한
        :param template: 시각 테마 이름(list_document_templates 참고). 생략 시 default.
        :param header: 머리글 오른쪽 문구(선택). :param footer: 바닥글 왼쪽 문구(선택).
        """
        data = build_minutes_docx(title, meeting_date, location, attendees, author,
                                  agenda_markdown, decisions_markdown, action_items_table,
                                  self.valves.templates_dir or None, template,
                                  self.valves.org_name, self.valves.logo_path,
                                  header, footer, self.valves.table_style)
        return await self._save_and_link(__request__, __user__, data, self._safe(title or "회의록", "docx"), "docx")

    async def create_slides(
        self, title: str, slides_markdown: str, subtitle: str = "",
        template: str = "default", __request__=None, __user__=None,
    ) -> str:
        """PowerPoint(.pptx) 발표자료를 만들어 다운로드 링크를 반환한다.

        :param title: 표지 제목
        :param slides_markdown: 슬라이드들을 '---' 로 구분. 각 슬라이드는 '# 제목' + '- 불릿'.
        :param subtitle: 표지 부제(선택)
        :param template: 시각 테마 이름(list_document_templates 참고). 생략 시 default.
        """
        data = build_slides_pptx(title, subtitle, slides_markdown,
                                 self.valves.templates_dir or None, template)
        return await self._save_and_link(__request__, __user__, data, self._safe(title, "pptx"), "pptx")

    async def create_spreadsheet(
        self, title: str, table_text: str, sheet_name: str = "Sheet1",
        __request__=None, __user__=None,
    ) -> str:
        """Excel(.xlsx) 표를 만들어 다운로드 링크를 반환한다.

        :param title: 파일명(제목)
        :param table_text: 표 데이터. 'markdown 표' 또는 CSV/TSV. 첫 행은 머리글.
        :param sheet_name: 시트 이름
        """
        data = build_table_xlsx(title, table_text, sheet_name)
        return await self._save_and_link(__request__, __user__, data, self._safe(title, "xlsx"), "xlsx")
