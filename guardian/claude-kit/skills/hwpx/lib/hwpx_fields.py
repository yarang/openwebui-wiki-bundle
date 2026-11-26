"""누름틀·라벨 분석 묶음 — hwpx_tool 에서 옮겼고 hwpx_tool 을 import 하지 않는다."""
from __future__ import annotations
import copy, re

_CTRL_ESCAPES = {9: "\\t", 10: "\\n", 13: "\\r"}

def one_line(text: str) -> str:
    """제어·서로게·비문자(U+FFFE/U+FFFF) 글자를 이스케이프 글자로 바꿔 한 줄로 만든다."""
    out = []
    for ch in str(text):
        code = ord(ch)
        if code in _CTRL_ESCAPES: out.append(_CTRL_ESCAPES[code])
        elif (32 <= code != 127 and not 0xD800 <= code <= 0xDFFF and code not in (0xFFFE, 0xFFFF)):
            out.append(ch)
        elif code <= 0xFF: out.append(f"\\x{code:02x}")
        else: out.append(f"\\u{code:04x}")
    return "".join(out)

def label_key(text: str) -> str:
    """라벨 비교 규칙: 공백을 한 칸으로 줄이고 casefold 한 뒤 끝의 ':' 를 뗀다."""
    key = re.sub(r"\s+", " ", str(text)).strip().casefold()
    while key.endswith((":", "：")): key = key[:-1].rstrip()
    return key

def key_body(text: str) -> str:
    """fill 이 받는 키 몸통: 첫 ' ← ' 부터 뒤(문맥)를 버리고 이어서 끝의 ' (fill 불가: …)' 도 버린다.
    fields 줄을 통째로 키로 붙여도 그 칸을 가리키게 한다."""
    body = str(text).split(" ← ", 1)[0]
    return re.sub(r" \(fill 불가: .*\)$", "", body).strip()

def field_entries(doc) -> list:
    """doc.fields.all 목록. 라이브러리가 누름틀을 못 찾으면 빈 목록."""
    try:
        return list(doc.fields.all)
    except AttributeError:
        return []

NESTED_FIELD_FAIL = "다른 누름틀 안에 있어 함께 채울 수 없음"
CROSSED_FIELD_FAIL = "다른 누름틀과 구간이 겹쳐 채울 수 없음"
NONFORM_CROSS = "하이퍼링크 등 다른 필드와 구간이 겹침"
NONFORM_NEST = "하이퍼링크 등 다른 필드를 품고 있음"
STYLE_FAIL = "채우면 구간 밖 글자 서식이 바뀜"
INSIDE_NONTEXT_FAIL = "구간 안에 글자가 아닌 내용이 있음"

HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"

def field_positions(doc) -> dict:
    """문서 순서로 fieldBegin·fieldEnd 에 하나의 번호를 매겨 짝짓는다: fieldBegin 요소 → (시작 번호, 끝 번호 또는 None).
    각 시작의 짝은 그 시작 뒤에서 처음 나오는 같은 id 의 끝이며, 시작보다 앞의 떠도는 끝은 무시한다. id 가 없는 시작은 제외한다."""
    pending: dict[str, list] = {}
    out: dict = {}
    marks = (el for s in doc.sections for el in s.element.iter(HP + "fieldBegin", HP + "fieldEnd"))
    for n, el in enumerate(marks):
        if el.tag == HP + "fieldBegin":
            if el.get("id") is not None: pending.setdefault(el.get("id"), []).append((el, n))
        elif el.get("beginIDRef") is not None:
            for begin, b in pending.pop(el.get("beginIDRef"), ()): out[begin] = (b, n)
    for begin, b in (pair for pairs in pending.values() for pair in pairs): out[begin] = (b, None)
    return out

def shown_name(name: str) -> str:
    """사유·손상 문구의 누름틀 이름 자리. one_line 한 결과가 공백뿐이면 (이름 없음) 으로 보여 준다."""
    line = one_line(name)
    return line if line.strip() else "(이름 없음)"

TRIAL_LIMIT = 50
COMPLEX_MSG = "구조가 복잡해 미리 판정 못 함"

