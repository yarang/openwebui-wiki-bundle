"""pptx skill 도구 — PowerPoint(PPTX) 문서 읽기·만들기. 출력 규약: 성공은 첫 줄
`OK <절대 경로>`, 실패는 첫 줄 `ERROR <사유>` + exit 1(사용법 오류는 2). Traceback 은 절대 출력하지 않는다."""
from __future__ import annotations
import os, re, sys, tempfile, warnings, xml.etree.ElementTree as ET, zipfile, zlib
from pathlib import Path
warnings.filterwarnings("ignore")
sys.dont_write_bytecode = True
try:
    from pptx import Presentation
    from pptx.oxml.ns import qn
    from pptx.util import Pt
    _PPTX_IMPORT_ERROR = None
except Exception as _exc:  # pragma: no cover - 번들 미설치 환경
    Presentation = None
    qn = None
    Pt = None
    _PPTX_IMPORT_ERROR = _exc

# 일부 작성 규칙(글자 크기 명시, '* '·'• ' 글머리, 넘침·자리 표시 경고)은 anthropics/skills
# (https://github.com/anthropics/skills, commit 2c5958ecac7cee2b583967a2c4981d0f4a75c579, Apache-2.0)의 pptx 지침을 참고했다.

MAX_CHARS_DEFAULT = 6000
MAX_INPUT_MB = 50
MAX_UNCOMPRESSED_MB = 200
MAX_MD_BYTES = 5 * 1024 * 1024  # from-md 입력 마크다운 상한(읽기 전에 검사)
MAX_TABLE_COLUMNS = 75    # PowerPoint 표 최대 열 수
MAX_TABLE_CELLS = 100000  # 표를 만들 때 칸 수 상한(메모리 폭주 방지)
MAX_BULLET_LEVEL = 8      # PowerPoint 문단 수준 상한
MAX_BODY_ITEMS = 8        # 본문 항목(글머리+일반+###)이 이보다 많으면 슬라이드 나누기 경고
MAX_TABLE_WARN_ROWS = 12  # 표 행(머리 행 포함)이 이보다 많으면 넘침 경고
# from-md 가 모든 run 에 명시하는 글자 크기(pt). 레이아웃 상속을 따르면 환경마다 달라 보이므로 직접 정한다.
SIZE_COVER_TITLE, SIZE_COVER_SUB, SIZE_SLIDE_TITLE = 44, 24, 36
SIZE_BODY, SIZE_SUBBODY, SIZE_CELL = 20, 18, 16
MB = 1024 * 1024
# zip 항목을 풀다가 나올 수 있는 '깨진 파일' 신호들. 내부 오류가 아닌 안내로 바꾼다.
CORRUPT_ZIP_ERRORS = (zipfile.BadZipFile, zlib.error, EOFError, RuntimeError, KeyError)
# XML 이 불허하는 제어 문자(탭 \t·줄바꿈 \n \r 은 제외)와 유니코드 비문자는 조용히 지운다.
XML_ILLEGAL_RE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")
# 16:9 너비(12192000) 와 기본 서식 4:3 너비(9144000) 의 비. 마스터·레이아웃 자리표시자 x/cx 를 이 배율로 늘린다.
SLIDE_WIDE = 12192000
SLIDE_HIGH = 6858000
WIDE_SCALE = SLIDE_WIDE / 9144000
BODY_LEFT = 609600        # 스케일 뒤 본문 여백(0.667in)
BODY_WIDTH = 10972800     # 스케일 뒤 본문 폭(12in)
ZIP_MAGIC = b"PK\x03\x04"
OLE_MAGIC = bytes.fromhex("D0CF11E0A1B11AE1")
OLE_PPT_MSG = "구형 PowerPoint(.ppt) 파일입니다. PowerPoint 에서 .pptx 로 다시 저장해 주세요"
USAGE = """pptx — PowerPoint(PPTX) 문서 도구
사용법: pptx read <파일.pptx> [--max-chars N] / from-md <in.md> [out.pptx] / --help
from-md 지원 문법: # 첫 제목(표지 슬라이드), ## 제목(슬라이드), ### 소제목(굵은 문단),
  - · * · • 글머리(들여쓰기 두 칸마다 수준 1), Markdown 표(| a | b |), **굵게**.
from-md 는 모든 글자에 크기를 명시한다. 본문이 지나치게 많거나 표가 크면, 남은 자리 표시가 있으면
  '경고' 줄을 OK 뒤에 덧붙인다(파일은 만들고 종료 코드는 그대로 0).
쓰기 명령의 출력 경로는 입력과 같거나 이미 존재하면 거부한다. 성공 시 첫 줄이 `OK <경로>`, 실패 시 `ERROR <사유>`."""

