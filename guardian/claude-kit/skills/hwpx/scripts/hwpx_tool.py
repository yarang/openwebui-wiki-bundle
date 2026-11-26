"""hwpx skill 도구 — 한글(HWPX/HWP) 문서 읽기·만들기·양식 채우기. 출력 규약: 성공은 첫 줄
`OK <절대 경로>`, 실패는 첫 줄 `ERROR <사유>` + exit 1(사용법 오류는 2). Traceback 은 절대 출력하지 않는다."""
from __future__ import annotations
import io, json, os, re, sys, tempfile, warnings, zipfile, zlib
import xml.etree.ElementTree as ElementTree
from pathlib import Path
warnings.filterwarnings("ignore")
# 배포 시 python-hwpx 가 skills/hwpx/lib 아래 vendoring 될 수 있다.
_LIB = Path(__file__).resolve().parent.parent / "lib"
if _LIB.is_dir(): sys.path.insert(0, str(_LIB))
sys.dont_write_bytecode = True
try:
    from hwpx_fields import (one_line, label_key, key_body, field_entries, shown_name, NESTED_FIELD_FAIL,
                             CROSSED_FIELD_FAIL, field_nesting, current_field_index,
                             missing_after_fill, field_value, field_snapshot, field_damage,
                             nonform_snapshot, nonform_reason, outside_text_styles, style_damage,
                             unopenable_reason)
except Exception as exc:
    # lib 폴더 자체가 없거나 lib 내용이 깨졌을 때 Traceback 대신 한국어 한 줄. 이 단계에서 one_line 은 없을 수 있다.
    if isinstance(exc, ModuleNotFoundError) and exc.name == "hwpx_fields":
        print("ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_fields.py 없음)")
    else:
        print("ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_fields.py 손상 또는 버전 불일치)")
    sys.exit(1)
try:
    from hwpx_slots import (parse_position_key, pos_key, slot_of_key, has_letter,
                            iter_grid_positions, table_roots, scan_labels, slot_context,
                            preceding_paragraph_texts, retry_hints)
except Exception as exc:
    if isinstance(exc, ModuleNotFoundError) and exc.name == "hwpx_slots":
        print("ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_slots.py 없음)")
    else:
        print("ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_slots.py 손상 또는 버전 불일치)")
    sys.exit(1)
try:
    from hwpx import HwpxDocument
except Exception as _exc:  # pragma: no cover - 번들 미설치 환경
    HwpxDocument = None
    _HWPX_IMPORT_ERROR = _exc
MAX_CHARS_DEFAULT = 6000
MAX_INPUT_MB = 50
MAX_UNCOMPRESSED_MB = 200
MB = 1024 * 1024
FILL_REASON_MAP = {"form field selector is ambiguous": "같은 이름의 누름틀이 여러 개"}
HWP5_CODE_MESSAGES = {
    "hwp5-limit-exceeded": "HWP 파일이 너무 큽니다(변환 한도 초과). 한글에서 HWPX 로 저장해 주세요",
    "hwp5-password": "암호가 걸린 HWP 는 열 수 없습니다. 한글에서 암호를 풀고 HWPX 로 저장해 주세요",
    "hwp5-distribution": "배포용 HWP 문서는 열 수 없습니다. 한글에서 배포용 설정을 풀고 HWPX 로 저장해 주세요",
    "hwp5-drm": "DRM 으로 보호된 HWP 는 열 수 없습니다. 보호를 푼 문서로 다시 시도해 주세요",
}
HWPX_PASSWORD_MSG = "암호가 걸린 HWPX 는 열 수 없습니다. 한글에서 암호를 풀고 다시 저장해 주세요"
ZIP_MAGIC = b"PK\x03\x04"
HWP_OLE_MAGIC = bytes.fromhex("D0CF11E0A1B11AE1")
HWP_FAIL_MSG = "HWP 파일을 읽지 못했습니다. 한글에서 '다른 이름으로 저장 → HWPX' 후 다시 시도하세요."
USAGE = """hwpx — 한글(HWPX/HWP) 문서 도구
사용법: hwpx read <파일> [--max-chars N] [--md] / from-md <in.md> [out.hwpx] / fields <양식.hwpx>
  fill <양식.hwpx> <값.json> <out.hwpx> / validate <파일.hwpx> / --help
from-md 지원 문법: # ~ ### 제목, □·ㅇ·- 개조식 줄, Markdown 표(| a | b |), **굵게**.
쓰기 명령의 출력 경로는 입력과 같거나 이미 존재하면 거부한다. 성공 시 첫 줄이 `OK <경로>`, 실패 시 `ERROR <사유>`."""