def wide_spans(doc, fields) -> tuple:
    """끝 있는 누름틀의 넓은 구간(시작 요소 → (시작 번호, 가장 먼 같은 id 끝 번호))을 문서를 한 번 훑어 만든다.
    두 번째 값은 시작 요소 → 시작 번호 사전(시작이 없으면 없다)."""
    idx: dict = {}
    ends: dict = {}
    marks = (el for s in doc.sections for el in s.element.iter(HP + "fieldBegin", HP + "fieldEnd"))
    for n, el in enumerate(marks):
        if el.tag == HP + "fieldBegin":
            if el.get("id") is not None: idx[el] = n
        elif el.get("beginIDRef"):
            ref = el.get("beginIDRef")
            if ref not in ends or ends[ref] < n: ends[ref] = n
    spans = {}
    for f in fields:
        b, e = idx.get(f.element), ends.get(f.element.get("id"))
        if b is None or e is None or e <= b or not getattr(f, "has_end", True): continue
        spans[f.element] = (b, e)
    return spans, idx

def trial_candidates(doc, fields) -> list:
    """시범 채우기를 해 볼 누름틀 번호(문서 순서): 구간이 다른 표시를 걸치는 누름틀과(busy),
    어떤 busy 구간 안에 시작 번호가 든 끝 있는 누름틀. 차분 배열 누적합으로 O(n) 에 가린다."""
    spans, idx = wide_spans(doc, fields)
    size = max((e for _, e in spans.values()), default=-1) + 1
    diff = [0] * (size + 1)
    for b, e in spans.values():
        if e - b > 1: diff[b + 1] += 1; diff[e] -= 1
    covered, run = [False] * size, 0
    for p in range(size):
        run += diff[p]; covered[p] = run > 0
    return [i for i, f in enumerate(fields) if f.element in spans
            and (spans[f.element][1] - spans[f.element][0] > 1 or covered[idx[f.element]])]

def classify(c, i) -> str:
    """사본 문서 c 의 i 번 누름틀에 실제로 '가' 를 채워 보고 망가지는 것이 있으면 사유, 없으면 빈 문자열.
    누름틀이 망가지는 것이 먼저고, 그다음 하이퍼링크 등 누름틀 아닌 필드, 마지막으로 자신을 본다."""
    fields = field_entries(c)
    F = fields[i]
    pos = field_positions(c)
    P = [pos.get(f.element, (None, None)) for f in fields]
    snap = [(f.element, str(f.name or ""), field_value(f), getattr(f, "has_end", True)) for f in fields]
    orph = orphan_end_ids(c)
    others = nonform_snapshot(c, {F.element})
    c.fill_form_field("가", field_index=i)
    live = {f.element: f for f in field_entries(c)}
    new_orph = orphan_end_ids(c) - orph
    for n, (el, name, val, ended) in enumerate(snap):
        if n == i: continue
        if el.get("id") in new_orph: return f"다른 누름틀 {shown_name(name)} 와 구간이 겹침"
        if el not in live or not is_attached(c, el): return f"다른 누름틀 {shown_name(name)} 를 품고 있음"
        if ended and not getattr(live[el], "has_end", True): return f"다른 누름틀 {shown_name(name)} 와 구간이 겹침"
        if field_value(live[el]) != val:
            inside = (None not in (P[n][0], P[n][1], P[i][0], P[i][1])
                      and P[n][0] < P[i][0] and P[i][1] <= P[n][1])
            return f"다른 누름틀 {shown_name(name)} " + ("안에 있음" if inside else "와 구간이 겹침")
    why = nonform_reason(c, others)
    if why: return why
    if F.element not in live or not getattr(live[F.element], "has_end", True) or field_value(live[F.element]) != "가":
        return CROSSED_FIELD_FAIL
    return ""

