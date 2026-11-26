#!/bin/bash
# docx skill 인수 시험. 사용: CLAUDE_LMS_PY=<python> tests/accept_docx.sh
# 모든 시험이 통과하면 "ACCEPT PASS" 를 출력하고 0 으로 끝난다.
NAME=docx; EXT=docx
. "$(dirname "$0")/lib_office_accept.sh"

cat > "$T/in.md" <<'MD'
# 주간 보고

## 1. 추진 실적

문서 작업 **자동화** 완료

- 첫 항목
  - 하위 항목
    - 셋째 단계
1. 번호 하나
2. 번호 둘
  1. 하위 번호

### 세부 내역

| 항목 | 값 |
| --- | --- |
| 예산 | 1,000 |
MD
common_cases "$T/in.md" "주간 보고" "자동화" "하위 항목" "예산" "1,000"

# D1. 문단 스타일: # ~ ### → Heading 1~3, 본문 → Normal, - → List Bullet(2,3), 1. → List Number(2)
"$PY" -I -W ignore - "$T/out.docx" > "$T/d1.txt" 2>&1 <<'EOF'
import sys, docx
for p in docx.Document(sys.argv[1]).paragraphs:
    if p.text.strip():
        print(f"{p.style.name}|{p.text}")
EOF
cat > "$T/d1.want" <<'W'
Heading 1|주간 보고
Heading 2|1. 추진 실적
Normal|문서 작업 자동화 완료
List Bullet|첫 항목
List Bullet 2|하위 항목
List Bullet 3|셋째 단계
List Number|번호 하나
List Number|번호 둘
List Number 2|하위 번호
Heading 3|세부 내역
W
diff -q "$T/d1.want" "$T/d1.txt" > /dev/null && pass paragraph-styles || bad paragraph-styles "$(diff "$T/d1.want" "$T/d1.txt" | grep '^[<>]' | head -4 | tr '\n' '/')"

# D2. 굵게: **자동화** 만 굵은 run, 공백에 붙은 ** 는 글자 그대로(거듭제곱), 짝 없는 ** 도 글자 그대로
printf '문서 작업 **자동화** 완료\n\n2 ** 3 = 8\n\n끝 **열림\n' > "$T/bold.md"
"$W" from-md "$T/bold.md" "$T/bold.docx" > /dev/null 2>&1
"$PY" -I -W ignore - "$T/bold.docx" > "$T/d2.txt" 2>&1 <<'EOF'
import sys, docx
for p in docx.Document(sys.argv[1]).paragraphs:
    for r in p.runs:
        if r.text:
            print(f"{'B' if r.bold else 'N'}|{r.text}")
EOF
grep -qx 'B|자동화' "$T/d2.txt" && ! grep -q '^B|문서' "$T/d2.txt" && grep -qx 'N|2 \*\* 3 = 8' "$T/d2.txt" && grep -qx 'N|끝 \*\*열림' "$T/d2.txt" && pass bold-runs || bad bold-runs "$(tr '\n' '/' < "$T/d2.txt")"

# D3. 한글 글꼴: Normal·Heading 1 스타일의 w:eastAsia = 맑은 고딕, 테마 글꼴(eastAsiaTheme)이 덮어쓰지 않는다
"$PY" -I -W ignore - "$T/out.docx" > "$T/d3.txt" 2>&1 <<'EOF'
import sys, docx
from docx.oxml.ns import qn
d = docx.Document(sys.argv[1])
for name in ("Normal", "Heading 1"):
    rpr = d.styles[name].element.rPr
    f = rpr.find(qn("w:rFonts")) if rpr is not None else None
    ea = f.get(qn("w:eastAsia")) if f is not None else None
    theme = f.get(qn("w:eastAsiaTheme")) if f is not None else None
    print(f"{name}|{ea}|{theme}")
