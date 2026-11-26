"""xlsx skill 도구 — 엑셀(XLSX) 통합 문서 읽기·만들기. 출력 규약: 성공은 첫 줄 `OK <절대 경로>`,
실패는 첫 줄 `ERROR <사유>` + exit 1(사용법 오류는 2). Traceback 은 절대 출력하지 않는다."""
from __future__ import annotations
import datetime as dt
import os, re, sys, tempfile, unicodedata, warnings, xml.etree.ElementTree as ET, zipfile, zlib
from decimal import Decimal, ROUND_HALF_UP
from math import isfinite
from pathlib import Path
warnings.filterwarnings("ignore")
sys.dont_write_bytecode = True

try:
    from openpyxl import Workbook, load_workbook
    from openpyxl.styles import Font
    from openpyxl.utils import column_index_from_string, get_column_letter
except Exception as _exc:  # pragma: no cover - 번들 미설치 환경
    print(f"ERROR 라이브러리 없음: openpyxl import 실패 ({' '.join(str(_exc).split())})")
    sys.exit(1)

# 일부 작성 규칙(글꼴 통일, 합계 수식 표시 형식, 자리 표시 경고, 새 함수 경고)은 anthropics/skills
# (https://github.com/anthropics/skills, commit 2c5958ecac7cee2b583967a2c4981d0f4a75c579, Apache-2.0)의 xlsx 지침을 참고했다.

MAX_CHARS_DEFAULT = 6000
MAX_INPUT_MB = 50
MAX_UNCOMPRESSED_MB = 200
MAX_MD_BYTES = 5 * 1024 * 1024  # from-md 입력 마크다운 상한(읽기 전에 검사)
MAX_TABLE_COLUMNS = 16384   # Excel 최대 열 수
MAX_TABLE_ROWS = 1048576    # Excel 최대 행 수
MAX_TABLE_CELLS = 1000000   # 표를 만들 때 칸 수 상한(메모리 폭주 방지)
MB = 1024 * 1024
ZIP_MAGIC = b"PK\x03\x04"
# zip 항목을 풀다가 나올 수 있는 '깨진 파일' 신호들. 내부 오류가 아닌 안내로 바꾼다.
CORRUPT_ZIP_ERRORS = (zipfile.BadZipFile, zlib.error, EOFError, RuntimeError, KeyError)
# XML 이 불허하는 제어 문자(탭 \t·줄바꿈 \n \r 은 제외)와 유니코드 비문자는 조용히 지운다.
XML_ILLEGAL_RE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")
# Excel 숫자 정밀도(유효 숫자 15자리)를 넘는 입력은 글자로 둔다.
MAX_SIGNIFICANT_DIGITS = 15
OLE_MAGIC = bytes.fromhex("D0CF11E0A1B11AE1")
OLE_MSG = "구형 .xls 형식입니다. Excel 에서 .xlsx 로 다시 저장해 주세요"
USAGE = """xlsx — 엑셀(XLSX) 통합 문서 도구
사용법: xlsx read <파일.xlsx> [--max-chars N] / from-md <in.md> [out.xlsx] / --help
read: 시트마다 `## 시트 이름` 과 마크다운 표로 보여준다(수식은 수식 글자 그대로). 전체본은 <파일>.xlsx.md 로 저장한다.
from-md: 마크다운 표(| 칸 | 칸 |)를 시트로 만든다. 표 바깥 글은 무시하고, 가장 가까운 앞 제목 줄을 시트 이름으로 쓴다.
쓰기 명령의 출력 경로는 입력과 같거나 이미 존재하면 거부한다. 성공 시 첫 줄이 `OK <경로>`, 실패 시 `ERROR <사유>`."""