def field_nesting(doc) -> dict:
    """품거나 품긴 누름틀의 fieldBegin 요소 → 사유. 위치 규칙 대신 문서 사본에 실제로 채워 보고
    (시범 채우기) 다른 누름틀이나 자신이 망가지는 것만 사유를 댄다. 원본 문서는 바꾸지 않는다.
    시범 채우기가 이미 사유를 낸 누름틀은 그 사유가 우선하고, 나머지 끝 있는 누름틀은 정적 서식 규칙으로 본다."""
    fields = field_entries(doc)
    out: dict = {}
    for k, i in enumerate(trial_candidates(doc, fields)):
        if k >= TRIAL_LIMIT:
            out[fields[i].element] = COMPLEX_MSG
            continue
        try:
            r = classify(copy.deepcopy(doc), i)
        except Exception:
            r = COMPLEX_MSG
        if r: out[fields[i].element] = r
    out.update({el: why for el, why in style_failures(doc, fields).items() if el not in out})
    return out

def mark_run(mark):
    """표시(fieldBegin) 가 든 hp:ctrl 의 부모 hp:run. 구조가 다르면 None."""
    ctrl = mark.getparent()
    run = ctrl.getparent() if ctrl is not None else None
    return run if run is not None and run.tag == HP + "run" else None

def _first_child(el):
    """첫 자식 요소(주석·처리 명령은 건너뛴다). 없으면 None."""
    return next((c for c in el if isinstance(c.tag, str)), None)

def unopenable_reason(doc) -> bool:
    """한/글이 열지 않는 문서인지 XML 로 직접 본다(저장 전 라이브러리 검증과 같은 조건):
    (a) id 속성 없는(빈 문자열 포함) fieldBegin, (b) beginIDRef 없는(빈 문자열 포함) fieldEnd,
    (c) run 첫 자식 ctrl 의 fieldEnd beginIDRef 와 같은 id 의 fieldBegin 이 모든 섹션 어디에도 없음."""
    roots = [s.element for s in doc.sections]
    begins = {el.get("id") for root in roots for el in root.iter(HP + "fieldBegin") if el.get("id")}
    for root in roots:
        for el in root.iter(HP + "fieldBegin", HP + "fieldEnd"):
            if el.tag == HP + "fieldBegin" and not el.get("id"): return True
            if el.tag == HP + "fieldEnd" and not el.get("beginIDRef"): return True
        for run in root.iter(HP + "run"):
            ctrl = _first_child(run)
            if ctrl is None or ctrl.tag != HP + "ctrl": continue
            end = _first_child(ctrl)
            if (end is not None and end.tag == HP + "fieldEnd"
                    and end.get("beginIDRef") not in begins): return True
    return False

# python-hwpx 가 글자로 읽는 hp:t 자식 요소 이름(라이브러리 내부 목록과 같음).
TEXT_CHILD_NAMES = frozenset(("tab", "lineBreak", "hyphen", "nbSpace", "fwSpace"))
# 화면에 그려지는 글자가 없는 표시 요소 이름(알려진 것). 이것만 있고 tail 글자도 없으면 내용이 아니다.
BLANK_MARK_NAMES = frozenset(("markpenBegin", "markpenEnd", "titleMark"))

def local_name(el) -> str:
    """요소 이름에서 네임스페이스를 뗀 local name. 주석 따위 요소가 아닌 노드는 빈 문자열."""
    tag = el.tag
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""

def t_visible(t) -> bool:
    """hp:t 가 화면에 그려지는 것을 품는지: 글자가 있거나, 자식에게 tail 글자가 있거나,
    자식이 글자 요소이거나, 모르는 자식이 있으면(보수적으로) 참. 알려진 글자 없는 표시만
    tail 없이 든 hp:t 는 거짓."""
    if t.text: return True
    return any(child.tail or local_name(child) not in BLANK_MARK_NAMES for child in t)

# 화면에 글자를 그리지 않는 hp:ctrl 자식 요소 이름(허용 목록). 이 목록 밖의 ctrl 자식은 모두 '보임'으로 본다.
CTRL_BLANK_NAMES = frozenset(("fieldBegin", "fieldEnd", "bookmark", "hiddenComment", "colPr",
                              "pageHiding", "pageNumCtrl", "newNum"))

