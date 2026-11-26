"""docx skill 도구 — Word(DOCX) 문서 읽기·만들기. 출력 규약: 성공은 첫 줄 `OK <절대 경로>`,
실패는 첫 줄 `ERROR <사유>` + exit 1(사용법 오류는 2). Traceback 은 절대 출력하지 않는다."""
from __future__ import annotations
import os, re, sys, tempfile, warnings, xml.etree.ElementTree as ET, zipfile, zlib
from pathlib import Path
warnings.filterwarnings("ignore")
sys.dont_write_bytecode = True
# 일부 작성 규칙(A4 쪽, DXA 표 폭, 머리 행, '* '·'• ' 글머리, 자리 표시 경고)은 anthropics/skills
# (https://github.com/anthropics/skills, commit 2c5958ecac7cee2b583967a2c4981d0f4a75c579, Apache-2.0)의 docx 지침을 참고했다.

MAX_CHARS_DEFAULT = 6000
MAX_INPUT_MB = 50
MAX_UNCOMPRESSED_MB = 200
MAX_MD_BYTES = 5 * 1024 * 1024  # from-md 입력 마크다운 상한(읽기 전에 검사)
MAX_TABLE_COLUMNS = 63   # Word 표 최대 열 수
MAX_TABLE_CELLS = 100000  # 표를 만들 때 칸 수 상한(메모리 폭주 방지)
MB = 1024 * 1024
ZIP_MAGIC = b"PK\x03\x04"
# zip 항목을 풀다가 나올 수 있는 '깨진 파일' 신호들. 내부 오류가 아닌 안내로 바꾼다.
CORRUPT_ZIP_ERRORS = (zipfile.BadZipFile, zlib.error, EOFError, RuntimeError, KeyError)
# XML 이 불허하는 제어 문자(탭 \t·줄바꿈 \n \r 은 제외)와 유니코드 비문자는 조용히 지운다.
XML_ILLEGAL_RE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")
OLE_MAGIC = bytes.fromhex("D0CF11E0A1B11AE1")
EAST_ASIA_FONT = "맑은 고딕"
USAGE = """docx — Word(DOCX) 문서 도구
사용법: docx read <파일.docx> [--max-chars N] / from-md <in.md> [out.docx] / --help
from-md 지원 문법: # ~ ### 제목, -·*·• 목록(들여쓰기 2·4칸), 1. 번호 목록, Markdown 표(| a | b |), **굵게**.
read 는 문서를 Markdown 으로 내보낸다. stdout 에는 --max-chars 만큼만, 전체본은 <파일>.docx.md 로 저장한다.
쓰기 명령의 출력 경로는 입력과 같거나 이미 존재하면 거부한다. 성공 시 첫 줄이 `OK <경로>`, 실패 시 `ERROR <사유>`."""