class ToolError(Exception):
    """ERROR 한 줄로 바꿔 출력할 사용자 단 예외."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message); self.message, self.code = message, code

def emit(*lines: str) -> None:
    print("\n".join(lines))

def one_line(text) -> str:
    """줄바꿈·겹친 공백을 한 칸 공백으로 눌러 한 줄로 만든다."""
    return " ".join(str(text).split())

def strip_illegal_chars(text: str) -> str:
    """PDF 에서 붙여 넣은 제어 문자 등 엑셀 시트에 넣을 수 없는 글자는 만들기 전에 지운다."""
    return XML_ILLEGAL_RE.sub("", text)

def reject_control_chars(raw: str) -> None:
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw): raise ToolError("경로에 줄바꿈 등 제어 문자가 있습니다")

def sniff_format(path: Path, raw: str) -> str | None:
    """확장자 대신 앞 바이트로 형식을 판별한다: zip(OOXML 컨테이너) / ole(구형 이진 형식) / None."""
    try:
        with open(path, "rb") as fh: head = fh.read(8)
    except OSError as exc:
        raise ToolError(f"파일을 읽을 수 없습니다({exc.strerror or '권한 확인'}): {raw}") from exc
    if head.startswith(ZIP_MAGIC): return "zip"
    if head.startswith(OLE_MAGIC): return "ole"
    return None

def check_input_size(path: Path, raw: str) -> None:
    """입력 크기 제한: 파일 50MB, zip 이면 압축 해제 합계 200MB. 파싱 전에 거부한다."""
    try: size = path.stat().st_size
    except OSError as exc:
        raise ToolError(f"파일을 읽을 수 없습니다({exc.strerror or '권한 확인'}): {raw}") from exc
    if size > MAX_INPUT_MB * MB: raise ToolError(f"파일이 너무 큽니다: {raw} (최대 {MAX_INPUT_MB}MB)")
    if sniff_format(path, raw) != "zip": return
    try:
        with zipfile.ZipFile(path) as zf: total = sum(info.file_size for info in zf.infolist())
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"XLSX 파일이 손상되었습니다: {raw}") from exc
    if total > MAX_UNCOMPRESSED_MB * MB:
        raise ToolError(f"파일이 너무 큽니다: 압축을 풀면 {(total + MB - 1) // MB}MB, 최대 {MAX_UNCOMPRESSED_MB}MB")

def ensure_input(raw: str) -> Path:
    reject_control_chars(raw)
    path = Path(raw)
    if not path.is_file(): raise ToolError(f"파일 없음: {raw}")
    check_input_size(path, raw)
    return path

def absolute_path(raw: str) -> Path:
    """셸이 보는 논리 경로(PWD 환경변수) 기준 절대 경로. /tmp → /private/tmp 심볼릭 링크에서도 셸 접두사를 유지한다."""
    path = Path(raw)
    if path.is_absolute(): return path
    cwd = os.environ.get("PWD") or os.getcwd()
    try:
        if not os.path.isabs(cwd) or os.path.realpath(cwd) != os.path.realpath("."): cwd = os.getcwd()
    except OSError:
        cwd = os.getcwd()
    return Path(cwd) / path

def check_output_target(out_raw: str, in_raw: str) -> Path:
    reject_control_chars(out_raw)
    out_abs = absolute_path(out_raw)
    if in_raw and out_abs == absolute_path(in_raw): raise ToolError(f"출력 경로가 입력과 같습니다: {out_raw}")
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

def write_sidecar(side: Path, full: str) -> None:
    """배타적 생성으로 열어 전체본을 쓴다. 쓰기가 실패하면 만든 파일을 지운다."""
    fd = os.open(side, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh: fh.write(full)
    except OSError:
        side.unlink(missing_ok=True)
        raise

def read_sidecar_note(path: Path, full: str, max_chars: int) -> str:
    """전체본을 <파일명>.xlsx.md 로 저장하고 안내 문구를 돌려준다. 실패해도 계속한다."""
    side = path.with_name(path.name + ".md")
    try: write_sidecar(side, full)
    except FileExistsError: return f"(앞 {max_chars}자만 표시. 전체본은 저장하지 않음: {side} 가 이미 있습니다)"
    except OSError as exc: return f"(앞 {max_chars}자만 표시. 전체본 저장 실패: {one_line(exc.strerror or type(exc).__name__)})"
    return f"(앞 {max_chars}자만 표시. 전체 저장: {side})"

def publish_workbook(wb, out_abs: Path) -> None:
    """임시 파일에 저장한 뒤 umask 권한으로 하드 링크 게시. 실패 시 임시 파일을 지우고 출력 경로는 그대로 둔다."""
    fd, tmp_name = tempfile.mkstemp(dir=str(out_abs.parent), prefix=".xlsx-", suffix=".tmp")
    os.close(fd); tmp = Path(tmp_name)
    try:
        wb.save(str(tmp))
        mask = os.umask(0); os.umask(mask)
        os.chmod(tmp, 0o666 & ~mask)
        try: os.link(str(tmp), str(out_abs))
        except FileExistsError: raise ToolError(f"출력 경로가 이미 존재합니다: {out_abs}")
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

def whole_cell_bold(text: str) -> str | None:
    """칸 전체가 `**굵게**` 로 감싸져 있으면 굵은 글자를, 아니면 None."""
    pieces = split_bold(text)
    if len(pieces) == 1 and pieces[0][1] and pieces[0][0]: return pieces[0][0]
    return None

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
    if len(rows) > MAX_TABLE_ROWS:
        raise ToolError(f"표가 너무 깁니다(행 {len(rows)}개, 최대 {MAX_TABLE_ROWS}개). 표를 나눠 주세요")
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

HEADING_RE = re.compile(r"(#{1,})\s+(.*)$")

def collect_tables(text: str) -> list[tuple[tuple[int, str] | None, list[str]]]:
    """표 블록마다 (가장 가까운 앞 제목 (줄 번호, 제목 글자) 또는 None, 표 블록) 을 문서 순서로 모은다."""
    lines, out, last, i = text.splitlines(), [], None, 0
    while i < len(lines):
        stripped = lines[i].strip()
        if not stripped: i += 1
        elif stripped.startswith("|"):
            block = []
            while i < len(lines) and lines[i].strip().startswith("|"): block.append(lines[i].strip()); i += 1
            if parse_md_table(block) is not None: out.append((last, block))
        else:
            match = HEADING_RE.match(stripped) if stripped.startswith("#") else None
            if match is not None: last = (i, strip_bold(match.group(2)).strip())
            i += 1
    return out

SHEET_BAD_CHARS_RE = re.compile(r"[\[\]:*?/\\]")
RESERVED_SHEET_NAMES = {"history"}  # Excel 예약 이름(대소문자 무시)

def sanitise_sheet_name(name: str) -> str:
    """엑셀이 금지하는 문자는 _ 로 바꾸고 31자로 자른다. 앞뒤 작은따옴표는 Excel 이 거부하므로 떼어 낸다.
    빈 이름이나 예약 이름(History) 이면 빈 글자를 돌려줘 caller 가 '시트N' 으로 물러가게 한다."""
    cleaned = SHEET_BAD_CHARS_RE.sub("_", name).strip("'")[:31]
    if not cleaned or cleaned.lower() in RESERVED_SHEET_NAMES: return ""
    return cleaned

def unique_sheet_name(name: str, existing: set) -> str:
    """이미 있는 이름이면 ' (2)', ' (3)' … 을 붙인다(통합 문서 시트 이름은 31자 이하여야 한다)."""
    if name not in existing: return name
    n = 2
    while True:
        suffix = f" ({n})"
        candidate = name[:31 - len(suffix)] + suffix
        if candidate not in existing: return candidate
        n += 1

def assign_sheet_names(tables: list) -> list[str]:
    """표마다 시트 이름을 정한다: 앞 제목 줄(아직 앞 표가 쓰지 않은 것)이면 그 제목, 아니면 '시트N'(N 은 이 통합 문서에서의 순서)."""
    used_lines, existing, names = set(), set(), []
    for position, (heading, _) in enumerate(tables, 1):
        title = ""
        if heading is not None and heading[0] not in used_lines and heading[1]:
            title = sanitise_sheet_name(heading[1]); used_lines.add(heading[0])
        name = unique_sheet_name(title or f"시트{position}", existing)
        existing.add(name); names.append(name)
    return names

# DDE 구분符 '|' 와 외부로 나가는 함수가 든 수식은 엑셀이 열 때 위험하므로 글자로만 넣는다.
# \b 단어 경계로 겉옷을 입혀 RECALL_TOTAL·EXECUTIVE 같은 이름의 일부(=SUM(RECALL_TOTAL), =EXECUTIVE!A1)는 수식으로 남긴다.
DANGER_FORMULA_RE = re.compile(r"\b(WEBSERVICE|FILTERXML|CALL|REGISTER\.ID|EXEC|HYPERLINK|RTD|SQL\.REQUEST)\b", re.I)
# 외부 참조: UNC 경로(\\), http(s) URL, 다른 통합 문서 참조([a.xlsx], [1]).
EXTERNAL_REF_RE = re.compile(r"\\\\|https?://|\[[^\]]*\]")

def is_dangerous_formula(text: str) -> bool:
    return "|" in text or bool(DANGER_FORMULA_RE.search(text)) or bool(EXTERNAL_REF_RE.search(text))

# ── 깨진 수식 검사 ──
# `=` 뒤 몸통을 왼쪽부터 한 번만 훑는다(역추적하는 정규식은 쓰지 않는다: 아주 긴 수식에서 느려진다).
# 문자열(")·시트 이름(') 안의 글자는 검사에서 빼고, 따옴표 밖에서만 괄호·중괄호 깊이·생략 부호(...·…)·연산자를 본다.
BROKEN_TRAILING_CHARS = "+-*/^&,=<>(;:"
# 이항으로만 쓰이는 * / ^ 는 왼쪽 항이 필요하다: 몸통의 첫 공백 아닌 글자이거나 이 글자들 바로 뒤에 오면 깨진 수식.
BINARY_ONLY_AFTER = frozenset("+-*/^&=<>,(:;{")

def is_dangling_binary(ch: str, prev: str) -> bool:
    """* / ^ 가 몸통의 첫 공백 아닌 글자(prev == "")이거나, 직전 글자가 왼쪽 항이 올 수 없는
    글자(연산자·여는 괄호·쉼표·콜론 등)인지 본다. + - 는 단항으로도 쓰이므로 대상에서 뺀다."""
    return ch in "*/^" and (not prev or prev in BINARY_ONLY_AFTER)

def is_broken_formula(formula: str) -> bool:
    """수식 껍데기가 온전한지 본다. 깨진 경우: 몸통이 비거나 공백뿐인 경우(= 하나), 문자열·시트 이름이 닫히지
    않은 경우, 괄호·중괄호({}) 깊이가 0 밑으로 내려가거나 끝까지 0 이 되지 않는 경우, 배열 상수({...}) 밖의 ;,
    따옴표 밖의 생략 부호(… 는 언제나, ... 는 그것을 담은 식별자 묶음(글자·숫자·_·.)이 바로 뒤에 ! 를 만나지
    못한 경우로 시트 이름 참조 Sales...2026!B2 는 뺀다), 이항으로만 쓰이는 * / ^ 가 왼쪽 항 없이 온 경우,
    끝의 공백 아닌 마지막 글자가 연산자(+ - * / ^ & , = < > ( ; :)인 경우. 문자열 안의 괄호·점은 글자로 친다."""
    body = formula[1:]
    if not body.strip(): return True
    depth = brace = dots = 0
    quote, prev, pending = "", "", False
    i, size = 0, len(body)
    while i < size:
        ch = body[i]
        if quote:  # 문자열·시트 이름 안: 겹친 따옴표(""·'') 는 이스케이프, 홀수 번째 따옴표가 닫는다
            if ch != quote: i += 1
            elif i + 1 < size and body[i + 1] == quote: i += 2
            else: prev, quote, i = quote, "", i + 1  # 닫는다: 닫은 뒤의 직전 글자는 따옴표로 친다
            continue
        in_run = ch.isalnum() or ch in "_."  # 식별자 묶음(시트 이름·참조)을 이루는 글자
        if pending and not in_run:  # ... 을 품은 묶음이 끝났다: ! 앞이면 시트 이름, 아니면 생략 부호
            if ch == "!": pending = False
            else: return True
        if ch in "\"'": quote = ch
        elif ch == "…": return True
        elif ch == "(": depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0: return True
        elif ch == "{": brace += 1
        elif ch == "}":
            brace -= 1
            if brace < 0: return True
        elif ch == ";" and brace == 0: return True  # ; 는 배열 상수({1;2}) 안에서만 쓴다
        elif is_dangling_binary(ch, prev): return True
        elif ch == ".":
            dots += 1
            if dots >= 3: pending = True  # 즉시 깨진다고 하지 않고 묶음이 끝나는 자리에서 판정
        if ch != ".": dots = 0
        if not ch.isspace(): prev = ch  # 따옴표 밖의 직전 공백 아닌 글자(연산자·끝글자 검사에 쓴다)
        i += 1
    return bool(quote) or depth != 0 or brace != 0 or pending or prev in BROKEN_TRAILING_CHARS

def significant_digits(text: str) -> int:
    """표기에서 유효 숫자 자릿수: 부호·쉼표·소수점·% 를 뺀 숫자 개수."""
    return sum(1 for ch in text if ch.isdigit())

def typed_value(text: str) -> tuple[object, str | None]:
    """셀 글자를 (값, 숫자 서식) 으로 정한다. 어떤 모양이든 유효 숫자가 15자리를 넘거나 결과가 inf/nan 이면 글자로 둔다."""
    if significant_digits(text) > MAX_SIGNIFICANT_DIGITS: return (text, None)
    match = re.fullmatch(r"-?(0|[1-9]\d*)(\.\d+)?", text)
    if match:
        return (float(text) if match.group(2) else int(text), None)
    match = re.fullmatch(r"(-?[1-9]\d{0,2}(?:,\d{3})+)(\.\d+)?", text)
    if match:
        frac = match.group(2) or ""
        number = text.replace(",", "")
        fmt = "#,##0." + "0" * (len(frac) - 1) if frac else "#,##0"  # 입력의 소수 자릿수를 그대로 보존(1,234.5 → #,##0.0)
        return (float(number) if frac else int(number), fmt)
    match = re.fullmatch(r"(-?\d+(?:\.\d+)?)%", text)
    if match:
        frac = match.group(1).partition(".")[2]
        value = float(Decimal(match.group(1)) / Decimal(100))  # Decimal 나누기로 12% → 정확히 0.12
        if not isfinite(value): return (text, None)  # 터무니없이 큰 백분율이 inf 로 넘치면 글자로
        return (value, "0%" if not frac else "0." + "0" * len(frac) + "%")
    return (text, None)

# 글꼴 통일: from-md 이 쓰는 모든 칸(머리 행 포함)은 맑은 고딕 한 가지로. 굵기는 머리 행·`**x**` 칸만.
FONT_PLAIN = Font(name="맑은 고딕")
FONT_BOLD = Font(name="맑은 고딕", bold=True)

def set_cell(ws, row: int, col: int, text: str, header: bool, warns: list, broken: list) -> None:
    """한 칸을 쓴다: 빈 칸은 비워 두고, `**x**` 전체 굵게·수식·숫자 종류를 가려 넣는다.
    위험하거나 깨진 수식은 값은 넣되 글자(String)로 저장해 계산을 막는다. 깨진 수식은 broken 에 (시트, 칸, 수식)를 남긴다."""
    cell = ws.cell(row=row, column=col)
    value_text, bold = text, header
    whole = whole_cell_bold(text)
    if whole is not None: value_text, bold = whole, True
    if value_text == "": return
    if value_text.startswith("="):
        cell.value = value_text
        if is_dangerous_formula(value_text):
            cell.data_type = "s"  # 위험한 수식은 값은 넣되 글자(String)로 저장해 계산을 막는다.
            warns.append(f"경고 위험한 수식을 글자로 넣음: {cell.coordinate}")
        elif is_broken_formula(value_text):
            cell.data_type = "s"  # 깨진 수식은 엑셀이 열 때 '복구' 창을 띄우고 지우므로 글자(String)로 넣는다.
            broken.append((ws.title, cell.coordinate, value_text))
    else:
        value, fmt = typed_value(value_text)
        cell.value = value
        if fmt: cell.number_format = fmt
    cell.font = FONT_BOLD if bold else FONT_PLAIN

def display_width(text: str) -> int:
    """표시 너비: 한글 등 전각 문자는 2칸으로 센다."""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)

def fill_sheet(ws, rows: list[list[str]], warns: list, broken: list) -> None:
    """머리 행(1행) + 데이터 행을 쓰고, 틀 고정과 열 너비를 정한다."""
    ncols = max(len(row) for row in rows)
    widths = [0] * ncols
    for r, row in enumerate(rows, 1):
        for c in range(ncols):
            text = row[c] if c < len(row) else ""
            set_cell(ws, r, c + 1, text, r == 1, warns, broken)
            widths[c] = max(widths[c], display_width(strip_bold(text)))
    ws.freeze_panes = "A2"
    for c in range(ncols):
        ws.column_dimensions[get_column_letter(c + 1)].width = max(8, min(60, widths[c] + 2))

def build_workbook(text: str) -> tuple[Workbook, list[str]]:
    tables = collect_tables(text)
    if not tables: raise ToolError("마크다운에 표가 없습니다. '| 칸 | 칸 |' 모양의 표를 넣어 주세요")
    names = assign_sheet_names(tables)
    wb = Workbook(); wb.remove(wb.active)
    warns: list[str] = []
    broken: list[tuple[str, str, str]] = []
    for name, (_, block) in zip(names, tables):
        fill_sheet(wb.create_sheet(title=name), parse_md_table(block), warns, broken)
    inherit_formula_formats(wb)  # 참조 칸의 서식이 다 정해진 뒤(모든 시트를 쓴 다음)에만 할 수 있다
    warn_placeholders(wb, warns)
    warn_modern_functions(wb, warns)
    warn_broken_formulas(broken, warns)
    return wb, warns

def cells_in_order(wb):
    """쓴 칸을 시트·행·열 순서로 (시트, 칸) 쌍으로 돌려준다. ws._cells 만 보므로 새 칸을 만들지 않는다."""
    for ws in wb.worksheets:
        for _, cell in sorted((getattr(ws, "_cells", None) or {}).items()):
            yield ws, cell

# ── 합계 수식 표시 형식 물려받기 ──
# 대상은 (a) 중첩 괄호 없는 단일 SUM·AVERAGE·MIN·MAX·SUBTOTAL 호출(인자는 참조만), (b) 같은 시트 칸 참조의 +·- 연결.
# 나누기(/)·곱(*)·거듭제곱(^)·붙이기(&)·문자열(")·다른 시트(!) 가 들어간 수식은 비율이 0 처럼 보이는 일이 없도록 General 을 유지한다.
TOTAL_FUNC_RE = re.compile(r"(SUM|AVERAGE|MIN|MAX|SUBTOTAL)\(([^()]*)\)", re.I)
REF_CHAIN_RE = re.compile(r"\$?[A-Za-z]{1,3}\$?\d+(\s*[+-]\s*\$?[A-Za-z]{1,3}\$?\d+)*")
CELL_OR_RANGE_RE = re.compile(r"\$?([A-Za-z]{1,3})\$?(\d+)(?::\$?([A-Za-z]{1,3})\$?(\d+))?")
# 통째 열(A:A, $A:$B)·통째 행(3:3, 1:1048576) 참조. 칸 수가 언제나 MAX_RANGE_CELLS 를 넘으므로
# '참조 아님'으로 건너뛰는 게 아니라 못 쓰는 참조로 봐야 한다(=SUM(A:A,B2) 가 B2 서식을 물려받는 일 방지).
WHOLE_COLUMN_RE = re.compile(r"\$?[A-Za-z]{1,3}:\$?[A-Za-z]{1,3}")
WHOLE_ROW_RE = re.compile(r"\$?\d+:\$?\d+")
MAX_RANGE_CELLS = 10000        # 이보다 큰 범위는 펼치지 않고 General 유지
MAX_FORMAT_LOOKUPS = 2000000   # 통합 문서 전체 칸 조회 상한(넘으면 상속을 멈춘다)
MAX_FORMAT_PASSES = 20         # 수식이 수식을 가리킬 수 있어 고정점까지 반복

def total_formula_args(formula: str) -> list[str] | None:
    """형식을 물려받을 수식의 인자 목록. 대상이 아니면 None. 대소문자·공백은 허용한다."""
    body = formula[1:].strip()
    if any(ch in body for ch in '!*/^&"'): return None
    match = TOTAL_FUNC_RE.fullmatch(body)
    if match is not None: return [arg.strip() for arg in match.group(2).split(",")]
    if REF_CHAIN_RE.fullmatch(body) is not None: return re.split(r"\s*[+-]\s*", body)
    return None

def arg_ref_bounds(ref: str) -> tuple[int, int, int, int] | None:
    """인자 하나(B2 또는 B2:D2, $ 허용)의 참조 범위 (행 처음·끝, 열 처음·끝) 를 돌려준다.
    칸을 실제로 펼쳐 만들지 않으므로 범위가 아무리 커도 메모리는 그대로다.
    참조 모양이 아니거나(숫자·이름) 해석할 수 없으면 None."""
    match = CELL_OR_RANGE_RE.fullmatch(ref)
    if match is None: return None
    try:
        cols = [column_index_from_string(g.upper()) for g in (match.group(1), match.group(3) or match.group(1))]
        rows = [int(g) for g in (match.group(2), match.group(4) or match.group(2))]
    except ValueError:
        return None
    return (min(rows), max(rows), min(cols), max(cols))

def formula_ref_ranges(args: list[str]) -> list[tuple[int, int, int, int]] | None:
    """인자의 참조 범위를 (펼치지 않은) 경계 목록으로 검사해 돌려준다. 못 쓰는 참조(해석 안 되는 참조,
    표 한계 밖 좌표, 칸 수 상한 초과, 통째 열·행)가 하나라도 있으면 None(수식 전체가 General 유지).
    엑셀은 콜론 앞뒤 공백을 허용하므로(A : A) 검사 전에 지운다. 그래도 콜론이나 내부 공백이 남은 인자가
    참조로 해석되지 않으면(=SUM(B2 B2) 의 교집합 등) 해석할 수 없는 참조로 본다(None).
    애초에 참조가 아닌 인자(=SUM(1,2) 의 숫자, 정의된 이름)는 건너뛴다."""
    ranges: list[tuple[int, int, int, int]] = []
    for arg in args:
        arg = re.sub(r"\s*:\s*", ":", arg)  # 엑셀은 A : A 처럼 콜론 앞뒤 공백을 허용한다
        if WHOLE_COLUMN_RE.fullmatch(arg) is not None or WHOLE_ROW_RE.fullmatch(arg) is not None:
            return None  # 통째 열·행은 칸 수가 언제나 상한을 넘는다
        bounds = arg_ref_bounds(arg)
        if bounds is None:
            if CELL_OR_RANGE_RE.fullmatch(arg) is not None: return None  # 참조 모양인데 해석할 수 없음
            if ":" in arg or re.search(r"\s", arg) is not None: return None  # 콜론·내부 공백이 남은 해석 불가 참조
            continue  # 참조가 아닌 인자(숫자·정의된 이름)는 건너뛴다
        rlo, rhi, clo, chi = bounds
        if not (1 <= rlo <= rhi <= MAX_TABLE_ROWS and 1 <= clo <= chi <= MAX_TABLE_COLUMNS): return None
        if (rhi - rlo + 1) * (chi - clo + 1) > MAX_RANGE_CELLS: return None
        ranges.append(bounds)
    return ranges

def first_referenced_format(ws, formula: str, budget: list[int]) -> str | None:
    """수식이 가리키는 칸을 차례로 보아 General 이 아닌 첫 형식을 돌려준다. 대상이 아니거나 못 찾으면 None.
    칸 좌표는 범위를 그때그때 행 우선(왼쪽위부터)으로 펼쳐 돌리므로 수식이 길어도 메모리가 늘지 않는다.
    budget[0] 은 남은 칸 조회 수 상한이다."""
    args = total_formula_args(formula)
    if args is None: return None
    ranges = formula_ref_ranges(args)
    if ranges is None: return None
    written = getattr(ws, "_cells", None) or {}
    for rlo, rhi, clo, chi in ranges:
        for r in range(rlo, rhi + 1):
            for c in range(clo, chi + 1):
                if budget[0] <= 0: return None
                budget[0] -= 1
                cell = written.get((r, c))
                if cell is not None and cell.number_format != "General": return cell.number_format
    return None

def inherit_formula_formats(wb) -> None:
    """대상 수식에 첫 참조 칸의 표시 형식을 물려준다(=SUM(B2:B4) 아래 1,000 칸들이면 #,##0).
    수식이 아직 형식 없는 수식을 가리킬 수 있어 바뀌는 게 없을 때까지(최대 20번) 반복한다."""
    targets = [(ws, cell) for ws, cell in cells_in_order(wb)
               if cell.data_type == "f" and isinstance(cell.value, str) and cell.value.startswith("=")]
    budget = [MAX_FORMAT_LOOKUPS]
    for _ in range(MAX_FORMAT_PASSES):
        changed = False
        for ws, cell in targets:
            if budget[0] <= 0: return
            if cell.number_format != "General": continue
            fmt = first_referenced_format(ws, cell.value, budget)
            if fmt is not None: cell.number_format = fmt; changed = True
        if not changed: break

# ── 자리 표시 경고 ──
# [ ]·[내용 입력] 모양, TODO(대소문자 구분), lorem·ipsum·xxx(대소문자 무시), ○○. 한글에 붙어 있어도(TODO) 잡는다.
# 자유 형식: [기획 1월 금액]·[담당자 이름] 같은 값 이름 끝 대괄호, [목표 1] 류 번호 붙은 대괄호(링크 [이름](…)·[이름][ref], 쌍점 든 참고·별첨 대괄호 제외).
PLACEHOLDER_RE = re.compile(
    r"\[\s*\]"
    r"|\[(?:(?i:insert)|입력|내용|여기)[^\]\n]{0,30}\]"
    r"|\[[^\[\]\n:]{0,30}(?:금액|액수|이름|성함|성명|회사명|기관명|부서명|날짜|일자|일시|시작일|종료일|마감일|숫자|수치|연락처|전화번호|이메일|주소)(?:[ \t]?\d{1,2})?[ \t]?\](?![(\[])"
    r"|\[[^\[\]\n:]{0,30}(?:업무|항목|목표|사항|내용)[ \t]?\d{1,2}[ \t]?\](?![(\[])"
    r"|(?<![A-Za-z])TODO(?![A-Za-z])"
    r"|(?<![A-Za-z])(?i:lorem|ipsum|xxx)(?![A-Za-z])"
    r"|○○")
MAX_PLACEHOLDERS_SHOWN = 5

def warn_placeholders(wb, warns: list) -> None:
    """값을 쓴 칸(머리 행·수식 글자 포함)에 자리 표시가 남아 있으면 첫 발견 순서(최대 5개)로 한 줄 알린다.
    5개를 모으면 더는 훑지 않고 곧바로 빠져나온다(서로 다른 토큰 수십만 개에서 시간 초과 방지).
    토큰 안 줄바꿈·겹친 공백은 한 칸으로 눌러 경고 줄이 여러 줄로 깨지지 않게 한다.
    경고는 결과를 바꾸지 않는다: rc 는 그대로 0, 파일은 그대로 만든다."""
    tokens: list[str] = []
    seen: set[str] = set()
    for _, cell in cells_in_order(wb):
        if cell.value is None: continue
        for match in PLACEHOLDER_RE.finditer(str(cell.value)):
            token = " ".join(match.group(0).split())
            if token not in seen:
                seen.add(token); tokens.append(token)
                if len(tokens) >= MAX_PLACEHOLDERS_SHOWN: break
        if len(tokens) >= MAX_PLACEHOLDERS_SHOWN: break
    if tokens:
        joined = ", ".join(tokens)
        warns.append(one_line(f"경고 자리 표시가 남아 있음: {joined} — 실제 값으로 채우거나 사용자에게 물어보세요"))

# ── 옛 엑셀에 없는 함수 경고 ──
MODERN_FUNCS = ("CONCAT", "TEXTJOIN", "IFS", "SWITCH", "MAXIFS", "MINIFS", "XLOOKUP", "XMATCH",
                "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "LET", "LAMBDA", "RANDARRAY")
MODERN_FUNC_RE = re.compile(
    r"(?<![A-Za-z0-9_.])(" + "|".join(sorted(MODERN_FUNCS, key=len, reverse=True)) + r")\s*\(", re.I)
STRING_LITERAL_RE = re.compile(r'"(?:[^"]|"")*"')

def warn_modern_functions(wb, warns: list) -> None:
    """옛 엑셀(2016 이전)에 없는 함수를 쓴 수식 칸마다 한 줄 알린다. 수식은 그대로 둔다(_xlfn. 을 붙이지 않는다).
    문자열 안 글자(=IF(A3="SORT(",1,0))는 함수로 보지 않는다."""
    for _, cell in cells_in_order(wb):
        if cell.data_type != "f" or not isinstance(cell.value, str): continue
        found: list[str] = []
        for match in MODERN_FUNC_RE.finditer(STRING_LITERAL_RE.sub("", cell.value)):
            name = match.group(1).upper()
            if name not in found: found.append(name)
        if found:
            names, coord = ", ".join(found), cell.coordinate
            warns.append(f"경고 옛 엑셀에 없는 함수: {names} ({coord}) — SUMIFS·INDEX/MATCH·IFERROR 로 바꾸면 어디서나 열립니다")

# ── 깨진 수식 경고 ──
MAX_BROKEN_SHOWN = 5       # 경고에 보여 주는 칸 좌표 수(넘으면 '외 N칸')
BROKEN_EXAMPLE_CHARS = 40  # 경고의 예 수식 길이 상한(넘으면 자르고 … 를 붙인다)

def warn_broken_formulas(broken: list, warns: list) -> None:
    """글자로 넣은 깨진 수식 칸이 있으면 한 줄로 알린다: 칸 좌표(쓴 순서, 최대 5개 + 외 N칸; 깨진 수식이
    하나라도 나온 첫 시트가 아니면 좌표 앞에 '시트이름!' 을 붙인다)와 첫 수식 예(40자까지).
    경고는 결과를 바꾸지 않는다: rc 는 그대로 0, 파일은 그대로 만든다."""
    if not broken: return
    first_sheet = broken[0][0]
    coords = [coord if sheet == first_sheet else f"{sheet}!{coord}" for sheet, coord, _ in broken]
    shown = ", ".join(coords[:MAX_BROKEN_SHOWN])
    if len(coords) > MAX_BROKEN_SHOWN: shown += f" 외 {len(coords) - MAX_BROKEN_SHOWN}칸"
    example = broken[0][2]
    if len(example) > BROKEN_EXAMPLE_CHARS: example = example[:BROKEN_EXAMPLE_CHARS] + "…"
    warns.append(one_line(f"경고 깨진 수식을 글자로 넣음: {shown} (예: {example}) — 괄호·문자열·참조를 고쳐 다시 만드세요"))

COMMA_FMT_RE = re.compile(r"#,##0(\.(0+))?")
PERCENT_FMT_RE = re.compile(r"0(\.(0+))?%")

def format_number(value, fmt: str) -> str:
    """숫자를 서식대로 표시: #,##0 → 1,000 / 0% → 12%(백분율에는 쉼표를 넣지 않는다) / 일반은 1.0 → 1, 3.5 → 3.5."""
    if fmt and fmt != "General":
        match = COMMA_FMT_RE.fullmatch(fmt)
        if match: return f"{value:,.{len(match.group(2) or '')}f}"
        match = PERCENT_FMT_RE.fullmatch(fmt)
        if match:
            digits = len(match.group(2) or "")
            scaled = (Decimal(str(value)) * 100).quantize(Decimal(1).scaleb(-digits), rounding=ROUND_HALF_UP)
            return f"{scaled:.{digits}f}%"  # 1200% 처럼 큰 백분율도 쉼표 없이 → 왕복해도 같은 수식으로 읽힌다
    if isinstance(value, float) and value == int(value) and abs(value) < 1e16: return str(int(value))
    return str(value)

def format_cell_value(cell) -> str:
    """칸 값을 표시 글자로: 빈 칸은 '', 수식은 수식 글자(배열 수식은 그 안의 .text), 비정상 숫자(inf/nan)는
    그 글자를 그대로, 날짜는 ISO 날짜(자정이면 시간 생략), 숫자는 서식대로. 칸 안 줄바꿈은 한 줄로 눌러 표가 깨지지 않게 한다."""
    value = cell.value
    if value is None: return ""
    if cell.data_type == "f":
        return one_line(getattr(value, "text", None) or str(value))  # ArrayFormula 는 .text(수식 글자)
    if isinstance(value, bool): return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)) and not isinstance(value, bool) and not isfinite(value):
        return one_line(str(value))  # <v>inf</v> 같은 비정상값: 숫자 서식을 거치지 않고 글자로
    if isinstance(value, dt.datetime):
        text = value.strftime("%Y-%m-%d") if (value.hour, value.minute, value.second, value.microsecond) == (0, 0, 0, 0) \
            else value.isoformat(sep=" ")
        return one_line(text)
    if isinstance(value, (dt.date, dt.time)): return one_line(value.isoformat())
    if isinstance(value, (int, float)): return format_number(value, cell.number_format)
    return one_line(str(value))