def unit_run(el):
    """단위 el 을 그 서식으로 그리는 hp:run. 부모가 run 이면 부모, 부모가 ctrl 이고 그 부모가 run 이면 그 run,
    아니면 None."""
    parent = el.getparent()
    if parent is None: return None
    if parent.tag == HP + "run": return parent
    if parent.tag == HP + "ctrl":
        run = parent.getparent()
        if run is not None and run.tag == HP + "run": return run
    return None

def run_units(run) -> list:
    """run 의 '단위' 목록을 문서 순서로: run 직접 자식 중 hp:ctrl 이 아닌 것과 직접 자식 hp:ctrl 의 자식
    요소 하나하나. hp:ctrl 자체는 단위가 아니다(자식 없는 빈 ctrl 은 아무것도 그리지 않는다)."""
    units = []
    for child in run:
        if not isinstance(child.tag, str): continue
        if child.tag == HP + "ctrl": units.extend(c for c in child if isinstance(c.tag, str))
        else: units.append(child)
    return units

def is_unit(el) -> bool:
    """el 이 '단위'인지: hp:run 의 직접 자식 중 hp:ctrl 이 아닌 것, 또는 그런 hp:ctrl 의 자식 요소.
    hp:ctrl 자체와 주석 따위 요소가 아닌 노드는 단위가 아니다."""
    if not isinstance(el.tag, str) or el.tag == HP + "ctrl": return False
    parent = el.getparent()
    if parent is None: return False
    if parent.tag == HP + "run": return True
    return (parent.tag == HP + "ctrl" and parent.getparent() is not None
            and parent.getparent().tag == HP + "run")

def unit_visible(el) -> bool:
    """단위가 화면에 그려지는지. ctrl 자식은 허용 목록(CTRL_BLANK_NAMES) 밖이면 보임(자동 번호·쪽 번호·
    각주·모르는 것), hp:t 면 t_visible, 그 밖의 run 직접 자식(덧말·표·모르는 것)은 보임."""
    if not is_unit(el): return False
    parent = el.getparent()
    if parent.tag == HP + "ctrl": return local_name(el) not in CTRL_BLANK_NAMES
    if local_name(el) == "t": return t_visible(el)
    return True

def unit_of_para(el, para):
    """el 이 이 문단(para) 의 run 에 속한 단위인지 보고 그 run 을 돌려준다. 표 칸·숨은 설명·글상자 안
    중첩 문단의 단위는 그 문단 차례에 따로 본다(style_failures 가 문단마다 부른다)."""
    if not is_unit(el): return None
    run = unit_run(el)
    return run if run is not None and run.getparent() is para else None

def other_begin_in_run(begin, run, form: set) -> bool:
    """run 의 직접 자식 hp:ctrl 안에 begin 아닌 누름틀의 fieldBegin 이 있는지."""
    return any(el.tag == HP + "fieldBegin" and el is not begin and el in form
               for ctrl in run if ctrl.tag == HP + "ctrl" for el in ctrl)

def style_reason(begin, start_run, inside: list, form: set) -> str | None:
    """한 문단 누름틀의 정적 규칙: (1) 구간 안 단위 중 글자(hp:t) 아닌 보이는 것이 있으면 값이 기존
    내용 옆에 붙으므로 거부(서식이 같아도), (2) 값이 들어갈 첫 hp:t(primary)의 run 이 시작 run 이
    아닌데 서식이 다르고 그 run 에 구간 밖 '보이는 단위'나 다른 누름틀의 시작 표시가 있으면 라이브러리
    채우기가 그것까지 바꾼다. 구간 안 hp:t 가 없으면 라이브러리가 시작 run 에 새 hp:t 를 넣으므로
    서식이 바뀌지 않는다."""
    if not inside: return None
    if any(local_name(el) != "t" and unit_visible(el) for el in inside): return INSIDE_NONTEXT_FAIL
    primary = next((unit_run(t) for t in inside if t.tag == HP + "t"), None)
    if primary is None or primary is start_run: return None
    start_pr = start_run.get("charPrIDRef")
    if start_pr is None or start_pr == primary.get("charPrIDRef"): return None
    keep = {id(el) for el in inside}
    if any(unit_visible(el) for el in run_units(primary) if id(el) not in keep): return STYLE_FAIL
    return STYLE_FAIL if other_begin_in_run(begin, primary, form) else None