class ToolError(Exception):
    """ERROR 한 줄로 바꿔 출력할 사용자 단 예외."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message); self.message, self.code = message, code

def emit(*lines: str) -> None:
    print("\n".join(lines))

def one_line(text: str) -> str:
    """어떤 문자열이라도 한 줄로: 줄바꿈·탭 등 흰칸을 한 칸 공백으로 묶는다."""
    return " ".join(str(text).split())

def strip_illegal_chars(text: str) -> str:
    """PDF 에서 붙여 넣은 제어 문자 등 XML 에 넣을 수 없는 글자는 문서를 만들기 전에 지운다."""
    return XML_ILLEGAL_RE.sub("", text)

def reject_control_chars(raw: str) -> None:
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw): raise ToolError("경로에 줄바꿈 등 제어 문자가 있습니다")

def logical_cwd() -> Path:
    """셸이 보는 논리 작업 폴더. PWD 가 실제 작업 폴더와 같은 곳일 때만 믿는다(/tmp → /private/tmp 심볼릭 링크 차이 방지)."""
    pwd = os.environ.get("PWD")
    if pwd and pwd.startswith("/") and os.path.realpath(pwd) == os.getcwd(): return Path(pwd)
    return Path.cwd()

def to_absolute(raw: str) -> Path:
    """경로를 절대 경로로. 이미 절대 경로면 그 문자열을 그대로 둔다(심볼릭 링크는 풀지 않는다)."""
    path = Path(raw)
    return path if path.is_absolute() else logical_cwd() / path

def sniff_format(path: Path, raw: str) -> str | None:
    """확장자 대신 앞 바이트로 형식을 판별한다. 열 수 없으면 권한 안내로 바꾼다."""
    try:
        with open(path, "rb") as fh: head = fh.read(8)
    except OSError as exc:
        raise ToolError(f"파일을 읽을 수 없습니다({exc.strerror or '권한 확인'}): {raw}") from exc
    if head.startswith(ZIP_MAGIC): return "zip"
    if head.startswith(OLE_MAGIC): return "ole"
    return None

def open_zip(path: Path, raw: str) -> zipfile.ZipFile:
    try:
        return zipfile.ZipFile(path)
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"DOCX 파일이 손상되었거나 지원하지 않는 형식입니다: {raw}") from exc

def ensure_input(raw: str) -> Path:
    reject_control_chars(raw)
    path = Path(raw)
    if not path.is_file(): raise ToolError(f"파일 없음: {raw}")
    check_input_size(path, raw)
    return to_absolute(raw)

def check_input_size(path: Path, raw: str) -> None:
    """입력 크기 제한: 파일 50MB, zip 압축 해제 합계 200MB(해제·해석 전에 검사)."""
    try: size = path.stat().st_size
    except OSError as exc:
        raise ToolError(f"파일을 읽을 수 없습니다({exc.strerror or '권한 확인'}): {raw}") from exc
    if size > MAX_INPUT_MB * MB: raise ToolError(f"파일이 너무 큽니다: {raw} (최대 {MAX_INPUT_MB}MB)")
    if sniff_format(path, raw) != "zip": return
    try:
        with open_zip(path, raw) as zf: total = sum(info.file_size for info in zf.infolist())
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"DOCX 파일이 손상되었거나 지원하지 않는 형식입니다: {raw}") from exc
    if total > MAX_UNCOMPRESSED_MB * MB:
        raise ToolError(f"파일이 너무 큽니다: 압축을 풀면 {(total + MB - 1) // MB}MB, 최대 {MAX_UNCOMPRESSED_MB}MB")

def check_output_target(out_raw: str, in_raw: str) -> Path:
    reject_control_chars(out_raw)
    out_abs = to_absolute(out_raw)
    if out_abs.suffix != ".docx": raise ToolError(f"출력 확장자는 .docx 여야 합니다: {out_raw}")
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

# OOXML 패키지 관계 부품(`_rels/.rels`) 의 XML 네임스페이스와, officeDocument 관계의 Target 접두어 → 문서 종류.
# 문서 안에 다른 오피스 파일(embeddings/…)이 있어도 주 부품만 보므로 오인하지 않는다.
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

def check_readable(path: Path, raw: str) -> None:
    """읽기 전 형식 검사: 구형 .doc(OLE 컨테이너), 다른 OOXML(xlsx·pptx), zip 아님·OOXML 아님."""
    fmt = sniff_format(path, raw)
    if fmt == "ole":
        raise ToolError("구형 Word 형식(.doc) 입니다. Word 에서 연 뒤 .docx 로 다시 저장해 주세요")
    if fmt != "zip": raise ToolError(f"DOCX 파일이 아닙니다: {raw}")
    try:
        with open_zip(path, raw) as zf:
            kind = ooxml_kind_from_rels(zf)
            has_types = "[Content_Types].xml" in zf.namelist()
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"DOCX 파일이 손상되었거나 지원하지 않는 형식입니다: {raw}") from exc
    if kind == "docx": return
    if kind is not None: raise ToolError(f"{kind.upper()} 파일입니다. {kind} 스킬을 사용해 주세요: {raw}")
    if has_types: raise ToolError(f"Word 문서가 아닌 OOXML 파일입니다: {raw}")
    raise ToolError(f"DOCX 파일이 손상되었거나 지원하지 않는 형식입니다: {raw}")

# `**굵게**` 는 별표 바로 뒤·앞에 공백이 없을 때만 굵게다(`2 ** 3` 제외).
BOLD_RE = re.compile(r"\*\*(?!\s)(.+?)(?<!\s)\*\*")

# 남아 있으면 안 되는 자리 표시: 빈 대괄호, [내용 입력] 류, TODO, lorem/xxx 류, ○○.
# 자유 형식: [기획 1월 금액]·[담당자 이름] 같은 값 이름 끝 대괄호, [목표 1] 류 번호 붙은 대괄호(링크 [이름](…)·[이름][ref], 쌍점 든 참고·별첨 대괄호 제외).
PLACEHOLDER_RE = re.compile(
    r"\[\s*\]"                                      # [ ]  []
    r"|\[(?:(?i:insert)|입력|내용|여기)[^\]\n]{0,30}\]"   # [insert …] [입력…] [내용 입력] [여기에 부제]
    r"|\[[^\[\]\n:]{0,30}(?:금액|액수|이름|성함|성명|회사명|기관명|부서명|날짜|일자|일시|시작일|종료일|마감일|숫자|수치|연락처|전화번호|이메일|주소)(?:[ \t]?\d{1,2})?[ \t]?\](?![(\[])"   # [기획 1월 금액] [담당자 이름] [회사명] [이름 2] — 쌍점 든 대괄호 제외
    r"|\[[^\[\]\n:]{0,30}(?:업무|항목|목표|사항|내용)[ \t]?\d{1,2}[ \t]?\](?![(\[])"   # [목표 1] [이번 주 완료한 업무 2] — 번호 필수([주요 업무] 등 소제목 제외)
    r"|(?<![A-Za-z])TODO(?![A-Za-z])"               # TODO (case-sensitive; matches 확인TODO, not TODOS)
    r"|(?<![A-Za-z])(?i:lorem|ipsum|xxx)(?![A-Za-z])"
    r"|○○")

def split_bold(text: str) -> list[tuple[str, bool]]:
    """짝이 맞는 `**굵게**` 만 굵게 나누고, 남는 `**` 는 글자 그대로 둔다."""
    pieces, pos = [], 0
    for match in BOLD_RE.finditer(text):
        if match.start() > pos: pieces.append((text[pos:match.start()], False))
        pieces.append((match.group(1), True)); pos = match.end()
    if pos < len(text) or not pieces: pieces.append((text[pos:], False))
    return pieces

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
    """`머리 행 + 구분선` 꼴(2줄 이상)의 블록만 표로 본다. 표일 때 첫 줄이 머리 행, 셋째 줄부터는 구분선 모양이어도
    모두 데이터 행으로 둔다. 아니면 None."""
    if len(block) < 2 or is_separator_row(block[0]) or not is_separator_row(block[1]): return None
    rows = [parse_table_row(line) for line in [block[0]] + block[2:]]
    check_table_size(rows)
    cols = max(len(row) for row in rows)
    return [row + [""] * (cols - len(row)) for row in rows]

try:
    from docx import Document
    from docx.enum.style import WD_STYLE_TYPE
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.oxml.table import CT_Tbl
    from docx.oxml.text.paragraph import CT_P
    from docx.shared import Twips
    from docx.table import Table
    from docx.text.paragraph import Paragraph
except Exception as _exc:  # pragma: no cover - 번들 미설치 환경
    print(f"ERROR python-docx import 실패: {one_line(f'{type(_exc).__name__}: {_exc}')}")
    sys.exit(1)

# 템플릿에 스타일이 없을 때 새로 만들 때의 바탕 스타일.
FALLBACK_BASE = {"List Bullet 2": "List Bullet", "List Bullet 3": "List Bullet",
                 "List Number 2": "List Number", "Heading 2": "Normal", "Heading 3": "Normal"}

def style_or_add(doc, name: str):
    """문단 스타일을 이름으로 찾는다. 템플릿에 없으면 같은 이름으로 만들어 돌려준다."""
    try:
        return doc.styles[name]
    except KeyError:
        pass
    style = doc.styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
    try: style.base_style = doc.styles[FALLBACK_BASE.get(name, "Normal")]
    except KeyError: pass
    return style

def set_east_asian_font(doc) -> None:
    """Normal·Heading 1~3 스타일에 한글 글꼴(맑은 고딕) 을 지정하고 테마 글꼴 속성(w:eastAsiaTheme) 은 지운다."""
    for name in ("Normal", "Heading 1", "Heading 2", "Heading 3"):
        try: style = doc.styles[name]
        except KeyError: continue
        fonts = style.element.get_or_add_rPr().get_or_add_rFonts()
        fonts.set(qn("w:eastAsia"), EAST_ASIA_FONT)
        fonts.attrib.pop(qn("w:eastAsiaTheme"), None)

def add_runs(para, text: str, force_bold: bool = False) -> None:
    """문단에 run 들을 넣는다. **굵게** 는 굵은 run, 표 머리 칸처럼 force_bold 면 모두 굵게."""
    for seg, bold in split_bold(text):
        if not seg: continue
        run = para.add_run(seg)
        if bold or force_bold: run.bold = True

# A4(11906×16838 DXA), 사방 여백 1인치(1440). 한국 문서 기본 쪽이라 Letter 가 아니다.
A4_WIDTH, A4_HEIGHT, PAGE_MARGIN = 11906, 16838, 1440
TEXT_WIDTH_DXA = A4_WIDTH - 2 * PAGE_MARGIN  # 9026 — A4 본문 폭이자 표의 총 폭
HEADER_FILL = "D9D9D9"  # 머리 칸 음영(옅은 회색)

def setup_a4_page(doc) -> None:
    """첫 섹션을 A4 · 사방 1440 여백으로 만든다. 표를 만들기 전에 호출해야 add_table 이
    새 표의 gridCol 을 이 시점의 본문 폭으로 계산한다(python-docx 동작)."""
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Twips(A4_WIDTH), Twips(A4_HEIGHT)
    sec.top_margin = sec.right_margin = sec.bottom_margin = sec.left_margin = Twips(PAGE_MARGIN)

def find_placeholder_tokens(text: str) -> list[str]:
    """자리 표시 토큰을 처음 본 순서로, 중복 없이 최대 5개."""
    seen, tokens = set(), []
    for match in PLACEHOLDER_RE.finditer(text):
        token = match.group(0)
        if token not in seen:
            seen.add(token); tokens.append(token)
            if len(tokens) >= 5: break
    return tokens

def placeholder_warning(text: str) -> str | None:
    """자리 표시가 남아 있으면 경고 한 줄을, 깨끗하면 None."""
    tokens = find_placeholder_tokens(text)
    if not tokens: return None
    return one_line(f"경고 자리 표시가 남아 있음: {', '.join(tokens)} — 실제 내용으로 채우거나 사용자에게 물어보세요")

HEADING_MD_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
BULLET_MD_RE = re.compile(r"^(\s*)(?:[-*•])\s+(.+?)\s*$")  # `- `·`* `·`• ` (기호 뒤 공백 필요: `**굵게**` 는 제외)
NUMBER_MD_RE = re.compile(r"^(\s*)\d+\.\s+(.+?)\s*$")

def bullet_style_name(indent: int) -> str:
    return "List Bullet 3" if indent >= 4 else "List Bullet 2" if indent >= 2 else "List Bullet"

def number_style_name(indent: int) -> str:
    return "List Number 2" if indent >= 2 else "List Number"

def add_paragraph_line(doc, line: str, counts: dict) -> None:
    """markdown 한 줄을 문단으로: # 제목, - 목록, 1. 번호, 나머지 본문. 들여쓰기 칸 수로 목록 단계를 정한다."""
    stripped = line.strip()
    heading = HEADING_MD_RE.match(stripped)
    if heading is not None:
        para = doc.add_paragraph(); para.style = style_or_add(doc, f"Heading {min(len(heading.group(1)), 3)}")
        add_runs(para, heading.group(2))
    elif (bullet := BULLET_MD_RE.match(line)) is not None:
        para = doc.add_paragraph(); para.style = style_or_add(doc, bullet_style_name(len(bullet.group(1))))
        add_runs(para, bullet.group(2))
    elif (number := NUMBER_MD_RE.match(line)) is not None:
        para = doc.add_paragraph(); para.style = style_or_add(doc, number_style_name(len(number.group(1))))
        add_runs(para, number.group(2))
    else:
        para = doc.add_paragraph(); para.style = style_or_add(doc, "Normal")
        add_runs(para, stripped)
    counts["paras"] += 1