EOF
[ "$(cat "$T/d3.txt")" = "Normal|맑은 고딕|None
Heading 1|맑은 고딕|None" ] && pass east-asia-font || bad east-asia-font "$(tr '\n' '/' < "$T/d3.txt")"

# D4. 표: 셀 안 굵게, 빈 데이터 행 유지, \| 는 글자, 구분선처럼 생긴 데이터 행 유지, 머리 행 굵게
cat > "$T/tbl.md" <<'MD'
| 항목 | 값 |
| --- | --- |
| **굵은항목** | 1 |
|  |  |
| a \| b | 2 |
| --- | --- |
MD
"$W" from-md "$T/tbl.md" "$T/tbl.docx" > "$T/d4.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/tbl.docx" > "$T/d4b.txt" 2>&1 <<'EOF'
import sys, docx
t = docx.Document(sys.argv[1]).tables[0]
print(len(t.rows), len(t.columns))
print("/".join(r.cells[0].text for r in t.rows))
b = lambda c: all(r.bold for p in c.paragraphs for r in p.runs if r.text)
print(b(t.rows[0].cells[0]), b(t.rows[1].cells[0]), b(t.rows[1].cells[1]))
EOF
[ $rc -eq 0 ] && [ "$(cat "$T/d4b.txt")" = "5 2
항목/굵은항목//a | b/---
True True False" ] && pass table-structure || bad table-structure "rc=$rc $(tr '\n' '/' < "$T/d4b.txt")"
"$W" read "$T/tbl.docx" > "$T/d4r.txt" 2>&1
grep -qxF '| 항목 | 값 |' "$T/d4r.txt" && grep -qxF '| --- | --- |' "$T/d4r.txt" && grep -qF '| a \| b | 2 |' "$T/d4r.txt" && pass table-read || bad table-read "$(sed -n '2,8p' "$T/d4r.txt" | tr '\n' '/')"

# D5. 머리 행 + 구분선이 없는 '|' 줄은 표가 아니라 문단(글자 그대로)
printf '| 참고: 내용\n\n머리 문단\n| --- | --- |\n' > "$T/pipe.md"
"$W" from-md "$T/pipe.md" "$T/pipe.docx" > "$T/d5.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/pipe.docx" > "$T/d5b.txt" 2>&1 <<'EOF'
import sys, docx
d = docx.Document(sys.argv[1])
texts = [p.text for p in d.paragraphs]
print(len(d.tables), "| 참고: 내용" in texts, any("---" in t for t in texts))
EOF
[ $rc -eq 0 ] && [ "$(cat "$T/d5b.txt")" = "0 True True" ] && pass pipe-line-not-table || bad pipe-line-not-table "rc=$rc $(cat "$T/d5b.txt")"

# D6. read 형식: 제목은 '#', 목록은 '- '/'  - ', 번호는 1. 2. 순서, 굵게는 **, HTML 엔티티 없음
printf '# 연구 & 개발\n\nA & B 그리고 <x> **굵게**\n' > "$T/amp.md"
"$W" from-md "$T/amp.md" "$T/amp.docx" > /dev/null 2>&1
"$W" read "$T/amp.docx" > "$T/d6a.txt" 2>&1
grep -qx '# 연구 & 개발' "$T/d6a.txt" && grep -qx 'A & B 그리고 <x> \*\*굵게\*\*' "$T/d6a.txt" && ! grep -q '&amp;\|&lt;' "$T/d6a.txt" && pass read-no-html-entities || bad read-no-html-entities "$(sed -n '2,6p' "$T/d6a.txt" | tr '\n' '/')"
r="$T/c1r.txt"
grep -qx '## 1\. 추진 실적' "$r" && grep -qx '### 세부 내역' "$r" && grep -qx -- '- 첫 항목' "$r" && grep -qx -- '  - 하위 항목' "$r" \
  && grep -qx -- '    - 셋째 단계' "$r" && grep -qx '1\. 번호 하나' "$r" && grep -qx '2\. 번호 둘' "$r" && grep -qx '  1\. 하위 번호' "$r" \
  && grep -qx '문서 작업 \*\*자동화\*\* 완료' "$r" && pass read-markdown-shape || bad read-markdown-shape "$(sed -n '2,14p' "$r" | tr '\n' '/')"

# D7. 왕복: read 결과(OK 줄 제외)로 다시 만든 문서는 문단 스타일·글자·표가 같다
tail -n +2 "$T/c1r.txt" > "$T/rt.md"
"$W" from-md "$T/rt.md" "$T/rt.docx" > "$T/d7.txt" 2>&1; rc=$?
dump() { "$PY" -I -W ignore - "$1" <<'EOF'
import sys, docx
d = docx.Document(sys.argv[1])
for p in d.paragraphs:
    if p.text.strip():
        print(p.style.name, "|", p.text, "|", [r.text for r in p.runs if r.bold])
for t in d.tables:
    print([[c.text for c in r.cells] for r in t.rows])
EOF
}
[ $rc -eq 0 ] && [ "$(dump "$T/out.docx")" = "$(dump "$T/rt.docx")" ] && pass roundtrip || bad roundtrip "rc=$rc $(diff <(dump "$T/out.docx") <(dump "$T/rt.docx") | head -4 | tr '\n' '/')"

# D8. Word 로 만든 듯한 외부 문서(사용자 정의 스타일·제목 없는 표·빈 문단)도 내부 오류 없이 읽는다
"$PY" -I -W ignore - "$T/ext.docx" <<'EOF'
import sys, docx
from docx.enum.style import WD_STYLE_TYPE
d = docx.Document()
d.styles.add_style("내 스타일", WD_STYLE_TYPE.PARAGRAPH)
d.add_paragraph("사용자 스타일 문단", style="내 스타일")
d.add_paragraph("")
t = d.add_table(rows=1, cols=1); t.cell(0, 0).text = "단일 칸"
d.add_heading("제목 0", 0)
d.save(sys.argv[1])
EOF
"$W" read "$T/ext.docx" > "$T/d8.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '사용자 스타일 문단' "$T/d8.txt" && grep -q '단일 칸' "$T/d8.txt" && grep -q '제목 0' "$T/d8.txt" && pass read-foreign-docx || bad read-foreign-docx "rc=$rc $(first "$T/d8.txt")"

# D9. 너무 넓거나 큰 표: Word 한계 63열 초과, 칸 합계 10만 초과면 만들기 전에 한 줄 ERROR, 출력 없음(빨리 끝남)
for spec in "wide 20000 1" "w64 64 1" "many 300 400"; do
  set -- $spec
  wide_table_md "$T/$1.md" "$2" "$3"
  limited 60 "$W" from-md "$T/$1.md" "$T/$1.docx" > "$T/d9-$1.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ $rc -ne 142 ] && [ "$(lines "$T/d9-$1.txt")" = "1" ] && grep -q '^ERROR ' "$T/d9-$1.txt" && [ ! -e "$T/$1.docx" ] && pass "table-too-big-$1" || bad "table-too-big-$1" "rc=$rc $(first "$T/d9-$1.txt")"
done
wide_table_md "$T/w63.md" 63 2
"$W" from-md "$T/w63.md" "$T/w63.docx" > "$T/d9b.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && pass table-63-columns-ok || bad table-63-columns-ok "rc=$rc $(first "$T/d9b.txt")"

# D10. 병합 칸: 가로·세로로 합친 칸의 글은 한 번만 보이고, 세로 병합이 머리 행에서 데이터 행으로 이어져도 ** 가 붙지 않는다
"$PY" -I -W ignore - "$T/merged.docx" <<'EOF'
import sys, docx
d = docx.Document(); t = d.add_table(rows=3, cols=3)
a = t.cell(0, 0).merge(t.cell(0, 2)); a.text = "가로병합"
for c, s in ((1, "나"), (2, "다")): t.cell(1, c).text = s
b = t.cell(1, 0).merge(t.cell(2, 0)); b.text = "세로병합"
for c, s in ((1, "라"), (2, "마")): t.cell(2, c).text = s
t2 = d.add_table(rows=2, cols=2)
h = t2.cell(0, 0).merge(t2.cell(1, 0)); h.text = "머리세로"
t2.cell(0, 1).text = "값"; t2.cell(1, 1).text = "1"
d.save(sys.argv[1])
EOF
"$W" read "$T/merged.docx" > "$T/d10.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(grep -o '가로병합' "$T/d10.txt" | wc -l | tr -d ' ')" = "1" ] && [ "$(grep -o '세로병합' "$T/d10.txt" | wc -l | tr -d ' ')" = "1" ] \
  && [ "$(grep -o '머리세로' "$T/d10.txt" | wc -l | tr -d ' ')" = "1" ] && ! grep -q '\*\*머리세로' "$T/d10.txt" && pass read-merged-cells || bad read-merged-cells "rc=$rc $(tail -n +2 "$T/d10.txt" | tr '\n' '/')"

# D11. UTF-8 BOM 으로 시작하는 md: 첫 줄 # 제목이 Heading 1 로 들어간다
printf '\xef\xbb\xbf# 표지 제목\n본문\n' > "$T/bom.md"
"$W" from-md "$T/bom.md" "$T/bom.docx" > "$T/d11.txt" 2>&1
"$PY" -I -W ignore -c 'import sys, docx; p = docx.Document(sys.argv[1]).paragraphs[0]; print(p.style.name, p.text)' "$T/bom.docx" > "$T/d11b.txt" 2>&1
[ "$(cat "$T/d11b.txt")" = "Heading 1 표지 제목" ] && pass utf8-bom || bad utf8-bom "$(first "$T/d11.txt") $(cat "$T/d11b.txt")"

# D12. 번호 목록: 새 1단계 번호마다 하위 번호는 1 부터, 표를 지나면 번호도 1 부터 다시
printf '1. 첫째\n  1. 하위A\n2. 둘째\n  1. 하위B\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n1. 표뒤\n' > "$T/num.md"
"$W" from-md "$T/num.md" "$T/num.docx" > /dev/null 2>&1
"$W" read "$T/num.docx" > "$T/d12.txt" 2>&1
grep -qxF '  1. 하위B' "$T/d12.txt" && grep -qxF '1. 표뒤' "$T/d12.txt" && pass numbered-list-reset || bad numbered-list-reset "$(tail -n +2 "$T/d12.txt" | tr '\n' '/')"

# D13. 표 칸 안 여러 문단·줄바꿈(<w:br/>)은 한 줄로 펴서 표가 깨지지 않는다
"$PY" -I -W ignore - "$T/cellnl.docx" <<'EOF'
import sys, docx
from docx.enum.text import WD_BREAK
d = docx.Document(); t = d.add_table(rows=3, cols=2)
t.cell(0, 0).text = "항목"; t.cell(0, 1).text = "비고"
t.cell(1, 0).text = "인건비"; c = t.cell(1, 1); c.text = "1차"; c.add_paragraph("2차")
t.cell(2, 0).text = "운영비"; r = t.cell(2, 1).paragraphs[0].add_run("가"); r.add_break(WD_BREAK.LINE); t.cell(2, 1).paragraphs[0].add_run("나")
d.save(sys.argv[1])
EOF
"$W" read "$T/cellnl.docx" > "$T/d13.txt" 2>&1
grep -qxF '| 인건비 | 1차 2차 |' "$T/d13.txt" && grep -qxF '| 운영비 | 가 나 |' "$T/d13.txt" && pass multiline-cell || bad multiline-cell "$(tail -n +2 "$T/d13.txt" | tr '\n' '/')"

# D14. 하이퍼링크 안 글, 콘텐츠 컨트롤(<w:sdt>) 안 문단도 read 에 보인다
"$PY" -I -W ignore - "$T/link.docx" <<'EOF'
import sys, docx
from docx.oxml import parse_xml
W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
d = docx.Document()
p = d.add_paragraph("앞글 ")
p._p.append(parse_xml(f'<w:hyperlink {W} w:anchor="x"><w:r><w:t>링크글</w:t></w:r></w:hyperlink>'))
d.add_paragraph("가운데")
d.element.body.insert(len(d.element.body) - 1, parse_xml(
    f'<w:sdt {W}><w:sdtPr/><w:sdtContent><w:p><w:r><w:t>컨트롤글</w:t></w:r></w:p></w:sdtContent></w:sdt>'))
d.save(sys.argv[1])
EOF
"$W" read "$T/link.docx" > "$T/d14.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -qF '앞글 링크글' "$T/d14.txt" && grep -qF '컨트롤글' "$T/d14.txt" && pass read-hyperlink-sdt || bad read-hyperlink-sdt "rc=$rc $(tail -n +2 "$T/d14.txt" | tr '\n' '/')"

# D15. 굵은 run 앞뒤 공백은 ** 밖으로: **자동화 ** 가 아니라 **자동화** (그래야 다시 넣을 때 ** 가 남지 않는다)
"$PY" -I -W ignore - "$T/bsp.docx" <<'EOF'
import sys, docx
d = docx.Document(); p = d.add_paragraph()
p.add_run("앞 "); p.add_run(" 자동화 ").bold = True; p.add_run("뒤")
d.save(sys.argv[1])
EOF
"$W" read "$T/bsp.docx" > "$T/d15.txt" 2>&1
grep -qF '**자동화** 뒤' "$T/d15.txt" && ! grep -qF '** 자동화' "$T/d15.txt" && ! grep -qF '자동화 **' "$T/d15.txt" && pass bold-run-spaces || bad bold-run-spaces "$(tail -n +2 "$T/d15.txt" | tr '\n' '/')"

# D16. 병합 표시는 w:tcPr 안(gridSpan·vMerge)에 있다: A:B 를 합친 행의 C 글은 C 열에 남고,
#      세로 병합 이어짐 칸에 남은 글(Word 는 보이지 않는다)은 읽지 않는다
"$PY" -I -W ignore - "$T/merged2.docx" <<'EOF'
import sys, docx
from docx.oxml.ns import qn
from docx.oxml import OxmlElement
d = docx.Document(); t = d.add_table(rows=3, cols=3)
t.cell(0, 0).merge(t.cell(0, 1)).text = "병합"; t.cell(0, 2).text = "셋째"
t.cell(1, 0).merge(t.cell(2, 0)).text = "세로"
for r, c, s in ((1, 1, "가"), (1, 2, "나"), (2, 1, "다"), (2, 2, "라")): t.cell(r, c).text = s
cont = t._tbl.tr_lst[2].tc_lst[0]
assert cont.find(qn("w:tcPr")).find(qn("w:vMerge")) is not None
p = OxmlElement("w:p"); r = OxmlElement("w:r"); x = OxmlElement("w:t"); x.text = "잔여"
r.append(x); p.append(r); cont.append(p)
d.save(sys.argv[1])
EOF
"$W" read "$T/merged2.docx" > "$T/d16.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -qxF '| 병합 |  | 셋째 |' "$T/d16.txt" && grep -qxF '|  | 다 | 라 |' "$T/d16.txt" && ! grep -q '잔여' "$T/d16.txt" \
  && pass read-merged-tcpr || bad read-merged-tcpr "rc=$rc $(tail -n +2 "$T/d16.txt" | tr '\n' '/')"

# D17. 터무니없이 큰 gridSpan(가로 병합) 값은 표 열 수 안에서만 센다: 메모리 폭주 없이 빨리 읽고 열 수 유지
"$PY" -I -W ignore - "$T/hugespan.docx" <<'EOF'
import sys, docx
from docx.oxml.ns import qn
from docx.oxml import OxmlElement
d = docx.Document(); t = d.add_table(rows=2, cols=2)
t.cell(0, 0).text = "가"; t.cell(0, 1).text = "나"; t.cell(1, 0).text = "큰병합"; t.cell(1, 1).text = "다"
for tc, val in ((t._tbl.tr_lst[1].tc_lst[0], "9223372036854775808"), (t._tbl.tr_lst[1].tc_lst[1], "2000000000")):
    tcpr = tc.get_or_add_tcPr(); gs = OxmlElement("w:gridSpan"); gs.set(qn("w:val"), val); tcpr.append(gs)
vm = OxmlElement("w:vMerge"); vm.set(qn("w:val"), "continue")
t._tbl.tr_lst[1].tc_lst[1].get_or_add_tcPr().append(vm)
d.save(sys.argv[1])
EOF
limited 20 "$W" read "$T/hugespan.docx" > "$T/d17.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -qxF '| 큰병합 |  |' "$T/d17.txt" && ! grep -q '내부 오류' "$T/d17.txt" \
  && pass read-huge-gridspan || bad read-huge-gridspan "rc=$rc $(tail -n +2 "$T/d17.txt" | tr '\n' '/')"

# ── 혼합안(anthropics/skills 지침 반영) ─────────────────────────────────────────
cat > "$T/hy.md" <<'MD'
# 주간 보고
## 실적
* 별표 항목
  * 별표 둘째 단계
• 가운뎃점 항목
**굵게** 시작하는 본문
| 구분 | 계획 | 실적 |
| --- | --- | --- |
| 가 | 1 | 2 |
| 나 | 3 | 4 |
MD
"$W" from-md "$T/hy.md" "$T/hy.docx" > "$T/hyo.txt" 2>&1; hyrc=$?

# D18. 쪽은 A4(11906×16838 DXA), 여백은 사방 1440(1인치). 한국 문서 기본은 Letter 가 아니다
"$PY" -I -W ignore - "$T/hy.docx" > "$T/d18.txt" 2>&1 <<'EOF'
import sys, docx
from docx.oxml.ns import qn
sp = docx.Document(sys.argv[1]).sections[0]._sectPr
sz, mg = sp.find(qn("w:pgSz")), sp.find(qn("w:pgMar"))
print(sz.get(qn("w:w")), sz.get(qn("w:h")), *(mg.get(qn("w:" + k)) for k in ("top", "right", "bottom", "left")))
EOF
[ $hyrc -eq 0 ] && [ "$(cat "$T/d18.txt")" = "11906 16838 1440 1440 1440 1440" ] && pass page-a4 || bad page-a4 "rc=$hyrc $(cat "$T/d18.txt")"

# D19. 표 폭: tblW 는 DXA 9026(A4 본문 폭), 열 폭(gridCol)과 행마다 칸 폭(tcW, DXA) 합도 9026
#      (나누어 떨어지지 않으면 마지막 열이 나머지를 가진다). type=auto/pct 는 Google 문서 등에서 깨진다
"$PY" -I -W ignore - "$T/hy.docx" > "$T/d19.txt" 2>&1 <<'EOF'
import sys, docx
from docx.oxml.ns import qn
tbl = docx.Document(sys.argv[1]).tables[0]._tbl
tw = tbl.tblPr.find(qn("w:tblW"))
grid = [int(g.get(qn("w:w"))) for g in tbl.tblGrid.findall(qn("w:gridCol"))]
rows = []
for tr in tbl.tr_lst:
    ws = [tc.tcPr.find(qn("w:tcW")) for tc in tr.tc_lst]
    rows.append((sum(int(w.get(qn("w:w"))) for w in ws), ",".join(sorted({w.get(qn("w:type")) for w in ws}))))
print(tw.get(qn("w:type")), tw.get(qn("w:w")), sum(grid), grid[-1] >= grid[0], sorted(set(rows), key=str))
EOF
[ "$(cat "$T/d19.txt")" = "dxa 9026 9026 True [(9026, 'dxa')]" ] && pass table-width-dxa || bad table-width-dxa "$(cat "$T/d19.txt")"

# D20. 머리 행: 쪽이 넘어가면 반복(w:tblHeader), 머리 칸만 옅은 회색 음영(clear, D9D9D9). 자료 칸은 음영 없음
"$PY" -I -W ignore - "$T/hy.docx" > "$T/d20.txt" 2>&1 <<'EOF'
import sys, docx
from docx.oxml.ns import qn
tbl = docx.Document(sys.argv[1]).tables[0]._tbl
def shd(tc):
    s = tc.tcPr.find(qn("w:shd")) if tc.tcPr is not None else None
    return None if s is None else (s.get(qn("w:val")), s.get(qn("w:fill")))
hdr = tbl.tr_lst[0]
rep = hdr.trPr is not None and hdr.trPr.find(qn("w:tblHeader")) is not None
print(rep, sorted({shd(tc) for tc in hdr.tc_lst}, key=str), sorted({shd(tc) for tr in tbl.tr_lst[1:] for tc in tr.tc_lst}, key=str))
EOF
[ "$(cat "$T/d20.txt")" = "True [('clear', 'D9D9D9')] [None]" ] && pass table-header-row || bad table-header-row "$(cat "$T/d20.txt")"

# D21. 모델이 자주 쓰는 '* '·'• ' 글머리도 진짜 목록(List Bullet, 들여쓰면 List Bullet 2)이 되고 기호는 지운다.
#      '**굵게**'로 시작하는 줄은 목록이 아니다
"$PY" -I -W ignore - "$T/hy.docx" > "$T/d21.txt" 2>&1 <<'EOF'
import sys, docx
for p in docx.Document(sys.argv[1]).paragraphs:
    if p.text.strip(): print(p.style.name, "|", p.text)
EOF
grep -qxF 'List Bullet | 별표 항목' "$T/d21.txt" && grep -qxF 'List Bullet 2 | 별표 둘째 단계' "$T/d21.txt" \
  && grep -qxF 'List Bullet | 가운뎃점 항목' "$T/d21.txt" && grep -qxF 'Normal | 굵게 시작하는 본문' "$T/d21.txt" \
  && ! grep -qF '•' "$T/d21.txt" && pass star-dot-bullets || bad star-dot-bullets "$(tr '\n' '/' < "$T/d21.txt")"

# D22. 자리 표시 경고: [ ]·[내용 입력]·TODO·○○ 등이 남으면 OK 다음에 '경고 자리 표시' 한 줄(파일 생성, rc 0).
#      영어 낱말 속 TODO(TODOS 등)는 자리 표시가 아니다. 깨끗한 입력에는 경고 없음
printf '# 보고\n담당: ○○ 과장\n- [내용 입력]\n- 확인TODO 남음\n- TODOS 목록은 그대로\n' > "$T/ph.md"
"$W" from-md "$T/ph.md" "$T/ph.docx" > "$T/d22.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/d22.txt")"
[ $rc -eq 0 ] && [ "$(first "$T/d22.txt")" = "OK $T/ph.docx" ] && [ -f "$T/ph.docx" ] && [ "$(grep -c '^경고 자리 표시' "$T/d22.txt")" = "1" ] \
  && printf '%s' "$w" | grep -qF '○○' && printf '%s' "$w" | grep -qF '[내용 입력]' && printf '%s' "$w" | grep -qF 'TODO' \
  && ! printf '%s' "$w" | grep -qF 'TODOS' && ! grep -q '^경고' "$T/hyo.txt" \
  && pass placeholder-warning || bad placeholder-warning "rc=$rc $(tr '\n' '/' < "$T/d22.txt") | clean: $(grep '^경고' "$T/hyo.txt" | tr '\n' '/')"