def para_style_failures(para, wanted: set, form: set) -> dict:
    """문단 하나를 한 번 훑아, wanted 의 fieldBegin 각각에서 구간 안(시작 표시 뒤·끝 표시 앞) 단위
    목록을 만들어 style_reason 조건에 걸리는 것만 요소 → 사유로 돌려준다. 단위·시작 표시 모두 이
    문단의 run 것만 넣는다(표 칸·숨은 설명 안 중첩 문단은 그 문단 차례에 따로 온다)."""
    pending: dict = {}
    out: dict = {}
    for el in para.iter():
        if el.tag == HP + "fieldBegin":
            run = mark_run(el) if el in wanted and el.get("id") is not None else None
            if run is not None and run.getparent() is para:
                pending.setdefault(el.get("id"), []).append((el, run, []))
        elif el.tag == HP + "fieldEnd" and el.get("beginIDRef") in pending:
            for begin, run, inside in pending.pop(el.get("beginIDRef")):
                if (why := style_reason(begin, run, inside, form)): out[begin] = why
        elif unit_of_para(el, para) is not None:
            for inside in (rec[2] for recs in pending.values() for rec in recs): inside.append(el)
    return out

def style_failures(doc, fields) -> dict:
    """끝 있는 누름틀 전부(시범 채우기 후보만이 아님)에 정적 서식 규칙을 적용해
    fieldBegin 요소 → STYLE_FAIL. 누름틀 시작이 든 문단을 문단마다 한 번만 훑는다.
    '보호할 다른 누름틀'(form)은 끝 있는 누름틀만 넣는다(끝 없는 누름틀은 어차피 채울 수 없다)."""
    wanted = {f.element for f in fields if getattr(f, "has_end", True)}
    form = wanted
    paras = []
    for begin in wanted:
        run = mark_run(begin)
        para = run.getparent() if run is not None else None
        if para is not None and para not in paras: paras.append(para)
    out: dict = {}
    for para in paras: out.update(para_style_failures(para, wanted, form))
    return out

def current_field_index(doc, element) -> int | None:
    """채우는 순간의 누름틀 위치 번호(채우기가 안쪽 누름틀을 지우면 당겨진다)."""
    fields = list(doc.fields.all)
    return next((i for i, f in enumerate(fields) if f.element is element), None)

def is_attached(doc, element) -> bool:
    """요소가 아직 문서에 붙어 있는지: 맨 위 조상이 어느 section 요소와 같은지."""
    top = element
    while top.getparent() is not None: top = top.getparent()
    return any(top is section.element for section in doc.sections)

def missing_after_fill(doc, elements: dict, failed: set) -> list[tuple[str, str]]:
    """채운 뒤 기억한 요소(누름틀·표) 가 떨어져 나갔는지 본다. 안쪽을 먼저 채우면 바깥 누름틀이 접혀 함께 담긴 값이 지워지므로 그 키를 실패로 돌려준다."""
    return [(key, NESTED_FIELD_FAIL) for key, element in elements.items()
            if key not in failed and not is_attached(doc, element)]

def field_value(field) -> str:
    """누름틀 값의 비교용 문자열."""
    return str(getattr(field, "value", "") or "")

def orphan_end_ids(doc) -> set:
    """고아 끝 표시 집합: 짝 fieldBegin id 가 없는 fieldEnd 의 beginIDRef(None 제외)."""
    begins = {el.get("id") for s in doc.sections for el in s.element.iter(HP + "fieldBegin")}
    return {el.get("beginIDRef") for s in doc.sections for el in s.element.iter(HP + "fieldEnd")
            if el.get("beginIDRef") and el.get("beginIDRef") not in begins}