def column_widths_dxa(ncols: int) -> list[int]:
    """본문 폭 9026 DXA 를 열에 나눈다. 나누어 떨어지지 않으면 마지막 열이 나머지를 가져
    합이 정확히 9026 이 된다."""
    base = TEXT_WIDTH_DXA // ncols
    return [base] * (ncols - 1) + [TEXT_WIDTH_DXA - base * (ncols - 1)]

def apply_table_width(table, widths: list[int]) -> None:
    """표 폭을 DXA 로 고정한다(auto/pct 는 다른 문서 편집기에서 깨진다): tblW 는 본문 폭 전체,
    gridCol 과 행마다 칸의 tcW 는 그 열의 폭(행의 칸 폭 합 = tblW)."""
    tblW = table._tbl.tblPr.find(qn("w:tblW"))
    if tblW is not None:  # add_table 이 w:tblW(auto) 를 이미 만들어 두므로 속성만 바꾼다(스키마 순서 유지).
        tblW.set(qn("w:type"), "dxa"); tblW.set(qn("w:w"), str(TEXT_WIDTH_DXA))
    for col, w in zip(table.columns, widths): col.width = Twips(w)
    for row in table.rows:
        for cell, w in zip(row.cells, widths): cell.width = Twips(w)

def shade_cell(cell) -> None:
    """칸에 옅은 회색 음영(w:shd clear/D9D9D9). tcW 다음에 넣어 tcPr 스키마 순서를 지킨다."""
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear"); shd.set(qn("w:color"), "auto"); shd.set(qn("w:fill"), HEADER_FILL)
    cell._tc.get_or_add_tcPr().append(shd)