class ToolError(Exception):
    """ERROR 한 줄로 바꿔 출력할 사용자 단 예외."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message); self.message, self.code = message, code

def emit(*lines: str) -> None:
    print("\n".join(lines))

def translate_reason(reason: str) -> str:
    """라이브러리 사유 문자열을 한국어로 옮긴다. 모르면 원문을 그대로."""
    for needle, ko in FILL_REASON_MAP.items():
        if needle in reason: return ko
    return reason

def reject_control_chars(raw: str) -> None:
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw): raise ToolError("경로에 줄바꿈 등 제어 문자가 있습니다")

def require_hwpx() -> None:
    if HwpxDocument is None: raise ToolError(f"python-hwpx import 실패: {_HWPX_IMPORT_ERROR}")

def ensure_input(raw: str) -> Path:
    reject_control_chars(raw)
    path = Path(raw)
    if not path.is_file(): raise ToolError(f"파일 없음: {raw}")
    check_input_size(path, raw)
    return path

def check_input_size(path: Path, raw: str) -> None:
    """입력 크기 제한: 파일 50MB, HWPX 압축 해제 합계 200MB."""
    if path.stat().st_size > MAX_INPUT_MB * MB: raise ToolError(f"파일이 너무 큽니다: {raw} (최대 {MAX_INPUT_MB}MB)")
    if sniff_format(path) != "hwpx": return
    try: total = sum(info.file_size for info in zipfile.ZipFile(path).infolist())
    except zipfile.BadZipFile: raise ToolError(f"HWPX 파일이 손상되었습니다: {path}")
    if total > MAX_UNCOMPRESSED_MB * MB:
        raise ToolError(f"파일이 너무 큽니다: 압축을 풀면 {(total + MB - 1) // MB}MB, 최대 {MAX_UNCOMPRESSED_MB}MB")

def logical_cwd() -> Path:
    pwd = os.environ.get("PWD")
    if pwd and pwd.startswith("/") and os.path.realpath(pwd) == os.getcwd(): return Path(pwd)
    return Path.cwd()

def to_absolute(raw: str) -> Path:
    """경로를 절대 경로로. 이미 절대 경로면 그 문자열을 그대로 두고, 상대 경로는 셸이 보는 논리 작업
    폴더 기준으로 잡는다(/tmp → /private/tmp 심볼릭 링크 차이를 셸 이력과 같게 유지)."""
    path = Path(raw)
    return path if path.is_absolute() else logical_cwd() / path

def check_output_target(out_raw: str, in_raw: str) -> Path:
    reject_control_chars(out_raw)
    out_abs = to_absolute(out_raw)
    if in_raw and out_abs == to_absolute(in_raw): raise ToolError(f"출력 경로가 입력과 같습니다: {out_raw}")
    if os.path.lexists(out_abs): raise ToolError(f"출력 경로가 이미 존재합니다: {out_raw}")
    if not out_abs.parent.is_dir(): raise ToolError(f"출력 폴더가 없습니다: {out_abs.parent}")
    return out_abs

def read_utf8(raw: str) -> str:
    try:
        return Path(raw).read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise ToolError(f"UTF-8 텍스트 파일이 아닙니다: {raw}")

def sniff_format(path: Path) -> str | None:
    """확장자 대신 앞 바이트로 형식을 판별한다."""
    with open(path, "rb") as fh: head = fh.read(8)
    if head.startswith(ZIP_MAGIC): return "hwpx"
    if head == HWP_OLE_MAGIC: return "hwp"
    return None

def package_to_bytes(files: dict) -> bytes:
    """HWPX 파트 dict 를 mimetype 이 앞에 오는 zip(HWPX) 바이트로 묶는다."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name in sorted(files, key=lambda n: (n != "mimetype", n)):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            zf.writestr(info, files[name])
    return buf.getvalue()

def hwpx_corrupt_errors() -> tuple:
    """손상·형식 오류로 볼 예외 클래스들(zlib 오류·끊긴 자료 포함). import 못 하는 것은 빼고 만든다."""
    errors = [zipfile.BadZipFile, ElementTree.ParseError, zlib.error, EOFError]
    for module, name in (("hwpx.errors", "HwpxError"), ("hwpx.opc.package", "HwpxPackageError"),
                         ("lxml.etree", "XMLSyntaxError")):
        try: errors.append(getattr(__import__(module, fromlist=[name]), name))
        except Exception: pass
    return tuple(errors)

def open_hwpx_or_fail(path: Path, message: str):
    """HWPX 를 열고 손상·형식 오류는 안내로, 보안 오류는 그대로 다시 올린다."""
    try:
        return HwpxDocument.open(str(path))
    except Exception as exc:
        if is_security_error(exc): raise
        if "암호가 걸린" in str(exc): raise ToolError(HWPX_PASSWORD_MSG) from exc
        if isinstance(exc, hwpx_corrupt_errors()): raise ToolError(message) from exc
        raise

def open_hwp_bytes(data: bytes):
    """HWP 5.x(OLE) 바이트를 HWPX 로 변환해 연다. 보안 오류는 다시 올린다."""
    try:
        from hwpx.hwp5.package import convert
        return HwpxDocument.open(package_to_bytes(convert(data).files))
    except ToolError: raise
    except Exception as exc:
        if is_security_error(exc): raise
        raise ToolError(HWP5_CODE_MESSAGES.get(getattr(exc, "code", None)) or HWP_FAIL_MSG) from exc

def open_document(raw: str):
    require_hwpx()
    path = Path(raw)
    fmt = sniff_format(path)
    if fmt == "hwpx": return open_hwpx_or_fail(path, f"유효한 HWPX 파일이 아니거나 손상되었습니다: {raw}")
    if fmt == "hwp": return open_hwp_bytes(path.read_bytes())
    raise ToolError(f"HWPX/HWP 형식이 아닌 파일입니다: {raw}")

def package_validation_failure(path: Path) -> str | None:
    """validate_package 검증 실패 요약 한 줄. 통과·미지원이면 None."""
    try:
        from hwpx.tools.package_validator import validate_package
    except Exception: return None
    try:
        report = validate_package(str(path))
    except Exception as exc: return one_line(f"{type(exc).__name__}: {exc}")
    if getattr(report, "ok", True): return None
    return "; ".join(one_line(str(e)) for e in (getattr(report, "errors", None) or [])[:3]) or "패키지 검증 오류"

def ensure_report_ok(report, path: Path, prefix: str) -> int:
    """doc.validate() 결과와 패키지 검증을 확인하고 경고 수를 돌려준다."""
    if not report.ok:
        msgs = "; ".join(one_line(str(e)) for e in report.errors[:3])
        raise ToolError(f"{prefix}: {msgs}")
    pkg = package_validation_failure(path)
    if pkg: raise ToolError(f"{prefix}: {pkg}")
    return len(report.warnings)