def mark_walk(doc) -> tuple:
    """모든 섹션을 표시(fieldBegin·fieldEnd)·hp:t 문서 순서로 한 번 훑어
    (표시 요소 → 번호, (hp:t, 그 앞까지 나온 표시 개수) 목록) 을 만든다. 번호 매김은 field_positions 와 같다."""
    marks: dict = {}
    ts: list = []
    for section in doc.sections:
        for el in section.element.iter(HP + "fieldBegin", HP + "fieldEnd", HP + "t"):
            if el.tag == HP + "t": ts.append((el, len(marks)))
            else: marks[el] = len(marks)
    return marks, ts

def spans_overlap(pb, pe, tb, te) -> bool:
    """비누름틀 짝 (pb, pe) 과 누름틀 짝 (tb, te) 이 겹치는지. 끝 번호가 없는 짝은 겹치지 않는 것으로 본다."""
    if pe is None or tb is None or te is None: return False
    return pb < tb < pe or pb < te < pe or tb < pb < te or tb < pe < te

def pair_content(span: tuple, ts: list, inner: list) -> tuple:
    """짝 (b, e) 구간 안 hp:t 들의 (text, 자식 (tag, tail) 목록) 값을 문서 순서로.
    inner 중 이 구간에 통째로 든 누름틀 짝 (fb, fe) 의 구간 안 hp:t 는 뺀다(채우기가 값을 넣어도 정상)."""
    b, e = span
    if e is None: return ()
    hide = [(fb, fe) for fb, fe in inner if b < fb and fe < e]
    return tuple((t.text or "", tuple((c.tag, c.tail or "") for c in t))
                 for t, p in ts if b < p <= e and not any(fb < p <= fe for fb, fe in hide))

def form_pairs(pos: dict, form: set) -> list:
    """짝 표에서 누름틀 fieldBegin 의 (시작 번호, 끝 번호) 목록(끝 있는 짝만)."""
    return [pair for begin, pair in pos.items() if begin in form and pair[1] is not None]

def nonform_snapshot(doc, targets: set) -> dict:
    """채우기 전 스냅숏: 비누름틀(하이퍼링크 등) fieldBegin 요소 → (끝 요소 또는 None, 구간 안 hp:t
    내용 또는 None, targets 짝 안에 통째로 드는지). 내용은 targets 의 누름틀 짝과 겹치는 짝만 기억하고
    문서 순서(시작 번호 오름차순)로 넣는다. 같은 id 의 비누름틀이 여럿이어도 요소별로 따로 본다."""
    pos = field_positions(doc)
    form = {f.element for f in field_entries(doc)}
    marks, ts = mark_walk(doc)
    by_no = {no: el for el, no in marks.items()}
    tgt = [pair for pair in (pos.get(t) for t in targets) if pair and pair[1] is not None]
    inner = form_pairs(pos, form)
    snap: dict = {}
    for begin, (b, e) in sorted(pos.items(), key=lambda kv: kv[1][0]):
        if begin in form: continue
        content, inside = None, False
        if any(spans_overlap(b, e, tb, te) for tb, te in tgt):
            content = pair_content((b, e), ts, inner)
            inside = any(tb < b and e is not None and e < te for tb, te in tgt)
        snap[begin] = (by_no.get(e), content, inside)
    return snap

def nonform_reason(doc, snap: dict) -> str | None:
    """채운 뒤 문서를 채우기 전 스냅숏과 비교해 하이퍼링크 등 다른 필드가 망가졌으면 사유.
    짝마다(채우기 전 문서 순서) 시작·끝이 모두 떨어져 나가면 품고 있음, 하나만 떨어지거나 짝이
    바뀌면 겹침, 겹치는 짝의 구간 안 hp:t 내용이 바뀌면 통째로 들어간 짝은 품고 있음, 아니면 겹침."""
    pos = field_positions(doc)
    form = {f.element for f in field_entries(doc)}
    marks, ts = mark_walk(doc)
    by_no = {no: el for el, no in marks.items()}
    inner = form_pairs(pos, form)
    for begin, (end_el, content, inside) in snap.items():
        here = is_attached(doc, begin)
        live_end = None if end_el is None else is_attached(doc, end_el)
        if not here and live_end is not True: return NONFORM_NEST
        if not here or live_end is False: return NONFORM_CROSS
        now = pos.get(begin)
        if end_el is not None and (now is None or now[1] is None or by_no.get(now[1]) is not end_el):
            return NONFORM_CROSS
        if content is not None and now is not None and pair_content(now, ts, inner) != content:
            return NONFORM_NEST if inside else NONFORM_CROSS
    return None