def cell_markdown(cell, header: bool) -> str:
    r"""칸 하나의 마크다운 표시: 헤더는 굵게 표시 없이, 데이터 칸이 굵은 글꼴이면 **값** 으로, | 는 \| 로."""
    text = format_cell_value(cell).replace("|", "\\|")
    if not header and text and cell.value is not None and cell.font is not None and cell.font.b:
        return f"**{text}**"
    return text

# read 표시 상한: 성긴 시트(XFD1048576 같은 아주 먼 칸)에서 쓰인 범위 전체를 만들지 않도록 앞 200행×50열만 보여준다.
MAX_SHEET_ROWS_SHOWN = 200
MAX_SHEET_COLS_SHOWN = 50

def sheet_to_markdown(ws) -> str:
    """시트 하나를 `## 시트 이름` + GFM 표로. 값이 하나도 없으면 (빈 시트).
    쓰인 칸(ws._cells) 만 보므로 아주 먼 칸 하나 때문에 전체 범위를 만들지 않고, 잘려 나가면 (일부만 표시) 로 알린다."""
    lines = [f"## {ws.title}"]
    cells = getattr(ws, "_cells", None) or {}
    # openpyxl 은 스타일만 있고 값 없는 칸(굵은 글꼴·채움만 넣은 빈 칸)도 ws._cells 에 남긴다.
    # 표시 창의 시작은 값 있는 칸으로만 잡는다. 그렇지 않으면 A1 이 스타일만 있는 칸이고 값이 A300 에만
    # 있을 때 창(앞 200행) 안에 값이 하나도 없어 빈 표가 되고 만다.
    valued = [(r, c) for (r, c) in cells if cells[(r, c)].value is not None]
    if not valued:
        lines.append("(빈 시트)")
        return "\n".join(lines)
    min_r = min(r for r, _ in valued); max_r = max(r for r, _ in valued)
    min_c_all = min(c for _, c in valued); max_c = max(c for _, c in valued)
    r_hi = min(max_r, min_r + MAX_SHEET_ROWS_SHOWN - 1)
    # 시작 열(min_c)은 창의 행 범위(min_r..r_hi) 안에 있는 값 있는 칸으로만 정한다. min_r 은 값 있는 칸의
    # 행이므로 이 집합은 비지 않고, min_c 를 준 칸은 창 안에 있으므로 shown 이 비지 않는다. 창 밖에 남은 값
    # (A300 처럼 아래·왼쪽으로 빠진 칸)은 표에 없으니 (일부만 표시) 로 알린다.
    min_c = min(c for r, c in valued if min_r <= r <= r_hi)
    c_hi = min(max_c, min_c + MAX_SHEET_COLS_SHOWN - 1)
    # 표시 창 안에서 실제로 값이 있는 마지막 행·열까지만 칸을 만든다(빈 칸 도배로 본문이 잘리지 않게).
    shown = [(r, c) for r, c in valued if min_r <= r <= r_hi and min_c <= c <= c_hi]
    last_r = max(r for r, _ in shown); last_c = max(c for _, c in shown)
    for r in range(min_r, last_r + 1):
        row_texts = [cell_markdown(ws.cell(row=r, column=c), r == min_r) for c in range(min_c, last_c + 1)]
        lines.append("| " + " | ".join(row_texts) + " |")
        if r == min_r: lines.append("| " + " | ".join(["---"] * (last_c - min_c + 1)) + " |")
    if any(not (min_r <= r <= last_r and min_c <= c <= last_c) for r, c in valued):
        lines.append(f"(일부만 표시: 앞 {last_r - min_r + 1}행 × {last_c - min_c + 1}열, "
                     f"전체 {max_r - min_r + 1}행 × {max_c - min_c_all + 1}열)")
    return "\n".join(lines)