def save_to_tmp(doc, tmp: Path, out_abs: Path) -> None:
    """임시 경로에 저장한다. 열기 안전 검사 실패(HwpxPackageError)는 사용자 안내 문구로 바꾼다."""
    from hwpx.opc.package import HwpxPackageError
    try:
        doc.save_to_path(str(tmp))
    except HwpxPackageError as exc:
        raise ToolError(f"한/글이 열지 못하는 문서가 되어 저장하지 않았습니다: {out_abs}") from exc

def save_validated(doc, out_abs: Path) -> int:
    """임시 파일에 저장·검증한 뒤 umask 권한으로 하드 링크 게시. 실패 시 임시 파일을 지우고 출력 경로는 그대로 둔다."""
    fd, tmp_name = tempfile.mkstemp(dir=str(out_abs.parent), prefix=".hwpx-", suffix=".tmp")
    os.close(fd); tmp = Path(tmp_name)
    try:
        save_to_tmp(doc, tmp, out_abs)
        saved = HwpxDocument.open(str(tmp))
        warns = ensure_report_ok(saved.validate(), tmp, "저장은 했지만 검증 실패")
        mask = os.umask(0); os.umask(mask)
        os.chmod(tmp, 0o666 & ~mask)
        try: os.link(str(tmp), str(out_abs))
        except FileExistsError: raise ToolError(f"출력 경로가 이미 존재합니다: {out_abs}")
        return warns
    finally:
        if os.path.lexists(tmp): tmp.unlink(missing_ok=True)

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

def parse_md_table(block: list[str]) -> list[list[str]] | None:
    """`머리 행 + 구분선` 꼴(2줄 이상)의 블록만 표로 본다. 표일 때 첫 줄이 머리 행, 셋째 줄부터는 구분선 모양이어도 모두 데이터 행으로 둔다. 아니면 None."""
    if len(block) < 2 or is_separator_row(block[0]) or not is_separator_row(block[1]): return None
    rows = [parse_table_row(line) for line in [block[0]] + block[2:]]
    cols = max(len(row) for row in rows)
    return [row + [""] * (cols - len(row)) for row in rows]

def add_md_table(doc, block: list[str], counts: dict) -> None:
    rows = parse_md_table(block)
    if rows is None:
        for line in block: add_text_line(doc, line, counts)  # 구분선만 있는 `|` 블록은 표가 아니므로 일반 문단으로 넣는다.
        return
    table = doc.add_table(len(rows), len(rows[0]))
    for r, row in enumerate(rows):
        for c, cell_text in enumerate(row):
            cell = table.cell(r, c)
            for seg, bold in split_bold(cell_text): cell.paragraphs[0].add_run(seg, bold=bold)
    counts["tables"] += 1

def add_heading_line(doc, stripped: str, counts: dict) -> None:
    match = re.match(r"(#{1,})\s+(.*)$", stripped)
    if match is None:
        add_text_line(doc, stripped, counts)
        return
    doc.add_heading(strip_bold(match.group(2)).strip(), min(len(match.group(1)), 3))
    counts["paras"] += 1

def add_text_line(doc, text: str, counts: dict) -> None:
    # inherit_style=False: 제목(개요) 스타일을 물려받지 않게 바탕글로 넣는다.
    para = doc.add_paragraph(include_run=False, inherit_style=False)
    for seg, bold in split_bold(text): para.add_run(seg, bold=bold)
    counts["paras"] += 1

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
            (add_heading_line if stripped.startswith("#") else add_text_line)(doc, stripped, counts); i += 1
    return counts

def heading_style_levels(doc) -> dict:
    """스타일 이름이 '개요 N' 인 스타일의 id → 수준(1~6 으로 자른다)."""
    try: pairs = [(str(s.id), re.fullmatch(r"개요\s*(\d+)", str(getattr(s, "name", "")))) for s in doc.styles.values()]
    except Exception: return {}
    return {sid: min(max(int(m.group(1)), 1), 6) for sid, m in pairs if m}

TABLE_TAG_RE = re.compile(
    r"<table>(?=\n<(?:caption|tr)>|\n</table>)|(?<=</tr>\n)</table>|(?<=<table>\n)</table>")

# 라이브러리의 Markdown 글자 이스케이프는 html.escape(quote=False) 라서 이 세 가지뿐이다.
LIB_ENTITY_RE = re.compile(r"&(amp|lt|gt);")
LIB_ENTITIES = {"amp": "&", "lt": "<", "gt": ">"}

def unescape_library_entities(text: str) -> str:
    """&amp; &lt; &gt; 만 한 번에 되돌린다. 이어 붙인 replace 처럼 두 번 풀지 않는다."""
    return LIB_ENTITY_RE.sub(lambda m: LIB_ENTITIES[m.group(1)], text)

def map_table_depth(md: str, outside, inside) -> str:
    """HTML 표 구조 태그 깊이 순회: 깊이 0 조각에는 outside, HTML 표 안 조각에는 inside 를 적용해 이어 붙인다.
    캡션·본문 글자 속 '<table>' 은 구조 태그로 세지 않는다."""
    out, depth, pos = [], 0, 0
    for match in TABLE_TAG_RE.finditer(md):
        out += [(outside if depth == 0 else inside)(md[pos:match.start()]), match.group(0)]
        depth = depth + 1 if match.group(0) == "<table>" else max(0, depth - 1)
        pos = match.end()
    out.append((outside if depth == 0 else inside)(md[pos:]))
    return "".join(out)