# D23. 줄을 넘는 자리 표시('[' 다음 줄 ' ]')도 경고는 한 줄이다. OK·저장 요약 뒤 모든 줄이 '경고 '로 시작한다.
printf '# 제목\n## 쪽\n[\n ]\n' > "$T/mlph.md"
"$W" from-md "$T/mlph.md" "$T/mlph.docx" > "$T/d23.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/d23.txt")" = "OK $T/mlph.docx" ] && [ "$(sed -n '3,$p' "$T/d23.txt" | grep -vc '^경고 ')" = "0" ] \
  && [ "$(grep -c '^경고 자리 표시' "$T/d23.txt")" = "1" ] && grep '^경고 자리 표시' "$T/d23.txt" | grep -qF '[ ]' \
  && pass multiline-placeholder-one-line || bad multiline-placeholder-one-line "rc=$rc $(tr '\n' '/' < "$T/d23.txt")"

# D24. 서로 다른 자리 표시가 아주 많아도(20만 개, 2MB) 30초 안에 끝나고 경고에는 5개만 나온다.
"$PY" -I -c '
print("# 제목\n## 많음")
for r in range(4000):
    print(" ".join("[입력 %d]" % (r * 50 + i) for i in range(50)))' > "$T/manyph.md"
"$PY" -I -W ignore - "$W" "$T/manyph.md" "$T/manyph.docx" > "$T/d24.txt" 2>&1 <<'EOF'
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
w = [l for l in r.stdout.splitlines() if l.startswith("경고 자리 표시")]
print(r.returncode, len(w), w[0].count("[입력 ") if w else 0)
EOF
[ "$(cat "$T/d24.txt")" = "0 1 5" ] && pass many-placeholders-fast || bad many-placeholders-fast "$(cat "$T/d24.txt")"