def mark_header_row(table) -> None:
    """첫 행을 머리 행으로: 쪽이 넘어가도 반복(w:tblHeader) 하고 머리 칸만 음영. 굵게는 이미 add_runs 가 넣는다."""
    trPr = table.rows[0]._tr.get_or_add_trPr()
    if trPr.find(qn("w:tblHeader")) is None: trPr.append(OxmlElement("w:tblHeader"))
    for cell in table.rows[0].cells: shade_cell(cell)

def add_md_table(doc, block: list[str], counts: dict) -> None:
    rows = parse_md_table(block)
    if rows is None:
        for line in block: add_paragraph_line(doc, line, counts)  # 구분선만 있는 `|` 블록은 표가 아니므로 일반 문단으로 넣는다.
        return
    table = doc.add_table(rows=len(rows), cols=len(rows[0]))
    try: table.style = doc.styles["Table Grid"]
    except KeyError: pass
    apply_table_width(table, column_widths_dxa(len(rows[0])))
    mark_header_row(table)
    for r, row in enumerate(rows):
        for c, cell_text in enumerate(row):
            add_runs(table.cell(r, c).paragraphs[0], cell_text, force_bold=(r == 0))  # 머리 행은 모두 굵게
    counts["tables"] += 1

def render_markdown(doc, text: str) -> dict:
    lines, counts, i = text.splitlines(), {"paras": 0, "tables": 0}, 0
    while i < len(lines):
        stripped = lines[i].strip()
        if not stripped: i += 1
        elif stripped.startswith("|"):
            block = []
            while i < len(lines) and lines[i].strip().startswith("|"): block.append(lines[i].strip()); i += 1
            add_md_table(doc, block, counts)
        else:
            add_paragraph_line(doc, lines[i], counts); i += 1
    return counts