def unescape_outside_tables(md: str) -> str:
    """(import 실패 대체 경로) 라이브러리가 만든 HTML 표 블록 바깥의 글자 이스케이프만 되돌린다."""
    return map_table_depth(md, unescape_library_entities, lambda seg: seg)

# 표식 후보 비문자 66개: U+FDD0~U+FDEF 를 먼저, 그 뒤 0~16 평면 끝의 U+xFFFE·U+xFFFF.
NONCHAR_CODES = list(range(0xFDD0, 0xFDF0)) + [p * 0x10000 + c for p in range(17) for c in (0xFFFE, 0xFFFF)]

def pick_markers(doc) -> tuple | None:
    """원문에 없는 비문자 표식 5개를 고른다. 앞 3개는 & < > 용, 뒤 2개는 HTML 표 열기·닫기 경계용. 부족하면 None."""
    try:
        from lxml import etree
        used = "".join(etree.tostring(s.element, encoding="unicode") for s in doc.sections)
    except Exception: return None
    free = [chr(code) for code in NONCHAR_CODES if chr(code) not in used]
    return tuple(free[:5]) if len(free) >= 5 else None

HP_NS = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"

def plain_cell_text(tc, ns: str) -> str:
    """칸 글자를 한 줄로: 칸 안 문단 글자들을 공백 한 칸으로 이어 붙인다."""
    texts = ["".join(p.itertext()) for p in tc.iter(ns + "p")]
    return one_line(" ".join(" ".join(texts).split()))

def plain_table_md(table) -> str:
    """격자를 만들 수 없는 표의 단순 표시: 행마다 칸 글자를 ' | ' 로 이은 줄 + 겹침 안내 줄."""
    rows = []
    for tr in table.element.findall(HP_NS + "tr"):
        cells = [plain_cell_text(tc, HP_NS) for tc in tr.findall(HP_NS + "tc")]
        rows.append(" | ".join(cells))
    rows.append("(표 칸 병합이 겹쳐 단순 표시)")
    return "\n".join(rows)

def mark_table_borders(saved, markers: tuple):
    """_table_to_md 를 감싼다: 겹친 병합 등으로 표 하나에서 예외가 나면 그 표만 단순 표시로 바꾸고,
    HTML 표 결과의 경계 태그 바로 안에는 표식을 넣어 돌려준다. GFM 결과는 건드리지 않는다."""
    def wrap(*args, **kwargs):
        try:
            md = saved(*args, **kwargs)
        except Exception:
            return plain_table_md(args[0])
        if md.startswith("<table>") and md.endswith("</table>"):
            return f"<table>{markers[3]}{md[7:-8]}{markers[4]}</table>"
        return md
    return wrap

def resolve_marked(md: str, markers: tuple) -> str:
    """경계 표식으로 HTML 표 깊이를 세어 표식을 푼다: 표 안 조각은 엔티티로, 바깥 조각은 원래 글자로 되돌리고 경계 표식은 지운다."""
    outside = str.maketrans({m: ch for m, ch in zip(markers[:3], "&<>")})
    inside = str.maketrans({m: ent for m, ent in zip(markers[:3], ("&amp;", "&lt;", "&gt;"))})
    out, depth, pos = [], 0, 0
    for match in re.finditer("[" + re.escape(markers[3] + markers[4]) + "]", md):
        out.append(md[pos:match.start()].translate(outside if depth == 0 else inside))
        depth = depth + 1 if match.group() == markers[3] else max(0, depth - 1)
        pos = match.end()
    out.append(md[pos:].translate(outside if depth == 0 else inside))
    return "".join(out)

def style_detector(level):
    if not level: return lambda text: None
    return lambda text: f"{'#' * level} " + strip_bold(" ".join(text.split()))

def outline_heading_level(levels: dict, para, doc, dedupe, p_to_md):
    """개요 수준은 문단 자체 Markdown 이 라이브러리 중복 제거를 통과하고 문단 글자도 있을 때만. 빈 문단(표·각주만 있는 문단)에는 제목을 주지 않는다."""
    own = dedupe(p_to_md(para.element, doc, None).strip(), para)
    return levels.get(para.element.get("styleIDRef")) if own and (para.text or "").strip() else None

def export_markdown(doc) -> str:
    """문단마다 그 문단의 개요 수준만으로 제목을 정한다(글자 비교·정규식 추측 없음)."""
    try:
        from hwpx.tools import markdown_export as me
        lines_of, image_map, appendix = me._export_paragraph_lines, me._build_image_map, me._export_notes_appendix
        dedupe, p_to_md, saved_escape = me._export_dedupe_md, me._p_element_to_md, me.html_escape
        saved_table = me._table_to_md
    except Exception: return unescape_outside_tables(doc.text.markdown(rich=True))
    markers = pick_markers(doc)
    if markers is None: return unescape_outside_tables(doc.text.markdown(rich=True))
    levels = heading_style_levels(doc)
    mapping, notes, lines = image_map(doc, None, None), [], []
    # 라이브러리의 글자 이스케이프·표 만들기를 표식 버전으로 바꿔 끼웠다가 finally 에서 반드시 되돌린다.
    me.html_escape = lambda text, quote=False: str(text).translate(str.maketrans(dict(zip("&<>", markers[:3]))))
    me._table_to_md = mark_table_borders(saved_table, markers)
    try:
        for section in doc.sections:
            for para in section.paragraphs:
                det = style_detector(outline_heading_level(levels, para, doc, dedupe, p_to_md))
                lines.extend(lines_of(para, doc, mapping, notes, True, det))
    finally:
        me.html_escape, me._table_to_md = saved_escape, saved_table
    body = "\n\n".join(lines)
    if notes: body = appendix(body, notes, "\n\n---\n")
    return resolve_marked(body, markers)