class ToolError(Exception):
    """ERROR 한 줄로 바꿔 출력할 사용자 단 예외."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message); self.message, self.code = message, code

def emit(*lines: str) -> None:
    print("\n".join(lines))

def one_line(text: str) -> str:
    """줄바꿈·연속 공백을 한 칸 공백으로 눌러 한 줄로 만든다."""
    return " ".join(str(text).split())

def strip_illegal_chars(text: str) -> str:
    """PDF 에서 붙여 넣은 제어 문자 등 XML 에 넣을 수 없는 글자는 문서를 만들기 전에 지운다."""
    return XML_ILLEGAL_RE.sub("", text)

def reject_control_chars(raw: str) -> None:
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw): raise ToolError("경로에 줄바꿈 등 제어 문자가 있습니다")

def ensure_input(raw: str) -> Path:
    reject_control_chars(raw)
    path = Path(raw)
    if not path.is_file(): raise ToolError(f"파일 없음: {raw}")
    check_input_size(path, raw)
    return path

def check_input_size(path: Path, raw: str) -> None:
    """입력 크기 제한: 파일 50MB, zip 압축 해제 합계 200MB(파싱 전에 검사)."""
    try: size = path.stat().st_size
    except OSError as exc:
        raise ToolError(f"파일을 읽을 수 없습니다({exc.strerror or '권한 확인'}): {raw}") from exc
    if size > MAX_INPUT_MB * MB: raise ToolError(f"파일이 너무 큽니다: {raw} (최대 {MAX_INPUT_MB}MB)")
    if sniff_format(path, raw) != "zip": return
    try:
        with zipfile.ZipFile(path) as zf: total = sum(info.file_size for info in zf.infolist())
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"pptx 파일이 손상되었습니다: {raw}") from exc
    if total > MAX_UNCOMPRESSED_MB * MB:
        raise ToolError(f"파일이 너무 큽니다: 압축을 풀면 {(total + MB - 1) // MB}MB, 최대 {MAX_UNCOMPRESSED_MB}MB")

def logical_cwd() -> Path:
    """셸이 보는 논리 작업 폴더. PWD 가 실제 작업 폴더와 같은 곳일 때만 믿는다(/tmp → /private/tmp 심볼릭 링크 차이 방지)."""
    pwd = os.environ.get("PWD")
    if pwd and pwd.startswith("/") and os.path.realpath(pwd) == os.getcwd(): return Path(pwd)
    return Path.cwd()

def to_absolute(raw: str) -> Path:
    """상대 경로를 논리 작업 폴더 기준 절대 경로로 바꾼다(셸 이력과 같은 문자열 유지)."""
    path = Path(raw)
    return path if path.is_absolute() else logical_cwd() / path

def check_output_target(out_raw: str, in_raw: str) -> Path:
    reject_control_chars(out_raw)
    out_abs = to_absolute(out_raw)
    if not str(out_abs).lower().endswith(".pptx"):
        raise ToolError(f"출력 파일 확장자는 .pptx 여야 합니다: {out_raw}")
    if in_raw and out_abs == to_absolute(in_raw): raise ToolError(f"출력 경로가 입력과 같습니다: {out_raw}")
    if os.path.lexists(out_abs): raise ToolError(f"출력 경로가 이미 존재합니다: {out_raw}")
    if not out_abs.parent.is_dir(): raise ToolError(f"출력 폴더가 없습니다: {out_abs.parent}")
    return out_abs

def read_utf8(raw: str) -> str:
    """from-md 입력 마크다운을 읽는다: 5MB 초과는 읽기 전에 거부, BOM 은 떼고, 권한 오류는 안내로."""
    path = Path(raw)
    try:
        if path.stat().st_size > MAX_MD_BYTES:
            raise ToolError(f"입력 파일이 너무 큽니다: {raw} (최대 5MB)")
        return path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        raise ToolError(f"UTF-8 텍스트 파일이 아닙니다: {raw}")
    except ToolError:
        raise
    except OSError as exc:
        raise ToolError(f"파일을 읽을 수 없습니다({exc.strerror or '권한 확인'}): {raw}") from exc

def sniff_format(path: Path, raw: str) -> str | None:
    """확장자 대신 앞 바이트로 형식을 판별한다: zip(OOXML) / ole(구형 복합 문서) / None. 열 수 없으면 권한 안내로 바꾼다."""
    try:
        with open(path, "rb") as fh: head = fh.read(8)
    except OSError as exc:
        raise ToolError(f"파일을 읽을 수 없습니다({exc.strerror or '권한 확인'}): {raw}") from exc
    if head.startswith(ZIP_MAGIC): return "zip"
    if head.startswith(OLE_MAGIC): return "ole"
    return None

# OOXML 패키지 관계 부품(`_rels/.rels`) 의 XML 네임스페이스와, officeDocument 관계의 Target 접두어 → 문서 종류.
# [Content_Types].xml 문자열 검색은 문서 안에 붙여 넣은 다른 오피스 파일(embeddings/…)에 속으므로 쓰지 않는다.
RELS_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"
OOXML_TARGET_KINDS = (("word/", "docx"), ("xl/", "xlsx"), ("ppt/", "pptx"))

def ooxml_kind_from_rels(zf: zipfile.ZipFile) -> str | None:
    """`_rels/.rels` 의 officeDocument 관계 Target 경로로 본 문서 종류를 가린다. 정규식이 아니라 XML 로
    파싱하므로 작은따옴표 속성·접두어 붙은 요소(<pr:Relationship …>)로 쓰인 패키지도 알아본다. 판별 못 하면 None."""
    if "_rels/.rels" not in zf.namelist(): return None
    try:
        root = ET.fromstring(zf.read("_rels/.rels"))
    except (ET.ParseError, ValueError, LookupError):
        return None  # XML 로 읽히지 않으면 종류를 모른다(호출자가 알맞은 ERROR 로 바꾼다; 모르는 encoding 은 LookupError)
    for rel in root.iter(f"{RELS_NS}Relationship"):
        rel_type, target = rel.get("Type"), rel.get("Target")
        if rel_type is None or target is None: continue
        if not rel_type.rstrip("/").endswith("/officeDocument"): continue
        target = target.lstrip("/").lower()
        for prefix, kind in OOXML_TARGET_KINDS:
            if target.startswith(prefix): return kind
    return None

def detect_ooxml_kind(path: Path, raw: str) -> str | None:
    """zip 이면 `_rels/.rels` 의 officeDocument 관계 Target 으로 문서 종류를 가린다. 판별 불가면 None."""
    try:
        with zipfile.ZipFile(path) as zf:
            return ooxml_kind_from_rels(zf)
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"pptx 파일이 손상되었습니다: {raw}") from exc

def open_document(raw: str):
    """읽기 전 안내: 구형 OLE(.ppt) · zip 아님 · OOXML 아님 · 다른 오피스 문서 · 손상."""
    path = Path(raw)
    fmt = sniff_format(path, raw)
    if fmt == "ole": raise ToolError(f"{OLE_PPT_MSG}: {raw}")
    if fmt is None: raise ToolError(f"PowerPoint(pptx) 파일이 아닙니다: {raw}")
    kind = detect_ooxml_kind(path, raw)
    if kind is None: raise ToolError(f"OOXML(pptx) 파일이 아닙니다: {raw}")
    if kind != "pptx": raise ToolError(f"이 파일은 {kind} 문서입니다. {kind} 스킬을 사용해 주세요: {raw}")
    if Presentation is None: raise ToolError(f"python-pptx import 실패: {_PPTX_IMPORT_ERROR}")
    try:
        return Presentation(str(path))
    except Exception as exc:
        raise ToolError(f"pptx 파일을 열지 못했습니다(손상되었을 수 있음): {raw}") from exc

def require_pptx() -> None:
    if Presentation is None: raise ToolError(f"python-pptx import 실패: {_PPTX_IMPORT_ERROR}")

# `**굵게**` 는 별표 바로 뒤·앞에 공백이 없을 때만 굵게다(`2 ** 3` 제외).
BOLD_RE = re.compile(r"\*\*(?!\s)(.+?)(?<!\s)\*\*")

def split_bold(text: str) -> list[tuple[str, bool]]:
    """짝이 맞는 `**굵게**` 만 굵게 나누고, 남는 `**` 는 글자 그대로 둔다."""
    pieces, pos = [], 0
    for match in BOLD_RE.finditer(text):
        if match.start() > pos: pieces.append((text[pos:match.start()], False))
        pieces.append((match.group(1), True)); pos = match.end()
    if pos < len(text) or not pieces: pieces.append((text[pos:], False))
    return pieces

def strip_bold(text: str) -> str:
    return BOLD_RE.sub(r"\1", text)

def parse_table_row(line: str) -> list[str]:
    r"""표 행을 칸으로 나눈다. \| 는 칸 구분이 아니라 글자 | 다."""
    s = line.strip()
    if s.startswith("|"): s = s[1:]
    if re.search(r"(?<!\\)\|$", s): s = s[:-1]
    return [cell.strip().replace("\\|", "|") for cell in re.split(r"(?<!\\)\|", s)]

def is_separator_row(line: str) -> bool:
    cells = parse_table_row(line)
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", c) for c in cells)

def check_table_size(rows: list[list[str]]) -> None:
    """표를 만들기 전에 한계 검사: 칸을 채운(패딩) 뒤의 실제 칸 수(행 수 × 최대 열 수)로 거부한다.
    짧은 행도 최대 열 수만큼 채워지므로, 입력이 준 칸 합계가 아니라 이 값이 실제로 만들어질 칸 수다."""
    cols = max(len(row) for row in rows)
    if cols > MAX_TABLE_COLUMNS:
        raise ToolError(f"표가 너무 넓습니다(열 {cols}개, 최대 {MAX_TABLE_COLUMNS}개). 표를 나눠 주세요")
    total = len(rows) * cols
    if total > MAX_TABLE_CELLS:
        raise ToolError(f"표가 너무 큽니다(칸 {total}개, 최대 {MAX_TABLE_CELLS}개). 표를 나눠 주세요")

def parse_md_table(block: list[str]) -> list[list[str]] | None:
    """`머리 행 + 구분선` 꼴(2줄 이상)의 블록만 표로 본다. 표일 때 첫 줄이 머리 행, 셋째 줄부터는 구분선 모양이어도 모두 데이터 행으로 둔다. 아니면 None."""
    if len(block) < 2 or is_separator_row(block[0]) or not is_separator_row(block[1]): return None
    rows = [parse_table_row(line) for line in [block[0]] + block[2:]]
    check_table_size(rows)
    cols = max(len(row) for row in rows)
    return [row + [""] * (cols - len(row)) for row in rows]

# ─── markdown → pptx ────────────────────────────────────────────────────────────

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
HR_RE = re.compile(r"-{3,}")
# 글머리 기호는 '- ', '* ', '• ' 셋 다 같게(들여쓰기 두 칸마다 수준 1). 기호 뒤에 공백이 필요하므로
# '**굵게** 줄'은 글머리가 아니라 일반 문단이다.
BULLET_RE = re.compile(r"^(\s*)(?:-|\*|•)\s+(.*)$")

def parse_slides(text: str) -> list[dict]:
    """마크다운 줄을 슬라이드 목록으로 나눈다. 첫 헤딩이 # 이면 표지 슬라이드, 그 뒤 #/## 마다
    내용 슬라이드다. ### 는 굵은 수준 0 문단(표지에서는 부제목 글), --- 만 있는 줄과 빈 줄은 무시한다."""
    slides: list[dict] = []
    cur: dict | None = None
    seen_heading = False
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        s = line.strip()
        if not s or HR_RE.fullmatch(s):
            i += 1
            continue
        match = HEADING_RE.match(s)
        if match:
            level, title_text = len(match.group(1)), match.group(2)
            if level <= 2:
                if level == 1 and not seen_heading:
                    cur = {"kind": "title", "title": strip_bold(title_text).strip(), "subtitle": [], "items": []}
                else:
                    cur = {"kind": "content", "title": strip_bold(title_text).strip(), "subtitle": [], "items": []}
                slides.append(cur)
                seen_heading = True
            elif cur is not None:
                # 표지의 ### 는 부제목에 글(text) 로 넣는다(부제목은 문자열 목록). 본문의 ### 는 굵은 문단 항목.
                target = cur["subtitle"] if cur["kind"] == "title" else cur["items"]
                target.append(title_text if cur["kind"] == "title" else ("h3", title_text))
            i += 1
            continue
        if s.startswith("|"):
            block = []
            while i < len(lines) and lines[i].strip().startswith("|"): block.append(lines[i].strip()); i += 1
            if cur is not None:
                if cur["kind"] == "title": cur["subtitle"].extend(block)
                else:
                    rows = parse_md_table(block)
                    if rows is not None: cur["items"].append(("table", rows))
                    else: cur["items"].extend(("plain", b) for b in block)  # 구분선 없는 | 줄은 표가 아닌 본문 문단
            continue
        if cur is None:
            i += 1
            continue
        if cur["kind"] == "title":
            cur["subtitle"].append(s)
        else:
            bullet = BULLET_RE.match(line)
            if bullet: cur["items"].append(("bullet", min(len(bullet.group(1)) // 2, MAX_BULLET_LEVEL), bullet.group(2)))
            else: cur["items"].append(("plain", s))
        i += 1
    return slides

def add_runs(para, pieces, size_pt: int) -> None:
    """run 조각을 문단에 넣되 크기를 항상, 굵게는 **조각** 에만 명시한다."""
    for text, bold in pieces:
        if text == "": continue
        run = para.add_run()
        run.text = text
        run.font.size = Pt(size_pt)
        if bold: run.font.bold = True

def item_pieces(item) -> tuple[int, list]:
    """본문 항목을 (문단 수준, run 조각) 으로: 글머리는 들여쓰기 두 칸마다 수준 1, 일반 줄은 수준 0
    (글자 그대로), ### 소제목은 수준 0 에 모든 run 굵게."""
    if item[0] == "bullet": return item[1], split_bold(item[2])
    if item[0] == "plain": return 0, split_bold(item[1])
    if item[0] == "h3": return 0, [(seg, True) for seg, _ in split_bold(item[1])]
    return 0, [(str(item), False)]

def body_size(level: int) -> int:
    """본문 글자 크기: 수준 0 은 20pt, 들여 쓴 항목(수준 1 이상)은 18pt."""
    return SIZE_BODY if level == 0 else SIZE_SUBBODY

def fill_paragraphs(tf, items) -> None:
    tf.clear()
    first = True
    for item in items:
        para = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        level, pieces = item_pieces(item)
        para.level = level
        add_runs(para, pieces, body_size(level))

def placeholder_by_idx(slide, idx):
    for ph in slide.placeholders:
        if ph.placeholder_format.idx == idx: return ph
    return None

def set_title(slide, text: str, size_pt: int) -> None:
    """제목 자리표시자에 한 run 으로 넣고 크기·굵게를 명시한다(read 는 제목의 보통 글자만 본다)."""
    title = slide.shapes.title
    if title is None: return
    title.text_frame.text = text
    for run in title.text_frame.paragraphs[0].runs:
        run.font.size = Pt(size_pt); run.font.bold = True

def scale_widescreen(prs) -> None:
    """기본 서식은 4:3 이라 그 자리표시자가 왼쪽 3/4 에 남는다. 마스터·모든 레이아웃의 a:off/@x 와
    a:ext/@cx 에 16:9 배율(4/3) 을 곱한다(높이는 그대로). add_slide 는 레이아웃 자리표시자를
    복사하므로, 이 작업을 먼저 끝내야 슬라이드도 넓어진 위치를 가진다."""
    master = prs.slide_masters[0]
    for element in [master.element] + [layout.element for layout in master.slide_layouts]:
        for off in element.iter(qn("a:off")):
            try: off.set("x", str(int(round(int(off.get("x")) * WIDE_SCALE))))
            except (TypeError, ValueError): pass
        for ext in element.iter(qn("a:ext")):
            try: ext.set("cx", str(int(round(int(ext.get("cx")) * WIDE_SCALE))))
            except (TypeError, ValueError): pass

def add_title_slide(prs, spec) -> None:
    slide = prs.slides.add_slide(prs.slide_layouts[0])  # Title Slide
    set_title(slide, spec["title"], SIZE_COVER_TITLE)
    subtitle = placeholder_by_idx(slide, 1)
    if subtitle is not None and spec["subtitle"]:
        tf = subtitle.text_frame
        tf.clear()
        first = True
        for line in spec["subtitle"]:
            para = tf.paragraphs[0] if first else tf.add_paragraph()
            first = False
            add_runs(para, split_bold(line), SIZE_COVER_SUB)

def add_content_slide(prs, spec) -> None:
    slide = prs.slides.add_slide(prs.slide_layouts[1])  # Title and Content
    set_title(slide, spec["title"], SIZE_SLIDE_TITLE)
    body = placeholder_by_idx(slide, 1)
    if body is None:
        body = slide.shapes.add_textbox(BODY_LEFT, 1600200, BODY_WIDTH, 4525963)
    fill_paragraphs(body.text_frame, spec["items"])

def add_table_slide(prs, spec) -> None:
    slide = prs.slides.add_slide(prs.slide_layouts[5])  # Title Only
    set_title(slide, spec["title"], SIZE_SLIDE_TITLE)
    bullets = [item for item in spec["items"] if item[0] != "table"]
    tables = [item[1] for item in spec["items"] if item[0] == "table"]
    titles = slide.shapes.title
    top = titles.top + titles.height if titles is not None and titles.top is not None else 1417638
    top = max(top + 91440, 1600200)
    box_height = max(1, len(bullets)) * 320040 + 91440
    if bullets:
        box = slide.shapes.add_textbox(BODY_LEFT, top, BODY_WIDTH, box_height)
        box.text_frame.word_wrap = True
        fill_paragraphs(box.text_frame, bullets)
    else:
        top -= box_height  # 글머리가 없으면 표를 제목 바로 아래로 올린다
    table_top = top + box_height + 91440
    for rows in tables:
        if not rows: continue
        height = max(len(rows) * 330200, 330200)
        frame = slide.shapes.add_table(len(rows), len(rows[0]), BODY_LEFT, table_top, BODY_WIDTH, height)
        for r, row in enumerate(rows):
            for c, cell_text in enumerate(row):
                para = frame.table.cell(r, c).text_frame.paragraphs[0]
                pieces = [(seg, True) for seg, _ in split_bold(cell_text)] if r == 0 else split_bold(cell_text)
                add_runs(para, pieces, SIZE_CELL)
        table_top += height + 91440

# a:rPr 자식은 스키마 순서(ln, 채움, 효과, …, latin, ea, cs, …) 를 지켜야 한다. 어기면 PowerPoint 가
# 복구 창을 띄운다. a:ea 는 a:latin 뒤·cs/sym/hlink* 앞에 들어간다.
RPR_ORDER = ["ln", "noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill", "effectLst", "effectDag",
             "highlight", "uLnTx", "uLn", "uFillTx", "uFill", "latin", "ea", "cs", "sym", "hlinkClick",
             "hlinkMouseOver", "rtl", "extLst"]
EA_TYPEFACE = "맑은 고딕"

def ensure_east_asia_font(run_element) -> None:
    """run(a:r) 에 a:rPr 이 없으면 만들고, a:ea(동아시아 글꼴) 를 스키마 순서 위치에 넣는다."""
    rpr = run_element.find(qn("a:rPr"))
    if rpr is None:
        rpr = run_element.makeelement(qn("a:rPr"), {})
        run_element.insert(0, rpr)
    ea = rpr.find(qn("a:ea"))
    if ea is None:
        ea = rpr.makeelement(qn("a:ea"), {})
        pos = len(rpr)
        for index, child in enumerate(rpr):
            name = child.tag.rsplit("}", 1)[-1]
            rank = RPR_ORDER.index(name) if name in RPR_ORDER else len(RPR_ORDER)
            if rank > RPR_ORDER.index("ea"): pos = index; break
        rpr.insert(pos, ea)
    ea.set("typeface", EA_TYPEFACE)

def build_presentation(slides: list[dict]):
    require_pptx()
    prs = Presentation()
    prs.slide_width = SLIDE_WIDE
    prs.slide_height = SLIDE_HIGH
    scale_widescreen(prs)
    for spec in slides:
        if spec["kind"] == "title": add_title_slide(prs, spec)
        elif any(item[0] == "table" for item in spec["items"]): add_table_slide(prs, spec)
        else: add_content_slide(prs, spec)
    for slide in prs.slides:
        for run_element in slide.shapes._spTree.iter(qn("a:r")):
            ensure_east_asia_font(run_element)
    return prs

def save_pptx(prs, out_abs: Path) -> None:
    """임시 파일에 저장한 뒤 umask 권한으로 하드 링크 게시. 실패해도 출력 경로는 남기지 않는다."""
    fd, tmp_name = tempfile.mkstemp(dir=str(out_abs.parent), prefix=".pptx-", suffix=".tmp")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        prs.save(str(tmp))
        mask = os.umask(0); os.umask(mask)
        os.chmod(tmp, 0o666 & ~mask)
        try: os.link(str(tmp), str(out_abs))
        except FileExistsError: raise ToolError(f"출력 경로가 이미 존재합니다: {out_abs}")
    finally:
        if os.path.lexists(tmp): tmp.unlink(missing_ok=True)

# ─── from-md 경고(결과물은 그대로 만들고, OK 줄 뒤에 덧붙인다) ────────────────────

# 다듬지 않은 초안 표시: 빈 선택란, [입력…]·[여기…] 대괄호 자리 표시, TODO, lorem/ipsum/xxx, ○○.
# 자유 형식: [기획 1월 금액]·[담당자 이름] 같은 값 이름 끝 대괄호, [목표 1] 류 번호 붙은 대괄호(링크 [이름](…)·[이름][ref], 쌍점 든 참고·별첨 대괄호 제외).
PLACEHOLDER_RE = re.compile(
    r"\[\s*\]"                                      # [ ]  []
    r"|\[(?:(?i:insert)|입력|내용|여기)[^\]\n]{0,30}\]"   # [insert …] [입력…] [내용 입력] [여기에 부제]
    r"|\[[^\[\]\n:]{0,30}(?:금액|액수|이름|성함|성명|회사명|기관명|부서명|날짜|일자|일시|시작일|종료일|마감일|숫자|수치|연락처|전화번호|이메일|주소)(?:[ \t]?\d{1,2})?[ \t]?\](?![(\[])"   # [기획 1월 금액] [담당자 이름] [회사명] [이름 2] — 쌍점 든 대괄호 제외
    r"|\[[^\[\]\n:]{0,30}(?:업무|항목|목표|사항|내용)[ \t]?\d{1,2}[ \t]?\](?![(\[])"   # [목표 1] [이번 주 완료한 업무 2] — 번호 필수([주요 업무] 등 소제목 제외)
    r"|(?<![A-Za-z])TODO(?![A-Za-z])"               # TODO (case-sensitive; matches 확인TODO, not TODOS)
    r"|(?<![A-Za-z])(?i:lorem|ipsum|xxx)(?![A-Za-z])"
    r"|○○")

def overflow_warnings(slides: list[dict]) -> list[str]:
    """슬라이드마다: 본문 항목(표 제외)이 8개를 넘으면, 표가 12행(머리 포함)을 넘으면 경고 줄.
    표지는 세지 않고, 슬라이드 번호는 표지를 포함해 1부터 센다."""
    warns: list[str] = []
    for number, spec in enumerate(slides, 1):
        if spec["kind"] != "content": continue
        count = sum(1 for item in spec["items"] if item[0] != "table")
        if count > MAX_BODY_ITEMS:
            warns.append(f"경고 슬라이드 {number}: 글머리 {count}개 — 한 슬라이드에 6개 안팎이 읽기 좋습니다. 슬라이드를 나누세요")
        for item in spec["items"]:
            if item[0] == "table" and len(item[1]) > MAX_TABLE_WARN_ROWS:
                warns.append(f"경고 슬라이드 {number}: 표 {len(item[1])}행 — 화면 밖으로 넘칠 수 있습니다. 표를 나누세요")
    return warns

def placeholder_warning(text: str) -> str | None:
    """입력 마크다운에 남은 자리 표시 토큰을 처음 나온 순서로 최대 5개 모아 한 줄로. 없으면 None.
    토큰 안 줄바꿈·겹친 공백은 중복 제거 전에 한 칸으로 눌러([\n ] → [ ]) 비교·표시를 통일한다."""
    tokens: list[str] = []
    seen: set[str] = set()
    for match in PLACEHOLDER_RE.finditer(text):
        token = " ".join(match.group(0).split())
        if token not in seen:
            seen.add(token); tokens.append(token)
            if len(tokens) >= 5: break
    if not tokens: return None
    return one_line("경고 자리 표시가 남아 있음: " + ", ".join(tokens) + " — 실제 내용으로 채우거나 사용자에게 물어보세요")

def cmd_from_md(argv: list[str]) -> int:
    if len(argv) == 1:  # 출력 경로를 줄이면 입력 md 의 확장자만 바꾼 경로(상대 경로는 상대 그대로)
        argv = [argv[0], str(Path(argv[0]).with_suffix(".pptx"))]
    if len(argv) != 2: raise ToolError("사용법: pptx from-md <in.md> [out.pptx]", 2)
    in_raw, out_raw = argv
    ensure_input(in_raw)
    out_abs = check_output_target(out_raw, in_raw)
    text = strip_illegal_chars(read_utf8(in_raw))
    if not text.strip(): raise ToolError(f"마크다운 내용이 비어 있습니다: {in_raw}")
    slides = parse_slides(text)
    if not slides: raise ToolError("마크다운에 슬라이드가 없습니다(# 또는 ## 제목이 필요합니다)")
    prs = build_presentation(slides)
    save_pptx(prs, out_abs)
    lines = [f"OK {out_abs}", f"슬라이드 {len(slides)}개 저장"] + overflow_warnings(slides)
    placeholder = placeholder_warning(text)
    if placeholder: lines.append(placeholder)
    emit(*lines)
    return 0

# ─── pptx → markdown ────────────────────────────────────────────────────────────

def iter_shapes(shapes):
    """모양을 문서 순서로 돌린다. 그룹 모양은 그 안의 모양까지 재귀로 편다.
    shape.shape_type 은 기하(prstGeom/custGeom) 가 없으면 NotImplementedError 를 내므로 태그(p:grpSp) 로만 판별한다."""
    for shape in shapes:
        if shape._element.tag == qn("p:grpSp"):
            yield from iter_shapes(shape.shapes)
        else:
            yield shape

def para_segments(p_element) -> list[list]:
    """문단(a:p) XML 의 run(a:r) 과 줄바꿈(a:br) 을 (굵은지, 글자) 조각으로 묶는다.
    이어 붙은 같은 굵기 조각은 하나로 합치고 a:br 은 공백 한 칸으로 넣는다."""
    segs: list[list] = []
    def add(bold: bool, text: str) -> None:
        if not text: return
        if segs and segs[-1][0] == bold: segs[-1][1] += text
        else: segs.append([bold, text])
    for child in p_element.iter():
        if child.tag == qn("a:r"):
            text = "".join(t.text or "" for t in child.findall(qn("a:t")))
            rpr = child.find(qn("a:rPr"))
            add(rpr is not None and rpr.get("b") == "1", text)
        elif child.tag == qn("a:br"):
            add(False, " ")
    return segs

def segments_plain(segs: list[list]) -> str:
    return one_line("".join(text for _, text in segs))

def segments_md(segs: list[list]) -> str:
    """굵은 조각은 **글자** 로 감싼다. 감쌀 때 앞뒤 흰칸은 ** 밖으로 빼고(다시 읽을 때 **** 가 남지 않게),
    공백만 있는 굵은 조각은 감싸지 않는다. 결과는 한 줄로 눌러 표가 깨지지 않게 한다."""
    out = []
    for bold, text in segs:
        core = text.strip()
        if bold and core:
            lead = text[:len(text) - len(text.lstrip())]
            trail = text[len(text.rstrip()):]
            out.append(f"{lead}**{core}**{trail}")
        else:
            out.append(text)
    return one_line("".join(out))

def para_md(para) -> str:
    return segments_md(para_segments(para._p))

def para_all_bold(segs: list[list]) -> bool:
    return bool(segs) and all(bold for bold, _ in segs)

def cell_md(cell, plain: bool = False) -> str:
    """칸 글자를 한 줄로: 칸 안 문단·줄바꿈(a:br) 을 공백 한 칸으로 이어 붙이고 | 는 \\| 로 감춘다.
    plain(머리 행) 이면 굵게 표시 없이 글자만."""
    parts = [segments_plain(para_segments(p._p)) if plain else segments_md(para_segments(p._p))
             for p in cell.text_frame.paragraphs]
    return " ".join(part for part in parts if part).replace("|", "\\|")

def table_md(shape) -> list[str]:
    """표를 GFM 으로: 머리 행은 굵게 표시 없이, 둘째 줄은 | --- | 구분선, 데이터 행은 **굵게** 를 유지한다."""
    table = shape.table
    rendered = []
    for r, row in enumerate(table.rows):
        cells = [cell_md(cell, plain=(r == 0)) for cell in row.cells]
        rendered.append("| " + " | ".join(cells) + " |")
    if not rendered: return []
    separator = "| " + " | ".join(["---"] * len(table.columns)) + " |"
    return [rendered[0], separator] + rendered[1:]

def is_placeholder_idx(shape, idx: int) -> bool:
    """모양이 지정한 자리표시자(idx) 인지. python-pptx 는 접근마다 다른 프록시 객체를 돌려주므로 객체 비교가 아니라 idx 로 판별한다."""
    try:
        return shape.is_placeholder and shape.placeholder_format.idx == idx
    except Exception:
        return False

def slide_md(slide, number: int, lines: list[str]) -> None:
    layout_name = ""
    try: layout_name = slide.slide_layout.name or ""
    except Exception: pass
    title_shape = None
    try: title_shape = slide.shapes.title
    except Exception: pass
    title_text = one_line(title_shape.text_frame.text) if title_shape is not None else ""
    subtitle = placeholder_by_idx(slide, 1) if layout_name == "Title Slide" else None
    if layout_name == "Title Slide":
        # 제목이 비거나 없는 표지 슬라이드도 부제목 글을 잃지 않는다.
        lines.append(f"# {title_text}" if title_text else f"## (슬라이드 {number})")
        if subtitle is not None:
            for para in subtitle.text_frame.paragraphs:
                text = para_md(para)
                if text: lines.append(text)
    else:
        lines.append(f"## {title_text}" if title_text else f"## (슬라이드 {number})")
    for shape in iter_shapes(slide.shapes):
        if is_placeholder_idx(shape, 0): continue  # 제목 자리표시자는 이미 제목 줄로 냈다
        if subtitle is not None and is_placeholder_idx(shape, 1): continue
        try:
            if shape.has_table:
                lines.extend(table_md(shape))
            elif shape.has_text_frame:
                for para in shape.text_frame.paragraphs:
                    segs = para_segments(para._p)
                    text = segments_md(segs)
                    if not text: continue
                    if para.level == 0 and para_all_bold(segs):
                        lines.append(text)  # 수준 0 의 온굵은 문단(소제목) 은 일반 줄 **글자** 로
                    else:
                        lines.append("  " * para.level + "- " + text)
        except Exception:
            continue  # 못 읽는 모양 하나가 슬라이드 전체 읽기를 깨뜨리지 않게 한다.

def export_markdown(prs) -> str:
    lines: list[str] = []
    for number, slide in enumerate(prs.slides, 1):
        if number > 1: lines.append("")
        slide_md(slide, number, lines)
    return "\n".join(lines)

def parse_max_chars(arg: str) -> int:
    """--max-chars 값 검사. 1 이상의 정수가 아니면 사용법 오류."""
    try: value = int(arg)
    except ValueError: value = 0
    if value < 1: raise ToolError("--max-chars 는 1 이상의 정수여야 합니다", 2)
    return value

def parse_read_args(argv: list[str]) -> tuple[str, int]:
    path, max_chars, i = None, MAX_CHARS_DEFAULT, 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--max-chars" and i + 1 < len(argv): max_chars, i = parse_max_chars(argv[i + 1]), i + 2
        elif arg == "--max-chars": raise ToolError("--max-chars 값이 없습니다", 2)
        elif arg.startswith("--max-chars="): max_chars, i = parse_max_chars(arg.split("=", 1)[1]), i + 1
        elif path is None: path, i = arg, i + 1
        else: raise ToolError("파일 인자가 두 개 이상입니다", 2)
    if path is None: raise ToolError("사용법: pptx read <파일.pptx> [--max-chars N]", 2)
    return path, max_chars

def write_sidecar(side: Path, full: str) -> None:
    """배타적 생성으로 열어 전체본을 쓴다. 쓰기가 실패하면 만든 파일을 지운다."""
    fd = os.open(side, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh: fh.write(full)
    except OSError:
        side.unlink(missing_ok=True)
        raise

def read_sidecar_note(path: Path, full: str, max_chars: int) -> str:
    """전체본을 <파일명>.md 로 저장하고 안내 문구를 돌려준다. 실패해도 계속한다."""
    side = path.with_name(path.name + ".md")
    try: write_sidecar(side, full)
    except FileExistsError: return f"(앞 {max_chars}자만 표시. 전체본은 저장하지 않음: {side} 가 이미 있습니다)"
    except OSError as exc: return f"(앞 {max_chars}자만 표시. 전체본 저장 실패: {one_line(exc.strerror or type(exc).__name__)})"
    return f"(앞 {max_chars}자만 표시. 전체 저장: {side})"

def cmd_read(argv: list[str]) -> int:
    raw, max_chars = parse_read_args(argv)
    path = ensure_input(raw)
    prs = open_document(raw)
    full = export_markdown(prs)
    out_abs = to_absolute(raw)
    lines = [f"OK {out_abs}", full[:max_chars]]
    if len(full) > max_chars: lines.append(read_sidecar_note(out_abs, full, max_chars))
    emit(*lines)
    return 0

COMMANDS = {
    "read": cmd_read,
    "from-md": cmd_from_md,
}

def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    handler = COMMANDS.get(argv[0])
    if handler is None: raise ToolError(f"알 수 없는 명령: {argv[0]} (--help 참고)", 2)
    return handler(argv[1:])

def run(argv: list[str]) -> int:
    try:
        return main(argv)
    except ToolError as exc:
        print(f"ERROR {one_line(exc.message)}")
        return exc.code
    except KeyboardInterrupt:
        print("ERROR 중단됨")
        return 130
    except Exception as exc:
        print(f"ERROR 내부 오류: {one_line(f'{type(exc).__name__}: {exc}')}")
        return 1

if __name__ == "__main__": sys.exit(run(sys.argv[1:]))