def save_doc(doc, out_abs: Path) -> None:
    """임시 파일에 저장·되열기 검증한 뒤 umask 권한으로 하드 링크 게시. 실패해도 출력 경로는 남기지 않는다."""
    fd, tmp_name = tempfile.mkstemp(dir=str(out_abs.parent), prefix=".docx-", suffix=".tmp")
    os.close(fd); tmp = Path(tmp_name)
    try:
        doc.save(str(tmp))
        try: Document(str(tmp))
        except Exception as exc: raise ToolError(f"저장된 문서를 다시 여는 데 실패했습니다: {out_abs}") from exc
        mask = os.umask(0); os.umask(mask)
        os.chmod(tmp, 0o666 & ~mask)
        try: os.link(str(tmp), str(out_abs))
        except FileExistsError: raise ToolError(f"출력 경로가 이미 존재합니다: {out_abs}")
    finally:
        if os.path.lexists(tmp): tmp.unlink(missing_ok=True)

def open_docx(path: Path, raw: str):
    try:
        return Document(str(path))
    except ToolError: raise
    except Exception as exc:
        raise ToolError(f"DOCX 파일을 읽지 못했습니다(손상되었을 수 있음): {raw}") from exc

def iter_block_items(doc):
    """문서 본문을 문단·표 순서 그대로 돌려준다. 본문 바로 밖 w:sdt(콘텐츠 컨트롤) 안 문단도 함께."""
    for child in doc.element.body.iterchildren():
        if isinstance(child, CT_P): yield Paragraph(child, doc)
        elif isinstance(child, CT_Tbl): yield Table(child, doc)
        elif child.tag == qn("w:sdt"):
            content = child.find(qn("w:sdtContent"))
            if content is None: continue
            for sub in content.iterchildren():
                if isinstance(sub, CT_P): yield Paragraph(sub, doc)
                elif isinstance(sub, CT_Tbl): yield Table(sub, doc)