def form_fields_by_key(doc) -> dict[str, list]:
    """label_key(누름틀 이름) → [(fields.all 내 위치, 누름틀), …]. 한컴 누름틀은 여러 개가 같은 fieldid 를 가질 수 있어 위치 번호로 골라 모호함을 피한다."""
    out: dict[str, list] = {}
    for i, field in enumerate(field_entries(doc)):
        name = getattr(field, "name", None)
        if name and (key := label_key(str(name))): out.setdefault(key, []).append((i, field))
    return out

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
        if arg == "--md": i += 1
        elif arg == "--max-chars" and i + 1 < len(argv): max_chars, i = parse_max_chars(argv[i + 1]), i + 2
        elif arg == "--max-chars": raise ToolError("--max-chars 값이 없습니다", 2)
        elif arg.startswith("--max-chars="): max_chars, i = parse_max_chars(arg.split("=", 1)[1]), i + 1
        elif path is None: path, i = arg, i + 1
        else: raise ToolError("파일 인자가 두 개 이상입니다", 2)
    if path is None: raise ToolError("사용법: hwpx read <파일> [--max-chars N]", 2)
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
    doc = open_document(raw)
    full = export_markdown(doc)
    lines = [f"OK {path.absolute()}", full[:max_chars]]
    if len(full) > max_chars: lines.append(read_sidecar_note(path.absolute(), full, max_chars))
    emit(*lines)
    return 0

def cmd_from_md(argv: list[str]) -> int:
    if len(argv) == 1:  # 출력 경로를 줄이면 입력 md 의 확장자만 바꾼 경로(상대 경로는 상대 그대로)
        argv = [argv[0], str(Path(argv[0]).with_suffix(".hwpx"))]
    if len(argv) != 2: raise ToolError("사용법: hwpx from-md <in.md> [out.hwpx]", 2)
    in_raw, out_raw = argv
    ensure_input(in_raw)
    out_abs = check_output_target(out_raw, in_raw)
    doc = HwpxDocument.new()
    counts = render_markdown(doc, read_utf8(in_raw))
    save_validated(doc, out_abs)
    emit(f"OK {out_abs}", f"문단 {counts['paras']}개, 표 {counts['tables']}개 저장, 검증 통과")
    return 0

def fields_slot_lines(doc, slots: dict, note) -> list[str]:
    """표 라벨 목록 줄(문서 순서) + 요약 줄: 위치 키로 fill 불가 를 달고, 문서 전체에 같은 라벨이 둘 이상이면
    문맥( ← …)을 붙인다. 숫자·기호뿐인 라벨 줄은 빼고 개수만, 겹친 병합 표는 건너뜀 알림을 남긴다."""
    pairs = table_roots(doc)
    roots = {t.element: r.element for t, r in pairs}
    paras = preceding_paragraph_texts(doc)
    multi = {key for key, own in slots.items() if len(own) >= 2}
    ordered = sorted((s for own in slots.values() for s in own), key=lambda s: (s["table_no"], s["row"], s["col"]))
    lines, skipped = [], 0
    for slot in ordered:
        if not has_letter(slot["label"]): skipped += 1; continue
        if slot["right_text"].strip(): continue
        key = pos_key(slot)
        context = slot_context(slot, roots, paras) if slot["key"] in multi else ""
        tail = f" ← {context}" if context else ""
        lines.append(f"- {one_line(key)}{tail}{note(key)}")
    lines += [f"표 {no} 은 칸 병합이 겹쳐 건너뜀" for no, (t, _) in enumerate(pairs) if not iter_grid_positions(t)]
    if skipped: lines.append(f"(글자 없는 라벨 {skipped}개는 목록에서 뺌)")
    return lines

def cmd_fields(argv: list[str]) -> int:
    """누름틀·표 라벨 목록을 보여주고, fill 이 거부할 항목을 표시한다."""
    if len(argv) != 1: raise ToolError("사용법: hwpx fields <양식.hwpx>", 2)
    raw = argv[0]
    path = ensure_input(raw)
    doc = open_document(raw)
    if unopenable_reason(doc): raise ToolError(f"한/글이 열지 못하는 문서입니다(필드 표시 id 가 빠졌거나 짝이 없음): {raw}")
    slots = scan_labels(doc)
    fields_by_key = form_fields_by_key(doc)
    nests = field_nesting(doc)
    def note(key: str) -> str:
        reason = fill_blocker(key, fields_by_key, slots, nests)
        return f" (fill 불가: {reason})" if reason else ""
    lines = [f"OK {path.absolute()}"]
    ordered = sorted(fields_by_key.values(), key=lambda es: str(getattr(es[0][1], "name", "")))
    for entries in ordered:
        name = str(getattr(entries[0][1], "name", "") or "")
        lines.append(f"- {one_line(name)} (누름틀 필드){note(name)}")
    lines += fields_slot_lines(doc, slots, note)
    if not any(line.startswith("- ") for line in lines): lines.append("채울 칸을 찾지 못했습니다")
    emit(*lines)
    return 0

# 값(XML 글자) 에 쓸 수 없는 문자: 제어 문자(탭·줄바꿈 제외), 서로게이트, U+FFFE·U+FFFF. DEL(\x7f) 은 허용.
BAD_VALUE_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff￾￿]")
# 누름틀 값은 라이브러리가 저장하며 제어 문자를 지우므로 U+000B·U+000C 도 허용한다.
FIELD_VALUE_RE = re.compile(r"[\x00-\x08\x0e-\x1f\ud800-\udfff￾￿]")

