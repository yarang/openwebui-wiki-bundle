"""표 라벨 자리·위치 키·문맥 묶음 — hwpx_tool 에서 옮겨 왔다. hwpx_tool 을 import 하지 않는다."""
from __future__ import annotations
import re
from hwpx_fields import key_body, label_key, one_line, field_entries

# 위치 키: '라벨 (표 N, 행 M[, 열 C])'. 라벨에 줄바꿈이 섞여 있어도(-S) 맞아야 한다.
POS_KEY_RE = re.compile(r"^(.*) \(표 (\d+), 행 (\d+)(?:, 열 (\d+))?\)$", re.S)
NO_SLOT_AT_POS = "그 위치에 라벨 없음"
ROW_NEEDS_COL = "같은 행에 같은 라벨이 여러 칸: 열 을 붙이세요"

def parse_position_key(body: str):
    """위치 키 모양이면 (라벨, 표 번호, 행, 열|None), 아니면 None."""
    match = POS_KEY_RE.match(body)
    if match is None: return None
    col = match.group(4)
    return (match.group(1), int(match.group(2)), int(match.group(3)), None if col is None else int(col))

def clean_label(text: str) -> str:
    """표시용 라벨: 연속 공백 문자(줄바꿈·탭 포함)를 공백 한 칸으로 줄이고 앞뒤 공백을 뗀다."""
    return re.sub(r"\s+", " ", str(text)).strip()

def pos_key(slot: dict) -> str:
    """자리의 위치 키: '라벨 (표 N, 행 M)'. 문서에 같은 라벨이 여러 칸이면(multi) 라벨의 줄바꿈·탭을
    공백 한 칸으로 줄여 보이고, 같은 행에 같은 라벨이 여러 칸이면 ', 열 C' 까지 붙인다.
    한 칸뿐인 라벨은 글자 그대로(줄바꿈은 \\n) 보인다."""
    label = clean_label(slot["label"]) if slot.get("multi") else slot["label"]
    base = f"{label} (표 {slot['table_no']}, 행 {slot['row']}"
    return f"{base}, 열 {slot['col']})" if slot["dup_row"] else f"{base})"

def slot_of_key(body: str, slots: dict) -> tuple:
    """키 몸통이 가리키는 표 자리 하나를 (자리, 사유) 로. 위치 키면 그 자리를 고르고, 맨 이름은 그
    라벨의 자리가 하나일 때만 고른다. 자리를 못 고르면 사유(후보 위치 키 나열)를 채운다."""
    parsed = parse_position_key(body)
    own = slots.get(label_key(parsed[0] if parsed else body)) or []
    if parsed is None:
        if len(own) == 1: return own[0], None
        if len(own) >= 2:
            return None, "같은 라벨이 여러 칸: " + ", ".join(pos_key(s) for s in own) + " 중 하나를 키로 쓰세요"
        return None, None
    _, table_no, row, col = parsed
    matched = [s for s in own if s["table_no"] == table_no and s["row"] == row]
    if col is None and len(matched) >= 2: return None, ROW_NEEDS_COL
    if col is not None: matched = [s for s in matched if s["col"] == col]
    if not matched: return None, NO_SLOT_AT_POS
    return matched[0], None

def has_letter(text: str) -> bool:
    """라벨에 글자(isalpha)가 하나라도 있는지. 숫자·기호뿐인 라벨을 가려낸다."""
    return any(ch.isalpha() for ch in text)

def iter_grid_positions(table) -> list:
    """표의 모든 논리 칸 위치. 망가진 표(겹치는 병합 등)는 빈 목록으로 본다."""
    try:
        return list(table.iter_grid())
    except (AttributeError, TypeError, ValueError, IndexError):
        return []

def table_roots(doc) -> list[tuple]:
    """(표, 가장 바깥 표) 목록. 최상위 표부터 표 안의 표까지 깊이 우선(표 번호 순서)."""
    out: list[tuple] = []
    def walk(tables, root):
        for table in tables:
            top = root or table
            out.append((table, top))
            for pos in iter_grid_positions(table):
                if not pos.is_anchor: continue
                try: nested = table.cell(*pos.anchor).tables
                except Exception: continue
                if nested: walk(nested, top)
    try:
        walk(list(doc.tables.all), None)
    except (AttributeError, TypeError):
        pass
    return out

OBJECT_KIND_BY_TAG = {t: ("누름틀" if t == "fieldBegin" else "표" if t == "tbl" else "그림·개체") for t in (
    "fieldBegin tbl pic rect ellipse line arc polygon curve connectLine container ole equation textart checkBtn "
    "radioBtn btn comboBox listBox edit scrollBar video chart").split()}