def field_snapshot(doc, values: dict, fields_by_key: dict) -> tuple:
    """채우기 전 스냅숏: 누름틀 (요소, 이름, 값, 끝 없음) 목록(끝 없는 누름틀도 기록), 고아 끝 표시 집합, 요청 누름틀 요소 → 키."""
    tracked = [(f.element, str(getattr(f, "name", "") or ""), field_value(f), not getattr(f, "has_end", True))
               for f in field_entries(doc)]
    expected = {entries[0][1].element: key for key in values if (entries := fields_by_key.get(label_key(key_body(key))))}
    return tracked, orphan_end_ids(doc), expected

def field_damage(doc, tracked: list, orphans: set, expected: dict, filled_values: dict) -> list:
    """모두 채운 뒤 누름틀을 새로 읽어 스냅숏과 비교해 (fieldBegin 요소, 이름, 사유) 목록을 돌려준다.
    끝 없던 누름틀은 시작 표시가 사라졌을 때만 보고, 끝 있던 누름틀은 고아 끝 표시 생김·사라짐·끝 표시 상실·값 훼손 순으로 본다."""
    live = {f.element: f for f in field_entries(doc)}
    new_orphans = orphan_end_ids(doc) - orphans
    out = []
    for element, name, value, unended in tracked:
        if unended: reason = NESTED_FIELD_FAIL if element not in live else ""
        else:
            reason = (CROSSED_FIELD_FAIL if element.get("id") in new_orphans else
                      NESTED_FIELD_FAIL if element not in live else
                      CROSSED_FIELD_FAIL if not getattr(live[element], "has_end", True) or
                      (element in filled_values and field_value(live[element]) != filled_values[element]) or
                      (element not in filled_values and field_value(live[element]) != value) else "")
        if reason: out.append((element, name, reason))
    return out

def outside_text_styles(doc, expected: dict) -> dict:
    """채우기 전 기억(채운 뒤 규칙용): 요청 누름틀(expected 의 키 = fieldBegin 요소)이 하나도
    열려 있지 않을 때 '보이는 단위'(unit_visible) → 그 run(unit_run)의 charPrIDRef, 그리고 끝 있는
    누름틀 fieldBegin → 그 run(mark_run)의 charPrIDRef. 요청 누름틀 시작 id 를 열림에 두고
    같은 id 끝을 만나면 뺀다."""
    out: dict = {}
    opens: set = set()
    form = {f.element for f in field_entries(doc) if getattr(f, "has_end", True)}
    for section in doc.sections:
        for el in section.element.iter():
            if el.tag == HP + "fieldBegin":
                if el in expected: opens.add(el.get("id"))
                if el in form:
                    run = mark_run(el)
                    if run is not None: out[el] = run.get("charPrIDRef")
            elif el.tag == HP + "fieldEnd": opens.discard(el.get("beginIDRef"))
            elif not opens and unit_visible(el):
                run = unit_run(el)
                if run is not None: out[el] = run.get("charPrIDRef")
    return out

def style_damage(doc, before: dict) -> bool:
    """채운 뒤 비교: 기억한 구간 밖 '보이는 단위'·누름틀 fieldBegin 중 아직 문서에 붙어 있는 것의
    run 서식(charPrIDRef)이 바뀌었으면 손상. 채우기가 떼어 낸 요소는 이 검사에서 보지 않는다.
    ctrl 자식 단위도 unit_run 으로 run 을 찾는다(부모가 ctrl 이라 건너뛰지 않게)."""
    for el, char_pr in before.items():
        run = mark_run(el) if el.tag == HP + "fieldBegin" else unit_run(el)
        if run is not None and is_attached(doc, el) and run.get("charPrIDRef") != char_pr:
            return True
    return False