def reject_bad_values(values: dict, fields_by_key: dict) -> None:
    """JSON 순서로 값을 보아(표 칸 값도 같은 경로) 쓸 수 없는 제어 문자가 처음 걸리는 키 하나로 거부한다.
    누름틀 이름으로 채워지는 키만 \x0b·\x0c 를 허용한다."""
    for key, value in values.items():
        if not isinstance(value, str): continue
        pattern = FIELD_VALUE_RE if label_key(key_body(key)) in fields_by_key else BAD_VALUE_RE
        if pattern.search(value):
            raise ToolError(f"값에 쓸 수 없는 제어 문자가 있음: {one_line(key)}")

# 바깥 중괄호를 빼먹은 값.json 을 안내하는 고치는 법(JSONDecodeError 문구 끝에 붙는다).
JSON_BRACES_HINT = "; JSON 은 { 로 시작해 } 로 끝나야 하고 마지막 값 뒤에는 쉼표를 쓰지 않습니다"
# JSON 중첩 깊이 상한. Python 3.13 json 의 재귀 한계(약 1만 겹)보다 낮게 잡아 버전마다 같은 오류를 낸다.
MAX_JSON_DEPTH = 1000

def json_depth_exceeds(data, limit: int) -> bool:
    """컨테이너(dict·list) 만 세어 JSON 겹수가 limit 을 넘는지 재귀 없이 확인한다."""
    stack = [(data, 1)]
    while stack:
        node, depth = stack.pop()
        if isinstance(node, (dict, list)):
            if depth > limit: return True
            items = node.values() if isinstance(node, dict) else node
            stack.extend((item, depth + 1) for item in items)
    return False

def parse_values_text(text: str, raw: str, hook) -> object:
    """JSON 글자를 hook 과 함께 읽는다. 깊음(재귀 한계·겹수 초과 검사)·큰 숫자 오류는 문구 그대로 ToolError 로 바꾼다."""
    try: data = json.loads(text, object_pairs_hook=hook)
    except json.JSONDecodeError: raise
    except RecursionError: raise ToolError(f"JSON 파싱 실패: {raw} (너무 깊음)")
    except ValueError: raise ToolError(f"JSON 파싱 실패: {raw} (숫자가 너무 큼)")
    if json_depth_exceeds(data, MAX_JSON_DEPTH): raise ToolError(f"JSON 파싱 실패: {raw} (너무 깊음)")
    return data

def bare_pairs_retry(text: str, raw: str, hook, exc: json.JSONDecodeError) -> object:
    """중괄호 없는 '"키": "값",' 줄이면 {…} 로 감싸 다시 읽는다. 아니면 원본 오류에 고치는 법을 붙인다."""
    if text.strip() and not text.lstrip().startswith("{"):
        try:
            data = parse_values_text("{" + text + "}", raw, hook)
            if isinstance(data, dict): return data
        except json.JSONDecodeError: pass
    raise ToolError(f"JSON 파싱 실패: {raw} ({exc}){JSON_BRACES_HINT}")

def load_values(raw: str) -> dict:
    """JSON 객체를 읽는다. 같은 키가 두 번 나오는 객체와 값이 문자열·정수가 아닌 객체는 거부한다.
    바깥 중괄호를 빼먹은 글은 {…} 로 감싸 한 번 더 읽어 객체면 그대로 쓴다(빈 글은 제외)."""
    def unique_object(pairs) -> dict:
        out: dict = {}
        for key, value in pairs:
            if key in out: raise ToolError(f"JSON 에 같은 키가 여러 번 있습니다: {key}")
            out[key] = value
        return out
    text = read_utf8(raw)
    try: data = parse_values_text(text, raw, unique_object)
    except json.JSONDecodeError as exc: data = bare_pairs_retry(text, raw, unique_object, exc)
    if not isinstance(data, dict): raise ToolError('JSON 은 {"키": "값"} 객체여야 합니다')
    for key, value in data.items():
        if isinstance(value, bool) or not isinstance(value, (str, int)):
            raise ToolError(f"값은 문자열(또는 정수)이어야 합니다: {one_line(key)}")
    return data

def key_identity(key: str, fields_by_key: dict, slots: dict) -> tuple:
    """키가 가리키는 칸의 정체: (해석한 라벨 키, 누름틀이면 None, 표 자리면 (표 번호, 행, 열)). 같은 칸 가리킴 검사에 쓴다."""
    body = key_body(key)
    parsed = parse_position_key(body)
    fkey = label_key(parsed[0] if parsed else body)
    if fields_by_key.get(fkey): return (fkey, None)
    slot, _ = slot_of_key(body, slots)
    return (fkey, (slot["table_no"], slot["row"], slot["col"])) if slot else (fkey, None)

def duplicate_key_group(values: dict, fields_by_key: dict, slots: dict) -> str | None:
    """해석한 라벨 키+표 자리로 같은 칸을 가리키는 키 묶음. 첫 묶음을 '키, 키' 로."""
    groups: dict[tuple, list[str]] = {}
    for key in values: groups.setdefault(key_identity(key, fields_by_key, slots), []).append(str(key))
    return next((", ".join(keys) for keys in groups.values() if len(keys) >= 2), None)

def slot_blocker(slot: dict) -> str | None:
    """표 자리 하나에 대한 거부 사유: 오른쪽 칸 개체 종류, 이미 값이 있음."""
    kind = slot.get("target_kind")
    if kind: return ("오른쪽 칸이 누름틀임(누름틀 이름으로 채우세요)" if kind == "누름틀" else f"오른쪽 칸에 {kind}가 있음")
    if slot["right_text"].strip(): return "이미 값이 있음"
    return None