def table_cell_text(table, row: int, col: int) -> str:
    """칸 글자(문단 줄바꿈은 \n). 칸이 없으면 빈 문자열."""
    try: cell = table.cell(row, col)
    except Exception: return ""
    paras = list(getattr(cell, "paragraphs", None) or [])
    return "\n".join(p.text or "" for p in paras) if paras else (cell.text or "")

def cell_target_kind(table, row: int, col: int, field_elements) -> str | None:
    """칸 요소 자손의 개체 종류 하나(누름틀 > 표 > 그림·개체). 문서 누름틀(doc.fields.all) 외의 fieldBegin(하이퍼링크·메모 등)은 그림·개체로 센다."""
    try:
        element = table.cell(row, col).element
        kinds = set()
        for el in element.iter():
            name = el.tag.rsplit("}", 1)[-1]
            if name == "fieldBegin":
                kinds.add("누름틀" if any(el is fe for fe in field_elements) else "그림·개체")
            elif name in OBJECT_KIND_BY_TAG: kinds.add(OBJECT_KIND_BY_TAG[name])
        return next(k for k in ("누름틀", "표", "그림·개체") if k in kinds)
    except Exception:
        return None

def field_key_pairs(doc) -> list[tuple]:
    """(누름틀 요소, 이름의 label_key) 목록. 누름틀 판정은 doc.fields.all 과 같아 하이퍼링크·메모 필드는 여기에 없다."""
    return [(f.element, label_key(str(n)) if (n := getattr(f, "name", None)) else "") for f in field_entries(doc)]

def grid_cell_element(table, pos):
    """논리 칸 위치의 요소. 칸을 얻지 못하면 None."""
    try:
        return table.cell(*pos).element
    except Exception:
        return None

def has_same_name_field(element, key: str, fkeys: list[tuple]) -> bool:
    """칸 요소 자손에 그 라벨과 같은 이름의 누름틀(fieldBegin) 이 있는지. 칸을 못 얻었으면 없는 것으로 본다."""
    return element is not None and any(
        el.tag.rsplit("}", 1)[-1] == "fieldBegin" and any(el is fe for fe, fkey in fkeys if fkey == key)
        for el in element.iter())

def scan_labels(doc) -> dict[str, list[dict]]:
    """라벨 키 → 문서 순서의 자리 목록. 자리는 label/key/table_no/table/row/col/row_span/dup_row/
    target/target_kind/right_text 를 담는다. 누름틀이 든 칸과 같은 이름 누름틀이 있는 오른쪽 칸 자리는
    라벨로 세지 않고, 맨 끝 열의 글자도 라벨이 아니다."""
    slots: dict[str, list[dict]] = {}
    fkeys = field_key_pairs(doc)
    field_elements = [el for el, _ in fkeys]
    for no, (table, _) in enumerate(table_roots(doc)):
        positions = iter_grid_positions(table)
        grid = {(p.row, p.column): tuple(p.anchor) for p in positions}
        for pos in (p for p in positions if p.is_anchor):
            row, col = pos.row, pos.column
            if cell_target_kind(table, row, col, field_elements) == "누름틀": continue
            label = table_cell_text(table, row, col).strip()
            right = grid.get((row, col + (getattr(pos, "col_span", 1) or 1)))
            key = label_key(label)
            if not key or right is None: continue
            if has_same_name_field(grid_cell_element(table, right), key, fkeys): continue
            slots.setdefault(key, []).append({
                "label": label, "key": key, "table_no": no, "table": table,
                "row": row, "col": col, "row_span": getattr(pos, "row_span", 1) or 1, "dup_row": False,
                "target": right, "target_kind": cell_target_kind(table, *right, field_elements),
                "right_text": table_cell_text(table, *right),
            })
    mark_row_columns(slots)
    return slots

def mark_row_columns(slots: dict) -> None:
    """라벨 자리에 겹침 표시를 단다: 같은 표·같은 행에 둘 이상이면 dup_row(위치 키에 열을 붙인다),
    문서 전체에 둘 이상이면 multi(위치 키 라벨의 줄바꿈·탭을 공백 한 칸으로 줄인다)."""
    row_counts: dict[tuple, int] = {}
    key_counts: dict[str, int] = {}
    for own in slots.values():
        for slot in own:
            where = (slot["key"], slot["table_no"], slot["row"])
            row_counts[where] = row_counts.get(where, 0) + 1
            key_counts[slot["key"]] = key_counts.get(slot["key"], 0) + 1
    for own in slots.values():
        for slot in own:
            slot["dup_row"] = row_counts[(slot["key"], slot["table_no"], slot["row"])] >= 2
            slot["multi"] = key_counts[slot["key"]] >= 2