def run_xml_text(r) -> str:
    """run(w:r) 의 글자: w:t 와 탭·줄바꿈(w:tab/w:br/w:cr) 까지 이어 받는다."""
    parts = []
    for child in r:
        if child.tag == qn("w:t"): parts.append(child.text or "")
        elif child.tag == qn("w:tab"): parts.append("\t")
        elif child.tag in (qn("w:br"), qn("w:cr")): parts.append("\n")
    return "".join(parts)

def run_xml_bold(r) -> bool:
    """run(w:r) 의 굵게 여부. w:b 가 'false'/'0'/'off' 이면 굵지 않다."""
    rpr = r.find(qn("w:rPr"))
    if rpr is None: return False
    b = rpr.find(qn("w:b"))
    return b is not None and b.get(qn("w:val")) not in ("false", "0", "off")

def para_segments(para) -> list[list]:
    """문단 XML 안의 모든 run(w:hyperlink 등에 싸인 것까지) 을 (굵은지, 글자) 조각으로 묶는다.
    이어 붙은 같은 굵기 조각은 하나로 합친다."""
    segs: list[list] = []
    for r in para._p.iter(qn("w:r")):
        text = run_xml_text(r)
        if not text: continue
        bold = run_xml_bold(r)
        if segs and segs[-1][0] == bold: segs[-1][1] += text
        else: segs.append([bold, text])
    return segs