def fill_blocker(key: str, fields_by_key: dict, slots: dict, nests: dict | None = None) -> str | None:
    """이 키를 fill 이 거부하는 첫 사유. 채울 수 있으면 None 을 돌려준다. 위치 키(라벨 (표 N, 행 M[, 열 C]))는
    그 자리 하나를, 맨 이름은 누름틀 먼저로 본다."""
    body = key_body(key)
    if ">" in body: return "라벨에 > 가 있음"
    parsed = parse_position_key(body)
    fkey = label_key(parsed[0] if parsed else body)
    entries = fields_by_key.get(fkey) or []
    if parsed is not None:
        slot, reason = slot_of_key(body, slots)
        if reason: return reason
        if slot is None: return "그 위치에 라벨 없음"
        if entries: return "누름틀과 표 라벨이 모두 있음"
        return slot_blocker(slot)
    if entries:
        if fkey in slots: return "누름틀과 표 라벨이 모두 있음"
        if len(entries) >= 2: return "같은 이름의 누름틀이 여러 개"
        field = entries[0][1]
        if not getattr(field, "has_end", True): return "누름틀 끝 표시가 없음"
        if nests and field.element in nests: return nests[field.element]
        value = str(getattr(field, "value", "") or "").strip()
        if not getattr(field, "is_placeholder", False) and value: return "이미 값이 있음"
        return None
    slot, reason = slot_of_key(body, slots)
    if reason: return reason
    if slot is None: return "라벨 없음"
    return slot_blocker(slot)

def fill_one(doc, key: str, text: str, fields_by_key: dict, slots: dict,
             elements: dict, nests: dict | None = None) -> tuple[bool, str]:
    """키 하나를 채운다. 누름틀은 채우는 순간의 위치로, 표는 미리 정한 칸에 쓴다."""
    reason = fill_blocker(key, fields_by_key, slots, nests)
    if reason: return False, reason
    body = key_body(key)
    entries = [] if parse_position_key(body) is not None else (fields_by_key.get(label_key(body)) or [])
    try:
        if entries:
            index = current_field_index(doc, elements[key])
            if index is None: return False, NESTED_FIELD_FAIL
            # 구간이 엇갈린 누름틀: 앞 채우기가 끝 표시를 지웠으면 라이브러리 영어 예외 대신 거부한다.
            if not getattr(field_entries(doc)[index], "has_end", True): return False, CROSSED_FIELD_FAIL
            doc.fill_form_field(text, field_index=index)
        else:
            slot, _ = slot_of_key(body, slots)
            slot["table"].set_cell_text(*slot["target"], text, logical=True)
    except Exception as exc:
        return False, translate_reason(str(exc) or type(exc).__name__)
    return True, ""

def shared_target_conflict(values: dict, fields_by_key: dict, slots: dict) -> str | None:
    """채울 수 있는 표 키 둘 이상이 같은 칸을 가리키면 키 원문을 ', ' 로 이은다."""
    groups: dict = {}
    for key in values:
        if fill_blocker(key, fields_by_key, slots): continue
        body = key_body(key)
        if parse_position_key(body) is None and fields_by_key.get(label_key(body)): continue
        slot, _ = slot_of_key(body, slots)
        if slot is not None: groups.setdefault((slot["table_no"], slot["target"]), []).append(str(key))
    return next((", ".join(keys) for keys in groups.values() if len(keys) >= 2), None)

def fill_targets(values: dict, fields_by_key: dict, slots: dict) -> dict:
    """키 → 채우는 대상 요소. 위치 번호는 채우기마다 당겨지므로 누름틀은 fieldBegin, 표 자리는 표 요소를 기억한다."""
    elements: dict = {}
    for key in values:
        body = key_body(key)
        entries = fields_by_key.get(label_key(body)) if parse_position_key(body) is None else None
        if entries: elements[key] = entries[0][1].element
        elif (slot := slot_of_key(body, slots)[0]) is not None: elements[key] = slot["table"].element
    return elements

def fill_requested(doc, values: dict, fields_by_key: dict, slots: dict, elements: dict, nests: dict,
                   expected: dict) -> tuple[list, dict, list]:
    """요청 키를 모두 채운다: (성공 키, 누름틀 요소 → 채운 값, 실패 (키, 사유) 목록)."""
    ok_keys, filled_values, failures = [], {}, []
    for key, val in values.items():
        ok, reason = fill_one(doc, key, str(val), fields_by_key, slots, elements, nests)
        if ok:
            ok_keys.append(key)
            field = next((f for f in field_entries(doc) if f.element is elements[key]), None)
            if elements[key] in expected and field is not None: filled_values[elements[key]] = field_value(field)
        else: failures.append((key, reason))
    return ok_keys, filled_values, failures

def split_damage(damage: list, expected: dict, merged: dict, ok_keys: list) -> list:
    """손상을 나눈다(merged 를 바꾼다): 손상 요소가 요청 키의 누름틀이고 그 키를 채웠을 때만 그 키에 합치고
    (CROSSED 면 덮어씀), 채우기 전에 실패한 요청 키와 그 밖의 손상은 (이름, 사유) 목록으로
    field_damage 순서(문서 순서)를 지켜 완전히 같은 항목만 한 번으로 줄여 돌려준다."""
    damaged: list = []
    for element, name, reason in damage:
        if element in expected and expected[element] in ok_keys:
            key = expected[element]
            if reason == CROSSED_FIELD_FAIL or key not in merged: merged[key] = reason
        elif (name, reason) not in damaged: damaged.append((name, reason))
    return damaged