def workbook_to_markdown(wb) -> str:
    return "\n\n".join(sheet_to_markdown(ws) for ws in wb.worksheets)

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

NONNUM_V_RE = re.compile(rb"<c\b[^>]*>\s*<v>([^<]+)</v>")
T_ATTR_RE = re.compile(rb'\s+t="[^"]*"')

def openpyxl_parses_number(val: bytes) -> bool:
    """openpyxl _cast_number 와 같은 규칙으로 숫자가 읽히는지 본다: 점·E 가 없으면 int() 만 시도한다('inf'·'nan' 은 죽는다)."""
    s = val.decode("ascii", "replace")
    if "." in s or "E" in s or "e" in s:
        try: float(s); return True
        except ValueError: return False
    try: int(s); return True
    except ValueError: return False

def sanitise_nonnumeric_v(data: bytes) -> bytes:
    """시트 XML 에서 <v>값</v> 이 openpyxl 숫자 파싱에 실패하는 값이면 그 칸을 글자(t="str") 로 바꾼다."""
    def repl(match):
        whole, val = match.group(0), match.group(1)
        if openpyxl_parses_number(val): return whole
        open_tag = whole.split(b">", 1)[0]  # '<c r="A2" t="n"' 처럼 닫는 '>' 앞까지만
        open_tag = T_ATTR_RE.sub(b"", open_tag) + b' t="str"'  # 숫자(t="n") 표시는 글자 표시로 바꾼다
        return open_tag + b"><v>" + val + b"</v>"
    return NONNUM_V_RE.sub(repl, data)

