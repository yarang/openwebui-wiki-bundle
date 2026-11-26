#!/usr/bin/env python3
"""문서 생성기 Tool '등록 가이드' PPT 생성기.

산출물: docs/문서생성기-등록-가이드.pptx
실행:   "$PPTX_PY" docs/build_registration_guide.py   # python-pptx 가 들어 있는 아무 파이썬
"""
from __future__ import annotations

import re
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Inches, Pt

KR = "Apple SD Gothic Neo"
MONO = "Menlo"
ACCENT = RGBColor(0x2F, 0x5D, 0x8A)
INK = RGBColor(0x1A, 0x1A, 0x1A)
MUTED = RGBColor(0x6B, 0x72, 0x80)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
LIGHT = RGBColor(0xCF, 0xE0, 0xF0)
CODEBG = RGBColor(0xF2, 0xF4, 0xF7)
RULE = RGBColor(0xD0, 0xD5, 0xDD)

HERE = Path(__file__).resolve().parent
prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
W, H = prs.slide_width, prs.slide_height
BLANK = prs.slide_layouts[6]


def _rect(slide, shape, l, t, w, h, fill=None, line=None, line_w=0.75):
    sp = slide.shapes.add_shape(shape, l, t, w, h)
    sp.shadow.inherit = False
    if fill is None:
        sp.fill.background()
    else:
        sp.fill.solid(); sp.fill.fore_color.rgb = fill
    if line is None:
        sp.line.fill.background()
    else:
        sp.line.color.rgb = line; sp.line.width = Pt(line_w)
    return sp


def _runs(p, text, size, color, name=KR):
    """**굵게** 지원하는 run 추가."""
    for part in re.split(r"(\*\*.+?\*\*)", text):
        if not part:
            continue
        r = p.add_run()
        if part.startswith("**") and part.endswith("**"):
            r.text, r.font.bold = part[2:-2], True
        else:
            r.text = part
        r.font.size, r.font.color.rgb, r.font.name = Pt(size), color, name


def bar_slide(title, step=None):
    s = prs.slides.add_slide(BLANK)
    _rect(s, MSO_SHAPE.RECTANGLE, 0, 0, W, Inches(1.25), fill=ACCENT)
    tb = s.shapes.add_textbox(Inches(0.6), Inches(0.12), W - Inches(1.2), Inches(1.0))
    tf = tb.text_frame; tf.word_wrap = True
    if step is not None:
        p = tf.paragraphs[0]
        r = p.add_run(); r.text = f"STEP {step}"
        r.font.size, r.font.bold, r.font.color.rgb, r.font.name = Pt(12), True, LIGHT, KR
        tp = tf.add_paragraph()
    else:
        tp = tf.paragraphs[0]
    r = tp.add_run(); r.text = title
    r.font.size, r.font.bold, r.font.color.rgb, r.font.name = Pt(26), True, WHITE, KR
    return s


def body(s, top=1.65):
    tb = s.shapes.add_textbox(Inches(0.75), Inches(top), W - Inches(1.5), H - Inches(top) - Inches(0.5))
    tf = tb.text_frame; tf.word_wrap = True
    return tf


def bullet(tf, text, level=0, first=False, size=18, color=INK):
    p = tf.paragraphs[0] if first else tf.add_paragraph()
    p.level = level
    p.space_after = Pt(6)
    marker = "•  " if level == 0 else "–  "
    lead = p.add_run(); lead.text = ("      " * level) + marker
    lead.font.size, lead.font.color.rgb, lead.font.name = Pt(size), ACCENT if level == 0 else MUTED, KR
    _runs(p, text, size, color)
    return p


def code_box(s, left, top, width, height, text):
    box = _rect(s, MSO_SHAPE.ROUNDED_RECTANGLE, Inches(left), Inches(top), Inches(width), Inches(height),
                fill=CODEBG, line=RULE)
    tf = box.text_frame; tf.word_wrap = True
    tf.margin_left = Pt(12); tf.margin_top = Pt(8); tf.vertical_anchor = MSO_ANCHOR.TOP
    for i, ln in enumerate(text.split("\n")):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        r = p.add_run(); r.text = ln
        r.font.name, r.font.size, r.font.color.rgb = MONO, Pt(13), INK
    return box