def fill_failure_message(merged: dict, damaged: list, ok_keys: list, nonform=None, style=None, hints=None) -> str:
    """요청 키 실패 묶음과 요청 밖 손상 묶음(누름틀·하이퍼링크 등 다른 필드·서식)을 요청 묶음부터 '; ' 로 이어
    하나의 줄로. hints(다시 시도할 키 조각)는 '채우지 못한 키' 조각 바로 뒤에 조각마다 '; ' 로 붙인다."""
    def head() -> str:
        good = [str(key) for key in ok_keys if key not in merged]
        if not good: return "요청한 키를"
        return f"요청한 키({', '.join(good)})를" if len(good) == 1 else f"요청한 키({', '.join(good)}) 중 하나 이상을"
    parts = []
    if merged: parts.append("채우지 못한 키: " + ", ".join(f"{key}({reason})" for key, reason in merged.items()))
    if hints: parts += hints
    if damaged:
        parts.append(head() + " 채우면 다른 누름틀이 바뀜: "
                     + ", ".join(f"{shown_name(name)}({reason})" for name, reason in damaged))
    if nonform: parts.append(head() + " 채우면 하이퍼링크 등 다른 필드가 바뀜")
    if style: parts.append(head() + " 채우면 구간 밖 글자 서식이 바뀜")
    return "; ".join(parts)

def cmd_fill(argv: list[str]) -> int:
    if len(argv) != 3: raise ToolError("사용법: hwpx fill <양식.hwpx> <값.json> <out.hwpx>", 2)
    form_raw, json_raw, out_raw = argv
    for raw in (form_raw, json_raw): ensure_input(raw)
    out_abs = check_output_target(out_raw, form_raw)
    values = load_values(json_raw)
    doc = open_document(form_raw)
    if unopenable_reason(doc):
        raise ToolError(f"한/글이 열지 못하는 문서입니다(필드 표시 id 가 빠졌거나 짝이 없음): {form_raw}")
    slots = scan_labels(doc)
    fields_by_key = form_fields_by_key(doc)
    if (dup := duplicate_key_group(values, fields_by_key, slots)): raise ToolError(f"같은 칸을 가리키는 키가 여러 개: {dup}")
    reject_bad_values(values, fields_by_key)
    conflict = shared_target_conflict(values, fields_by_key, slots)
    if conflict: raise ToolError(f"한 칸을 여러 라벨이 가리킵니다: {conflict}")
    nests = field_nesting(doc)
    elements = fill_targets(values, fields_by_key, slots)
    tracked, orphans, expected = field_snapshot(doc, values, fields_by_key)
    nf_snap, outside = nonform_snapshot(doc, set(expected)), outside_text_styles(doc, expected)
    ok_keys, filled_values, failures = fill_requested(doc, values, fields_by_key, slots, elements, nests, expected)
    failures.extend(missing_after_fill(doc, elements, {key for key, _ in failures}))
    merged: dict = {}
    for key, reason in failures: merged.setdefault(key, reason)
    damaged = split_damage(field_damage(doc, tracked, orphans, expected, filled_values), expected, merged, ok_keys)
    nf_bad, style_bad = nonform_reason(doc, nf_snap), style_damage(doc, outside)
    if merged or damaged or nf_bad or style_bad:
        hints = retry_hints(doc, slots, [key for key, reason in merged.items() if reason == "라벨 없음"])
        msg = fill_failure_message(merged, damaged, ok_keys, nonform=nf_bad, style=style_bad, hints=hints)
        raise ToolError(msg)
    save_validated(doc, out_abs)
    emit(f"OK {out_abs}", f"{len(ok_keys)}개 칸을 채웠습니다, 검증 통과")
    return 0

def cmd_validate(argv: list[str]) -> int:
    if len(argv) != 1: raise ToolError("사용법: hwpx validate <파일.hwpx>", 2)
    raw = argv[0]
    path = ensure_input(raw)
    if sniff_format(path) != "hwpx": raise ToolError(f"검증은 HWPX 파일만 지원합니다: {raw}")
    require_hwpx()
    doc = open_hwpx_or_fail(path, "검증 실패: 유효한 HWPX 파일이 아니거나 손상되었습니다")
    warns = ensure_report_ok(doc.validate(), path, "검증 실패")
    note = f", 경고 {warns}개" if warns else ""
    emit(f"OK {path.absolute()}", f"검증 통과{note}")
    return 0

COMMANDS = {
    "read": cmd_read,
    "from-md": cmd_from_md,
    "fields": cmd_fields,
    "fill": cmd_fill,
    "validate": cmd_validate,
}

def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    handler = COMMANDS.get(argv[0])
    if handler is None: raise ToolError(f"알 수 없는 명령: {argv[0]} (--help 참고)", 2)
    return handler(argv[1:])

def is_security_error(exc: BaseException | None) -> bool:
    """예외 사슬에서 클래스 이름에 SecurityError 가 든 것을 찾는다."""
    seen = set()
    while exc is not None and id(exc) not in seen:
        seen.add(id(exc))
        if "SecurityError" in type(exc).__name__: return True
        exc = exc.__cause__ or exc.__context__
    return False

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
        if is_security_error(exc):
            print(f"ERROR 파일이 너무 큽니다 또는 안전하지 않은 HWPX 입니다: {one_line(str(exc))}")
            return 1
        print(f"ERROR 내부 오류: {one_line(f'{type(exc).__name__}: {exc}')}")
        return 1

if __name__ == "__main__": sys.exit(run(sys.argv[1:]))