def left_group_texts(table, row: int, col: int, row_span: int) -> list[str]:
    """같은 행에서 라벨 칸 왼쪽 칸 중 행 병합(row_span)이 라벨 칸보다 큰 칸의 글자(왼쪽부터, 같은 칸은 한 번)."""
    grid = {}
    for pos in iter_grid_positions(table): grid[(pos.row, pos.column)] = pos
    out, seen = [], set()
    for c in range(col):
        pos = grid.get((row, c))
        if pos is None or pos.row_span <= row_span or pos.anchor in seen: continue
        seen.add(pos.anchor)
        text = one_line(" ".join(table_cell_text(table, *pos.anchor).split()))
        if text: out.append(text)
    return out

def preceding_paragraph_texts(doc) -> dict:
    """가장 바깥 표 요소 → 그 표보다 앞 본문 문단(표를 담지 않고 글자가 있는 것) 최대 2개."""
    paras = [p for section in doc.sections for p in section.paragraphs]
    texts = ["" if p.tables else one_line(" ".join((p.text or "").split())) for p in paras]
    hosts = {table.element: i for i, p in enumerate(paras) for table in p.tables}
    return {element: [t for t in texts[:i] if t][-2:] for element, i in hosts.items()}

def slot_context(slot: dict, roots: dict, paras: dict) -> str:
    """자리의 문맥: 왼쪽 묶음 칸 글자들 + 표 앞 본문 문단 글자들을 ' / ' 로 이어 40자 까지(넘치면 '…')."""
    parts = left_group_texts(slot["table"], slot["row"], slot["col"], slot["row_span"])
    parts += paras.get(roots.get(slot["table"].element), [])
    text = " / ".join(parts)
    return text[:40] + "…" if len(text) > 40 else text

def compact_text(text: str) -> str:
    """느슨한 비교용 글자: 모든 공백 문자를 지우고 casefold."""
    return re.sub(r"\s+", "", str(text)).casefold()

def hint_candidates(body: str, slots: dict) -> list:
    """후보 (자리, 나머지 글자) 목록을 문서 순서로. 후보는 라벨 키를 공백 제거한 글자(2자 이상)가 공백
    제거한 키 몸통에 들어 있는 자리이고, 나머지는 몸통에서 그 라벨 글자를 한 번 뺀 것이다."""
    ordered = sorted((s for own in slots.values() for s in own),
                     key=lambda s: (s["table_no"], s["row"], s["col"]))
    return [(s, body.replace(label, "", 1)) for s in ordered
            if len(label := compact_text(s["key"])) >= 2 and label in body]

def context_score(rest: str, context: str) -> int:
    """나머지 글자와 문맥의 일치 점수: 나머지(공백 제거)가 문맥(공백 제거)에 통째로 들어 있으면 그 길이,
    아니면 문맥을 ' / ' 로 나눈 조각(공백 제거해 2자 이상) 중 나머지에 들어 있는 것의 가장 긴 길이.
    나머지가 비어 있거나 어느 쪽도 아니면 0 이다(0 보다 크면 문맥과 맞는 것이다)."""
    compact_rest = compact_text(rest)
    if not compact_rest: return 0
    if compact_rest in compact_text(context): return len(compact_rest)
    lengths = [len(piece) for part in context.split(" / ")
               if len(piece := compact_text(part)) >= 2 and piece in compact_rest]
    return max(lengths) if lengths else 0

def retry_key_hint(key: str, slots: dict, roots: dict, paras: dict) -> str:
    """모르는 키 대신 써 볼 위치 키 글자: 문맥과 맞는 후보 중 점수가 가장 높은 자리만(같으면 모두),
    맞는 것이 없으면 후보 전부(문서 순서, 최대 6개, 넘으면 ' 외 N개'). 후보가 없으면 fields 줄 복사 안내."""
    body = compact_text(key_body(key))
    cands = hint_candidates(body, slots)
    scored = [(s, context_score(rest, slot_context(s, roots, paras))) for s, rest in cands]
    hits = [(s, score) for s, score in scored if score > 0]
    best = max((score for _, score in hits), default=0)
    picked = [s for s, score in hits if score == best] if best else [s for s, _ in cands]
    if not picked: return "없음(fields 줄의 키를 그대로 복사)"
    text = " 또는 ".join(pos_key(s) for s in picked[:6])
    return f"{text} 외 {len(picked) - 6}개" if len(picked) > 6 else text

def retry_hints(doc, slots: dict, keys: list) -> list[str]:
    """사유 '라벨 없음' 으로 거부된 키들의 '다시 시도할 키: …' 조각 목록. fields 와 같은 방식의
    문맥 글자(roots·paras)로 계산하며 keys 가 비면 계산하지 않는다."""
    if not keys: return []
    roots = {t.element: r.element for t, r in table_roots(doc)}
    paras = preceding_paragraph_texts(doc)
    return [f"다시 시도할 키: {key} → {retry_key_hint(key, slots, roots, paras)}" for key in keys]