# ── 표지 ─────────────────────────────────────────────────────────────────
s = prs.slides.add_slide(BLANK)
_rect(s, MSO_SHAPE.RECTANGLE, 0, Inches(3.05), W, Inches(0.09), fill=ACCENT)
tb = s.shapes.add_textbox(Inches(0.9), Inches(1.9), W - Inches(1.8), Inches(1.1))
p = tb.text_frame.paragraphs[0]
r = p.add_run(); r.text = "문서 생성기 Tool 등록 가이드"
r.font.size, r.font.bold, r.font.color.rgb, r.font.name = Pt(40), True, ACCENT, KR
tb2 = s.shapes.add_textbox(Inches(0.9), Inches(3.25), W - Inches(1.8), Inches(0.9))
p = tb2.text_frame.paragraphs[0]
r = p.add_run(); r.text = "Open WebUI · docx / pptx / xlsx 문서 생성 도구"
r.font.size, r.font.color.rgb, r.font.name = Pt(18), MUTED, KR
tb3 = s.shapes.add_textbox(Inches(0.9), Inches(6.6), W - Inches(1.8), Inches(0.5))
p = tb3.text_frame.paragraphs[0]
r = p.add_run(); r.text = "llm-wiki · document_generator v0.1.3"
r.font.size, r.font.color.rgb, r.font.name = Pt(12), MUTED, KR

# ── 개요 ─────────────────────────────────────────────────────────────────
s = bar_slide("개요 — 무엇을, 어떻게")
tf = body(s)
bullet(tf, "채팅에서 **Word 보고서·회의록, PowerPoint 발표자료, Excel 표**를 만들어 다운로드", first=True)
bullet(tf, "모델이 요청을 이해하고 도구를 자동 호출 → **다운로드 링크** 반환")
bullet(tf, "등록은 4단계 (Tool 은 Open WebUI DB 에 저장됨)")
bullet(tf, "STEP 0  사전 준비 — 파일 반입 + 라이브러리 설치", level=1)
bullet(tf, "STEP 1  Tool 등록 — 코드 붙여넣기", level=1)
bullet(tf, "STEP 2  Valve 설정 — 테마 경로", level=1)
bullet(tf, "STEP 3  모델에 연결 → STEP 4  확인", level=1)

# ── STEP 0 ───────────────────────────────────────────────────────────────
s = bar_slide("사전 준비 — 파일 반입 · 라이브러리", step=0)
tf = body(s)
bullet(tf, "에어갭 키트 `docgen-addon-<버전>.tar.gz` 를 대상 장비로 반입 후 압축 해제", first=True)
bullet(tf, "설치된 번들 루트를 인자로 apply 실행 (파일 복사 + python-docx 오프라인 설치)")
code_box(s, 0.75, 3.4, 11.8, 1.0, "tar -xzf docgen-addon-0.1.3.tar.gz\n./docgen-addon-0.1.3/apply-docgen.sh /설치된/번들/루트")
bullet(body(s, top=4.7), "완료 메시지에 `import OK — python-docx …` 가 보이면 준비 끝", first=True, size=16, color=MUTED)

# ── STEP 1 ───────────────────────────────────────────────────────────────
s = bar_slide("Tool 등록 — 코드 붙여넣기", step=1)
tf = body(s)
bullet(tf, "Open WebUI → 좌측 **Workspace → Tools**", first=True)
bullet(tf, "우측 상단 **➕ (Create Tool)** 클릭")
bullet(tf, "`open-webui-tools/document_generator.py` **전체 내용**을 복사해 붙여넣기")
bullet(tf, "상단 `\"\"\"title: 문서 생성기 …\"\"\"` 부터 끝까지 전부", level=1, size=16, color=MUTED)
bullet(tf, "이름·설명 자동 인식 → **Save**")
bullet(tf, "⚠ 갱신 시에도 '파일 교체'가 아니라 **편집 화면에서 재붙여넣기 + Save** (DB 저장)", color=ACCENT)