# D25. 자유 형식 대괄호 자리 표시도 경고한다: 채울 값의 이름(금액·이름·날짜 등)으로 끝나는 대괄호,
#      업무·목표·항목 등 뒤에 번호가 붙은 대괄호. 경고는 한 줄, 파일은 만들고 rc 0.
printf '# 주간 보고\n- [이번 주 완료한 업무 2]\n- [목표 1]\n| 부서 | 1월 |\n| --- | --- |\n| 기획 | [기획 1월 금액] |\n\n담당: [담당자 이름], 시작: [시작 날짜]\n' > "$T/ffph.md"
"$W" from-md "$T/ffph.md" "$T/ffph.docx" > "$T/d25.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/d25.txt")"; ok=1
for tok in '[이번 주 완료한 업무 2]' '[목표 1]' '[기획 1월 금액]' '[담당자 이름]' '[시작 날짜]'; do printf '%s' "$w" | grep -qF "$tok" || ok=0; done
[ $rc -eq 0 ] && [ "$(first "$T/d25.txt")" = "OK $T/ffph.docx" ] && [ "$(grep -c '^경고 자리 표시' "$T/d25.txt")" = "1" ] && [ $ok -eq 1 ] \
  && pass freeform-placeholder-warning || bad freeform-placeholder-warning "rc=$rc $(tr '\n' '/' < "$T/d25.txt")"