def load_workbook_safe(path: Path, raw: str):
    """통합 문서를 연다. <v>inf</v> 같은 비정상 숫자값 때문에 openpyxl 이 죽으면 그 칸만 글자로 바꿔 다시 읽는다."""
    try:
        return load_workbook(str(path))  # data_only 기본값: 수식은 계산값이 아니라 수식 글자로 읽는다.
    except ValueError:
        pass
    fd, tmp_name = tempfile.mkstemp(suffix=".xlsx")
    os.close(fd); tmp = Path(tmp_name)
    try:
        with zipfile.ZipFile(path) as zi, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
            for info in zi.infolist():
                data = zi.read(info.filename)
                if info.filename.startswith("xl/worksheets/") and info.filename.endswith(".xml"):
                    data = sanitise_nonnumeric_v(data)
                zo.writestr(info, data)
        return load_workbook(str(tmp))
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"XLSX 파일이 손상되었습니다: {raw}") from exc
    except Exception as exc:
        raise ToolError(f"XLSX 파일을 읽지 못했습니다: {raw}") from exc
    finally:
        if tmp.exists(): tmp.unlink(missing_ok=True)

def open_workbook(raw: str, path: Path):
    """형식을 가려 xlsx 만 연다: 구형 OLE, 다른 OOXML, zip 아님·OOXML 아님은 각각 안내로 거부한다."""
    fmt = sniff_format(path, raw)
    if fmt == "ole": raise ToolError(f"{OLE_MSG}: {raw}")
    if fmt is None: raise ToolError(f"XLSX 파일이 아닙니다: {raw}")
    try:
        with zipfile.ZipFile(path) as zf:
            kind = ooxml_kind_from_rels(zf)
            has_types = "[Content_Types].xml" in zf.namelist()
    except CORRUPT_ZIP_ERRORS as exc:
        raise ToolError(f"XLSX 파일이 손상되었습니다: {raw}") from exc
    if kind == "docx": raise ToolError(f"워드(.docx) 문서입니다. docx 스킬을 사용해 주세요: {raw}")
    if kind == "pptx": raise ToolError(f"파워포인트(.pptx) 문서입니다. pptx 스킬을 사용해 주세요: {raw}")
    if kind != "xlsx":
        if has_types: raise ToolError(f"OOXML 이 아닌 zip 파일이거나 XLSX 가 아닙니다: {raw}")
        raise ToolError(f"XLSX 파일이 손상되었습니다: {raw}")
    return load_workbook_safe(path, raw)

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
    if path is None: raise ToolError("사용법: xlsx read <파일.xlsx> [--max-chars N]", 2)
    return path, max_chars