# ── STEP 2 ───────────────────────────────────────────────────────────────
s = bar_slide("Valve 설정 — 테마 경로", step=2)
tf = body(s)
bullet(tf, "등록된 '문서 생성기' Tool 의 **⚙️ Valves** 열기", first=True)
bullet(tf, "**templates_dir** = 번들 안 `document-templates` **절대경로**")
code_box(s, 0.75, 3.2, 11.8, 0.7, "/Users/…/openwebui-wiki-bundle-…/document-templates")
tf2 = body(s, top=4.2)
bullet(tf2, "비워두면 코드 내장 기본 테마로 동작 (파일 테마·테마 추가 기능은 사용 불가)", first=True, size=16, color=MUTED)

# ── STEP 3 ───────────────────────────────────────────────────────────────
s = bar_slide("모델에 연결 — 도구 활성화", step=3)
tf = body(s)
bullet(tf, "도구는 **모델에 붙여야** 채팅에서 호출됩니다. 둘 중 하나:", first=True)
bullet(tf, "**간단** — 채팅 입력창의 도구(🔧) 아이콘에서 '문서 생성기' 켜기", level=1)
bullet(tf, "그 대화에만 적용", level=1, size=15, color=MUTED)
bullet(tf, "**권장(전용 모델)** — Workspace → Models → ➕ 로 '문서 작성 도우미' 생성", level=1)
bullet(tf, "Tools 에서 문서 생성기 활성화 + System Prompt 로 작성 규칙 지정", level=1, size=15, color=MUTED)
bullet(tf, "드롭다운에서 골라 쓰면 항상 도구가 붙어 나옴", level=1, size=15, color=MUTED)

# ── STEP 4 ───────────────────────────────────────────────────────────────
s = bar_slide("확인 — 동작 테스트", step=4)
tf = body(s)
bullet(tf, "채팅에 아래처럼 입력해 봅니다", first=True)
code_box(s, 0.75, 2.5, 11.8, 1.5,
         "list_document_templates 로 어떤 양식 있는지 알려줘\n"
         "→ 문서 종류·테마 목록이 나오면 등록 성공\n\n"
         "이 내용을 보고서로 만들어줘 …\n"
         "→ [파일.docx](/api/v1/files/…/content) 다운로드 링크가 나오면 완료")

# ── 문제 해결 ────────────────────────────────────────────────────────────
s = bar_slide("문제 해결")
rows = [
    ("증상", "조치"),
    ("도구가 채팅에 안 보임", "Save 확인 + STEP 3(모델에 연결) 수행 여부 확인"),
    ("No module named 'docx'", "라이브러리 미설치 → apply-docgen.sh 재실행"),
    ("400 Error uploading file", "0.1.2+ 버전으로 재붙여넣기 (metadata 수정본)"),
    ("표/제목이 리터럴 ** | 로 나옴", "0.1.2+ 로 교체 (마크다운 변환 반영)"),
    ("테마 선택이 안 먹음", "Valve templates_dir 이 실제 절대경로인지 확인"),
]
tbl = s.shapes.add_table(len(rows), 2, Inches(0.75), Inches(1.7), Inches(11.8), Inches(4.6)).table
tbl.columns[0].width = Inches(4.3); tbl.columns[1].width = Inches(7.5)
for ri, (a, b) in enumerate(rows):
    for ci, txt in enumerate((a, b)):
        cell = tbl.cell(ri, ci)
        cell.text = ""
        p = cell.text_frame.paragraphs[0]
        r = p.add_run(); r.text = txt
        r.font.name, r.font.size = KR, Pt(14)
        if ri == 0:
            r.font.bold, r.font.color.rgb = True, WHITE
            cell.fill.solid(); cell.fill.fore_color.rgb = ACCENT
        else:
            r.font.color.rgb = INK

# ── 마무리 ───────────────────────────────────────────────────────────────
s = bar_slide("참고")
tf = body(s)
bullet(tf, "상세 문서: `docs/DOCUMENT-TOOL.md` (등록 · 테마 추가 · 문제 해결)", first=True)
bullet(tf, "사용법: 채팅에서 자연어로 요청 → 보고서/회의록/발표자료/표")
bullet(tf, "테마 추가: `document-templates/` 에 `theme-<이름>.docx` 넣기")
bullet(tf, "재배포: 사내 Git 서버 Release `docgen-v<버전>`")

out = HERE / "문서생성기-등록-가이드.pptx"
prs.save(str(out))
print(f"생성됨: {out.name} ({len(prs.slides._sldIdLst)} slides)")