# D26. 문서에 흔한 대괄호 글은 자리 표시가 아니다: 참고·별첨 번호, [단위: 원], 번호 없는 소제목([주요 업무]·[추진 목표]),
#      마크다운 링크 글자([담당자 이름](mailto:…)).
printf '# 보고\n[참고 1] 관련 법령\n[별첨 2] 예산표\n## [주요 업무]\n- [추진 목표] 정리\n- 금액 [단위: 원]\n- 문의: [담당자 이름](mailto:a@example.com)\n' > "$T/ffok.md"
"$W" from-md "$T/ffok.md" "$T/ffok.docx" > "$T/d26.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/d26.txt")" = "OK $T/ffok.docx" ] && ! grep -q '^경고 자리 표시' "$T/d26.txt" \
  && pass freeform-placeholder-no-false-positive || bad freeform-placeholder-no-false-positive "rc=$rc $(tr '\n' '/' < "$T/d26.txt")"


# D27. 대괄호 뒤 공백이 아주 길어도(20만 칸) 자리 표시 검사가 30초 안에 끝난다(역추적 폭주 없음).
"$PY" -I -c 'print("# 보고\n" + "[이름" + " " * 200000 + "!")' > "$T/ffsp.md"
"$PY" -I -W ignore - "$W" "$T/ffsp.md" "$T/ffsp.docx" > "$T/d27.txt" 2>&1 <<'EOF'
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
print(r.returncode, r.stdout.splitlines()[0][:2] if r.stdout else "-")
EOF
[ "$(cat "$T/d27.txt")" = "0 OK" ] && pass freeform-placeholder-spaces-fast || bad freeform-placeholder-spaces-fast "$(cat "$T/d27.txt")"