def cmd_read(argv: list[str]) -> int:
    raw, max_chars = parse_read_args(argv)
    path = ensure_input(raw)
    wb = open_workbook(raw, path)
    full = workbook_to_markdown(wb)
    abs_path = absolute_path(raw)
    lines = [f"OK {abs_path}", full[:max_chars]]
    if len(full) > max_chars: lines.append(read_sidecar_note(abs_path, full, max_chars))
    emit(*lines)
    return 0

def cmd_from_md(argv: list[str]) -> int:
    if len(argv) == 1:  # 출력 경로를 줄이면 입력 md 의 확장자만 바꾼 경로(상대 경로는 상대 그대로)
        argv = [argv[0], str(Path(argv[0]).with_suffix(".xlsx"))]
    if len(argv) != 2: raise ToolError("사용법: xlsx from-md <in.md> [out.xlsx]", 2)
    in_raw, out_raw = argv
    if not out_raw.lower().endswith(".xlsx"): raise ToolError(f"출력 파일 확장자는 .xlsx 여야 합니다: {out_raw}")
    ensure_input(in_raw)
    text = strip_illegal_chars(read_utf8(in_raw))
    if not text.strip(): raise ToolError(f"입력 파일이 비어 있습니다: {in_raw}")
    out_abs = check_output_target(out_raw, in_raw)
    wb, warns = build_workbook(text)
    publish_workbook(wb, out_abs)
    cells = sum(ws.max_row * ws.max_column for ws in wb.worksheets)
    emit(f"OK {out_abs}", f"시트 {len(wb.sheetnames)}개, 칸 {cells}개 저장", *warns)
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