def mark_bold_segments(segs: list[list]) -> str:
    """굵은 조각은 **글자** 로 감싼다. 감쌀 때 앞뒤 흰칸은 ** 밖으로 빼고(다시 읽을 때 ** 가 남지 않게),
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

def runs_to_md(para) -> str:
    """문단의 run 들을 markdown 한 줄로: 굵은 run 은 **글자**, 줄바꿈은 공백 한 칸으로."""
    return mark_bold_segments(para_segments(para))

# 읽기 쪽 스타일 → markdown 접두어. 번호 목록은 값이 본문 단계(0)/들여쓰기 단계(1).
LIST_BULLET_PREFIX = {"List Bullet": "- ", "List Bullet 2": "  - ", "List Bullet 3": "    - "}
LIST_NUMBER_LEVEL = {"List Number": 0, "List Number 2": 1}

def heading_level_of(name: str) -> int | None:
    """'Heading N' → N(3 까지), 'Title' → 1. 아니면 None."""
    if name == "Title": return 1
    match = re.fullmatch(r"Heading (\d+)", name)
    return min(int(match.group(1)), 3) if match else None

def tc_to_md(tc, with_bold: bool) -> str:
    """칸(w:tc) 글자를 한 줄로: 칸 안 문단·줄바꿈을 공백 한 칸으로 이어 붙인다. with_bold 가 아니면 굵게 표시 없이 글자만."""
    paras = tc.findall(qn("w:p"))
    parts = [runs_to_md(Paragraph(p, None)) if with_bold
             else one_line("".join(run_xml_text(r) for r in p.iter(qn("w:r")))) for p in paras]
    return " ".join(part for part in parts if part.strip())

def tc_property(tc, name: str):
    """칸 속성을 찾는다. gridSpan·vMerge 는 w:tc 의 직계 자식이 아니라 w:tc/w:tcPr 안에 있다(스키마)."""
    tcpr = tc.find(qn("w:tcPr"))
    return None if tcpr is None else tcpr.find(qn(name))

def tc_grid_span(tc) -> int:
    """가로 병합으로 이 칸이 차지하는 그리드 열 수(w:gridSpan, 없으면 1)."""
    span = tc_property(tc, "w:gridSpan")
    if span is None: return 1
    try: return max(1, int(span.get(qn("w:val")) or 1))
    except (TypeError, ValueError): return 1

def table_to_md(table) -> list[str]:
    """표를 GFM 표로: 머리 행은 굵게 표시 없이, 데이터 행은 **굵게** 를 유지하고 칸 안 | 는 \\| 로 이스케이프.
    병합 칸의 글은 첫 칸에만 한 번: 가로 병합(gridSpan) 칸 뒤의 그리드 칸과 세로 병합 이어짐(w:vMerge) 칸은 빈 칸.
    (python-docx 의 row.cells 가 같은 칸을 반복하지만 lxml 프록시 주소는 재사용되므로 XML 로만 판단한다.)"""
    width = len(table.columns)
    if width == 0: return []
    rendered = []
    for r, tr in enumerate(table._tbl.findall(qn("w:tr"))):
        texts = []
        for tc in tr.findall(qn("w:tc")):
            # 병합 폭은 이 행에 남은 열까지만 센다(터무니없는 gridSpan 값으로 메모리가 늘어나지 않게).
            span = min(tc_grid_span(tc), width - len(texts))
            vm = tc_property(tc, "w:vMerge")
            if vm is not None and vm.get(qn("w:val")) != "restart":
                texts.extend([""] * span)  # 세로 병합 이어짐 칸은 빈 칸(열 수 유지)
                continue
            texts.append(tc_to_md(tc, r > 0).replace("|", "\\|"))
            texts.extend([""] * (span - 1))  # 가로 병합이 덮는 나머지 칸
        texts.extend([""] * (width - len(texts)))  # 뒤가 비어 있는 행도 열 수를 맞춘다
        rendered.append("| " + " | ".join(texts[:width]) + " |")
    if not rendered: return []
    return [rendered[0], "| " + " | ".join(["---"] * width) + " |"] + rendered[1:]

def export_markdown(doc) -> str:
    """문단·표를 문서 순서대로 markdown 줄로. 번호 목록은 문서의 번호가 아니라 1부터 다시 센다:
    새 1단계 번호마다 하위 번호가 1 로 돌아가고, 번호 아닌 블록(표·제목·본문) 뒤에는 모두 1 부터 다시 시작한다."""
    lines, num1, num2 = [], 0, 0
    for block in iter_block_items(doc):
        if isinstance(block, Table):
            num1 = num2 = 0  # 표를 지나면 번호도 처음부터
            lines.extend(table_to_md(block))
            continue
        name = block.style.name if block.style is not None else ""
        body = runs_to_md(block).strip()
        if name in LIST_NUMBER_LEVEL and body:
            if LIST_NUMBER_LEVEL[name] == 0: num1 += 1; num2 = 0; prefix = f"{num1}. "
            else: num2 += 1; prefix = f"  {num2}. "
        else:
            num1 = num2 = 0
            prefix = ""
            if name in LIST_BULLET_PREFIX: prefix = LIST_BULLET_PREFIX[name]
            elif (level := heading_level_of(name)) is not None: prefix = "#" * level + " "
            if not body: continue  # 빈 문단은 건너뛴다
        lines.append(prefix + body)
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
    if path is None: raise ToolError("사용법: docx read <파일.docx> [--max-chars N]", 2)
    return path, max_chars

def write_sidecar(side: Path, full: str) -> None:
    """배타적 생성으로 열어 전체본을 쓴다(이미 있거나 심볼릭 링크면 쓰지 않는다). 쓰기가 실패하면 만든 파일을 지운다."""
    fd = os.open(side, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh: fh.write(full)
    except OSError:
        side.unlink(missing_ok=True)
        raise

def read_sidecar_note(path: Path, full: str, max_chars: int) -> str:
    """전체본을 <파일명>.docx.md 로 저장하고 안내 문구를 돌려준다. 실패해도 계속한다."""
    side = path.with_name(path.name + ".md")
    try: write_sidecar(side, full)
    except FileExistsError: return f"(앞 {max_chars}자만 표시. 전체본은 저장하지 않음: {side} 가 이미 있습니다)"
    except OSError as exc: return f"(앞 {max_chars}자만 표시. 전체본 저장 실패: {one_line(exc.strerror or type(exc).__name__)})"
    return f"(앞 {max_chars}자만 표시. 전체 저장: {side})"

def cmd_read(argv: list[str]) -> int:
    raw, max_chars = parse_read_args(argv)
    path = ensure_input(raw)
    check_readable(path, raw)
    doc = open_docx(path, raw)
    full = export_markdown(doc) or "(내용 없음)"
    lines = [f"OK {path}", full[:max_chars]]
    if len(full) > max_chars: lines.append(read_sidecar_note(path, full, max_chars))
    emit(*lines)
    return 0

def cmd_from_md(argv: list[str]) -> int:
    if len(argv) == 1:  # 출력 경로를 줄이면 입력 md 의 확장자만 바꾼 경로(상대 경로는 상대 그대로)
        argv = [argv[0], str(Path(argv[0]).with_suffix(".docx"))]
    if len(argv) != 2: raise ToolError("사용법: docx from-md <in.md> [out.docx]", 2)
    in_raw, out_raw = argv
    ensure_input(in_raw)
    out_abs = check_output_target(out_raw, in_raw)
    text = strip_illegal_chars(read_utf8(in_raw))
    if not text.strip(): raise ToolError(f"내용이 비어 있는 Markdown 파일입니다: {in_raw}")
    doc = Document()
    set_east_asian_font(doc)
    setup_a4_page(doc)  # 콘텐츠보다 먼저: add_table 이 이 시점의 섹션 본문 폭으로 gridCol 을 계산한다.
    counts = render_markdown(doc, text)
    save_doc(doc, out_abs)
    lines = [f"OK {out_abs}", f"문단 {counts['paras']}개, 표 {counts['tables']}개 저장"]
    if (warn := placeholder_warning(text)) is not None: lines.append(warn)
    emit(*lines)
    return 0

COMMANDS = {"read": cmd_read, "from-md": cmd_from_md}

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