# D28. 이름 대신 쓰는 말(회사명·성함·종료일 등)로 끝나는 대괄호도 자리 표시로 경고한다.
printf '# 보고\n- 회사: [회사명]\n- 연락: [담당자 성함]\n- 끝: [종료일]\n' > "$T/ffmore.md"
"$W" from-md "$T/ffmore.md" "$T/ffmore.docx" > "$T/d28.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/d28.txt")"; ok=1
for tok in '[회사명]' '[담당자 성함]' '[종료일]'; do printf '%s' "$w" | grep -qF "$tok" || ok=0; done
[ $rc -eq 0 ] && [ "$(grep -c '^경고 자리 표시' "$T/d28.txt")" = "1" ] && [ $ok -eq 1 ] \
  && pass freeform-placeholder-more-nouns || bad freeform-placeholder-more-nouns "rc=$rc $(tr '\n' '/' < "$T/d28.txt")"

# D29. 쌍점이 든 대괄호(참고·별첨 설명)와 참조식 링크 글자([담당자 이름][contact])는 자리 표시가 아니다.
printf '# 보고\n[참고: 도로명주소]\n[별첨 2: 담당자 연락처]\n문의는 [담당자 이름][contact] 으로\n\n[contact]: mailto:a@example.com\n' > "$T/ffcolon.md"
"$W" from-md "$T/ffcolon.md" "$T/ffcolon.docx" > "$T/d29.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/d29.txt")" = "OK $T/ffcolon.docx" ] && ! grep -q '^경고 자리 표시' "$T/d29.txt" \
  && pass freeform-placeholder-colon-reflink || bad freeform-placeholder-colon-reflink "rc=$rc $(tr '\n' '/' < "$T/d29.txt")"

finish
