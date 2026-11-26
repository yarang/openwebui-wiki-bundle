#!/bin/bash
# pptx skill 인수 시험. 사용: CLAUDE_LMS_PY=<python> tests/accept_pptx.sh
# 모든 시험이 통과하면 "ACCEPT PASS" 를 출력하고 0 으로 끝난다.
NAME=pptx; EXT=pptx
. "$(dirname "$0")/lib_office_accept.sh"

cat > "$T/in.md" <<'MD'
# 2026 사업 계획
기획팀 · 2026-11-10

## 추진 배경
- 문서 작업 **자동화** 수요 증가
  - 하위 항목 하나
    - 더 깊은 항목
- 비용 절감
일반 문장도 들어간다
1. 번호 문장은 그대로

---

## 예산 요약
- 총액은 아래 표와 같다
| 항목 | 금액 |
| --- | --- |
| 인건비 | 1,000 |
| **합계** | 1,500 |

## 일정
### 상반기
- 설계
### 하반기
- 구축
MD
common_cases "$T/in.md" "# 2026 사업 계획" "## 추진 배경" "자동화" "하위 항목" "인건비" "1,000"

# P1. 슬라이드 크기 16:9, 슬라이드 수, 레이아웃(제목/제목+내용/표 슬라이드는 제목만)
"$PY" -I -W ignore - "$T/out.pptx" > "$T/p1.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
p = Presentation(sys.argv[1])
print(p.slide_width, p.slide_height, len(p.slides))
for s in p.slides:
    t = s.shapes.title.text_frame.text if s.shapes.title is not None else "-"
    print(f"{s.slide_layout.name}|{t}")
EOF
cat > "$T/p1.want" <<'W'
12192000 6858000 4
Title Slide|2026 사업 계획
Title and Content|추진 배경
Title Only|예산 요약
Title and Content|일정
W
diff -q "$T/p1.want" "$T/p1.txt" > /dev/null && pass size-layouts || bad size-layouts "$(tr '\n' '/' < "$T/p1.txt")"

# P1b. 16:9 배치: 기본 4:3 서식의 자리표시자를 그대로 두면 제목·본문이 왼쪽 3/4 에 몰린다.
#      모든 슬라이드의 제목은 오른쪽 끝이 너비의 90% 이상이고 좌우 여백이 비슷해야 하며, 어떤 모양도 슬라이드 밖으로 나가지 않는다.
"$PY" -I -W ignore - "$T/out.pptx" > "$T/p1b.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
p = Presentation(sys.argv[1]); W, H = p.slide_width, p.slide_height
out = []
for i, s in enumerate(p.slides, 1):
    t = s.shapes.title
    right = t.left + t.width
    centred = abs(t.left - (W - right)) <= W * 0.05
    inside = all(sh.left >= 0 and sh.top >= 0 and sh.left + sh.width <= W and sh.top + sh.height <= H for sh in s.shapes)
    out.append(f"{i}:{right >= W * 0.9}:{centred}:{inside}")
print(" ".join(out))
EOF
[ "$(cat "$T/p1b.txt")" = "1:True:True:True 2:True:True:True 3:True:True:True 4:True:True:True" ] && pass widescreen-placement || bad widescreen-placement "$(cat "$T/p1b.txt")"

# P2. 제목 슬라이드 부제목, 본문 글머리 수준·글자, --- 는 무시, ### 는 굵은 수준 0 문단
"$PY" -I -W ignore - "$T/out.pptx" > "$T/p2.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
p = Presentation(sys.argv[1]); sl = list(p.slides)
sub = [ph for ph in sl[0].placeholders if ph.placeholder_format.idx == 1]
print("SUB|" + (sub[0].text_frame.text if sub else "-"))
def body(s):
    for sh in s.shapes:
        if sh.has_text_frame and sh != s.shapes.title:
            for para in sh.text_frame.paragraphs:
                txt = "".join(r.text for r in para.runs)
                if txt:
                    b = all(r.font.bold for r in para.runs)
                    print(f"{para.level}|{txt}|{'B' if b else '-'}")
for i in (1, 3):
    print("S", i); body(sl[i])
EOF
cat > "$T/p2.want" <<'W'
SUB|기획팀 · 2026-11-10
S 1
0|문서 작업 자동화 수요 증가|-
1|하위 항목 하나|-
2|더 깊은 항목|-
0|비용 절감|-
0|일반 문장도 들어간다|-
0|1. 번호 문장은 그대로|-
S 3
0|상반기|B
0|설계|-
0|하반기|B
0|구축|-
W
diff -q "$T/p2.want" "$T/p2.txt" > /dev/null && pass body-levels || bad body-levels "$(diff "$T/p2.want" "$T/p2.txt" | grep '^[<>]' | head -6 | tr '\n' '/')"

# P3. **굵게** 는 굵은 run 으로, 2 ** 3 은 글자 그대로
printf '## 굵게\n- 문서 **자동화** 끝\n- 2 ** 3 은 8\n' > "$T/bold.md"
"$W" from-md "$T/bold.md" "$T/bold.pptx" > /dev/null 2>&1
"$PY" -I -W ignore - "$T/bold.pptx" > "$T/p3.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
s = Presentation(sys.argv[1]).slides[0]
for sh in s.shapes:
    if sh.has_text_frame and sh != s.shapes.title:
        for para in sh.text_frame.paragraphs:
            print("/".join(f"{r.text}{'*' if r.font.bold else ''}" for r in para.runs))
EOF
[ "$(cat "$T/p3.txt")" = "문서 /자동화*/ 끝
2 ** 3 은 8" ] && pass bold-runs || bad bold-runs "$(tr '\n' '|' < "$T/p3.txt")"

# P4. 표 슬라이드: 표 모양(3x2), 머리 행 굵게, 셀 **굵게** 는 굵은 글자, 표가 제목·글머리와 겹치지 않음
"$PY" -I -W ignore - "$T/out.pptx" > "$T/p4.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
s = list(Presentation(sys.argv[1]).slides)[2]
tb = [sh for sh in s.shapes if sh.has_table]
t = tb[0].table
cell = lambda r, c: t.cell(r, c).text_frame
bold = lambda r, c: all(x.font.bold for p in cell(r, c).paragraphs for x in p.runs)
print(len(tb), len(t.rows), len(t.columns))
print("/".join(cell(r, 0).text for r in range(len(t.rows))), bold(0, 0), bold(1, 0), bold(2, 0))
others = [sh for sh in s.shapes if not sh.has_table]
print(all(sh.top + sh.height <= tb[0].top for sh in others if sh.has_text_frame and sh.text_frame.text))
print(tb[0].left + tb[0].width <= 12192000 and tb[0].top + tb[0].height <= 6858000)
EOF
[ "$(cat "$T/p4.txt")" = "1 3 2
항목/인건비/합계 True False True
True
True" ] && pass table-slide || bad table-slide "$(tr '\n' '|' < "$T/p4.txt")"

# P5. 모든 글자 run 에 동아시아 글꼴(a:ea 맑은 고딕) — 제목·부제목·본문·표 칸 모두, rPr 자식 순서는 스키마대로
"$PY" -I -W ignore - "$T/out.pptx" > "$T/p5.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
from pptx.oxml.ns import qn
runs = bad = 0
for s in Presentation(sys.argv[1]).slides:
    for r in s.shapes._spTree.iter(qn("a:r")):
        runs += 1
        rpr = r.find(qn("a:rPr")); ea = rpr.find(qn("a:ea")) if rpr is not None else None
        if ea is None or ea.get("typeface") != "맑은 고딕":
            bad += 1
# a:rPr 자식 순서가 스키마 순서와 어긋나면 PowerPoint 가 '복구' 창을 띄운다
ORDER = ["ln", "noFill|solidFill|gradFill|blipFill|pattFill|grpFill", "effectLst|effectDag", "highlight",
         "uLnTx|uLn", "uFillTx|uFill", "latin", "ea", "cs", "sym", "hlinkClick", "hlinkMouseOver", "rtl", "extLst"]
rank = {n: i for i, g in enumerate(ORDER) for n in g.split("|")}
misorder = 0
for s in Presentation(sys.argv[1]).slides:
    for rpr in list(s.shapes._spTree.iter(qn("a:rPr"))) + list(s.shapes._spTree.iter(qn("a:endParaRPr"))):
        ks = [rank.get(c.tag.split("}")[1], 99) for c in rpr]
        if ks != sorted(ks):
            misorder += 1
print(runs > 20, bad + misorder)
EOF
[ "$(cat "$T/p5.txt")" = "True 0" ] && pass east-asia-font || bad east-asia-font "$(cat "$T/p5.txt")"

# P6. 제목(#·##)이 하나도 없으면 한 줄 ERROR, 출력 없음
printf -- '- 항목만 있다\n본문\n' > "$T/nohead.md"
"$W" from-md "$T/nohead.md" "$T/nohead.pptx" > "$T/p6.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(lines "$T/p6.txt")" = "1" ] && grep -q '^ERROR .*슬라이드' "$T/p6.txt" && [ ! -e "$T/nohead.pptx" ] && pass no-heading || bad no-heading "rc=$rc $(first "$T/p6.txt")"

# P7. 첫 줄이 ## 이면 제목 슬라이드 없이 시작, 뒤에 나오는 # 는 일반 슬라이드
printf '## 첫 장\n- 가\n# 두 번째 큰 제목\n- 나\n' > "$T/noh1.md"
"$W" from-md "$T/noh1.md" "$T/noh1.pptx" > /dev/null 2>&1
"$PY" -I -W ignore - "$T/noh1.pptx" > "$T/p7.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
print("/".join(f"{s.slide_layout.name}:{s.shapes.title.text_frame.text}" for s in Presentation(sys.argv[1]).slides))
EOF
[ "$(cat "$T/p7.txt")" = "Title and Content:첫 장/Title and Content:두 번째 큰 제목" ] && pass first-is-h2 || bad first-is-h2 "$(cat "$T/p7.txt")"

# P8. read 형식: 제목 슬라이드는 #, 나머지 ##, 글머리는 수준마다 두 칸, 굵게는 **, 표는 GFM
"$W" read "$T/out.pptx" > "$T/p8.txt" 2>&1
grep -qx '# 2026 사업 계획' "$T/p8.txt" && grep -qx '## 추진 배경' "$T/p8.txt" && grep -qxF -- '- 문서 작업 **자동화** 수요 증가' "$T/p8.txt" \
  && grep -qxF -- '  - 하위 항목 하나' "$T/p8.txt" && grep -qxF -- '    - 더 깊은 항목' "$T/p8.txt" && grep -qxF '| 항목 | 금액 |' "$T/p8.txt" \
  && grep -qxF '| --- | --- |' "$T/p8.txt" && grep -qxF '| **합계** | 1,500 |' "$T/p8.txt" && grep -qx '기획팀 · 2026-11-10' "$T/p8.txt" \
  && ! grep -q '&amp;\|&lt;' "$T/p8.txt" && pass read-markdown-shape || bad read-markdown-shape "$(sed -n '2,12p' "$T/p8.txt" | tr '\n' '/')"

# P9. 왕복: read 결과로 다시 만든 발표 자료는 레이아웃·제목·(수준, 글자, 굵게)·표가 같다
tail -n +2 "$T/p8.txt" > "$T/rt.md"
"$W" from-md "$T/rt.md" "$T/rt.pptx" > /dev/null 2>&1
dump() { "$PY" -I -W ignore - "$1" <<'EOF'
import sys
from pptx import Presentation
for s in Presentation(sys.argv[1]).slides:
    print("##", s.slide_layout.name, s.shapes.title.text_frame.text if s.shapes.title is not None else "-")
    for sh in s.shapes:
        if sh.has_table:
            print([[(c.text, all(r.font.bold for p in c.text_frame.paragraphs for r in p.runs)) for c in row.cells] for row in sh.table.rows])
        elif sh.has_text_frame and sh != s.shapes.title:
            print([(p.level, [(r.text, bool(r.font.bold)) for r in p.runs]) for p in sh.text_frame.paragraphs if p.runs])
EOF
}
[ "$(dump "$T/out.pptx")" = "$(dump "$T/rt.pptx")" ] && pass roundtrip || bad roundtrip "$(diff <(dump "$T/out.pptx") <(dump "$T/rt.pptx") | head -4 | tr '\n' '/')"

# P10. PowerPoint 로 만든 듯한 외부 파일(제목 없는 슬라이드·빈 슬라이드·그룹 안 글상자·메모)도 읽는다
"$PY" -I -W ignore - "$T/ext.pptx" <<'EOF'
import sys
from pptx import Presentation
from pptx.util import Inches
p = Presentation()
s = p.slides.add_slide(p.slide_layouts[6])
g = s.shapes.add_group_shape()
g.shapes.add_textbox(Inches(1), Inches(1), Inches(3), Inches(1)).text_frame.text = "그룹 안 글"
s.notes_slide.notes_text_frame.text = "발표자 메모"
p.slides.add_slide(p.slide_layouts[6])
p.save(sys.argv[1])
EOF
"$W" read "$T/ext.pptx" > "$T/p10.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '그룹 안 글' "$T/p10.txt" && grep -qx '## (슬라이드 1)' "$T/p10.txt" && grep -qx '## (슬라이드 2)' "$T/p10.txt" && pass read-foreign-pptx || bad read-foreign-pptx "rc=$rc $(sed -n '1,8p' "$T/p10.txt" | tr '\n' '/')"

# P11. 너무 넓거나 큰 표: 75열 초과, 칸 합계 10만 초과면 만들기 전에 한 줄 ERROR, 출력 없음(빨리 끝남)
for spec in "wide 20000 1" "w76 76 1" "many 300 400"; do
  set -- $spec
  wide_table_md "$T/$1.md" "$2" "$3"
  limited 60 "$W" from-md "$T/$1.md" "$T/$1.pptx" > "$T/p11-$1.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ $rc -ne 142 ] && [ "$(lines "$T/p11-$1.txt")" = "1" ] && grep -q '^ERROR ' "$T/p11-$1.txt" && [ ! -e "$T/$1.pptx" ] && pass "table-too-big-$1" || bad "table-too-big-$1" "rc=$rc $(first "$T/p11-$1.txt")"
done

# P12. 표지 # 제목 바로 아래 ### 소제목: 내부 오류 없이 만들고, 소제목 글이 남는다
printf '# 표지\n### 소제목\n발표자\n\n## 둘째\n- 항목\n' > "$T/cover-h3.md"
"$W" from-md "$T/cover-h3.md" "$T/cover-h3.pptx" > "$T/p12.txt" 2>&1; rc=$?
"$W" read "$T/cover-h3.pptx" > "$T/p12b.txt" 2>&1
[ $rc -eq 0 ] && [ "$(first "$T/p12.txt")" = "OK $T/cover-h3.pptx" ] && grep -q '소제목' "$T/p12b.txt" && grep -q '발표자' "$T/p12b.txt" && pass cover-h3 || bad cover-h3 "rc=$rc $(first "$T/p12.txt")"

# P13. 차트(내장 엑셀 통합 문서)가 든 발표 자료도 pptx 로 알아보고 읽는다
"$PY" -I -W ignore - "$T/chart.pptx" <<'EOF'
import sys, pptx
from pptx.chart.data import CategoryChartData
from pptx.enum.chart import XL_CHART_TYPE
from pptx.util import Inches
p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[5]); s.shapes.title.text = "차트 슬라이드"
cd = CategoryChartData(); cd.categories = ["가", "나"]; cd.add_series("값", (1, 2))
s.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(1), Inches(2), Inches(6), Inches(4), cd)
p.save(sys.argv[1])
EOF
"$W" read "$T/chart.pptx" > "$T/p13.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/p13.txt")" = "OK $T/chart.pptx" ] && grep -q '차트 슬라이드' "$T/p13.txt" && pass read-chart-pptx || bad read-chart-pptx "rc=$rc $(first "$T/p13.txt")"

# P14. 기하(prstGeom/custGeom)도 txBox 표시도 없는 모양(python-pptx 가 shape_type 에서 NotImplementedError)도 읽는다
"$PY" -I -W ignore - "$T/nogeom.pptx" <<'EOF'
import sys, pptx
from pptx.enum.shapes import MSO_SHAPE
from pptx.oxml.ns import qn
from pptx.util import Inches
p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[5]); s.shapes.title.text = "기하 없음 슬라이드"
sh = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(1), Inches(2), Inches(4), Inches(1)); sh.text_frame.text = "모양 속 글"
g = sh._element.spPr.find(qn("a:prstGeom")); g.getparent().remove(g)
p.save(sys.argv[1])
EOF
"$W" read "$T/nogeom.pptx" > "$T/p14.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '기하 없음 슬라이드' "$T/p14.txt" && grep -q '모양 속 글' "$T/p14.txt" && pass read-shape-without-geometry || bad read-shape-without-geometry "rc=$rc $(first "$T/p14.txt")"

# P15. UTF-8 BOM 으로 시작하는 md: 첫 줄 # 가 제목 슬라이드가 된다
printf '\xef\xbb\xbf# 표지\n부제\n\n## 둘째\n- 항목\n' > "$T/bom.md"
"$W" from-md "$T/bom.md" "$T/bom.pptx" > "$T/p15.txt" 2>&1
"$PY" -I -W ignore -c 'import sys, pptx; s = pptx.Presentation(sys.argv[1]).slides[0]; print(s.slide_layout.name, s.shapes.title.text)' "$T/bom.pptx" > "$T/p15b.txt" 2>&1
[ "$(cat "$T/p15b.txt")" = "Title Slide 표지" ] && pass utf8-bom || bad utf8-bom "$(first "$T/p15.txt") $(cat "$T/p15b.txt")"

# P16. 표 칸 안 여러 문단·줄바꿈(<a:br/>)은 공백으로 이어 한 줄로(가나 처럼 붙지도, 표가 깨지지도 않는다)
"$PY" -I -W ignore - "$T/cellnl.pptx" <<'EOF'
import sys, pptx
from pptx.util import Inches
p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[5]); s.shapes.title.text = "칸 줄바꿈"
t = s.shapes.add_table(2, 2, Inches(1), Inches(2), Inches(6), Inches(1)).table
t.cell(0, 0).text = "항목"; t.cell(0, 1).text = "비고"
tf = t.cell(1, 0).text_frame; tf.text = "가"; tf.add_paragraph().text = "나"
t.cell(1, 1).text_frame.paragraphs[0].text = "1차\v2차"
p.save(sys.argv[1])
EOF
"$W" read "$T/cellnl.pptx" > "$T/p16.txt" 2>&1
grep -qxF '| 가 나 | 1차 2차 |' "$T/p16.txt" && pass multiline-cell || bad multiline-cell "$(tail -n +2 "$T/p16.txt" | tr '\n' '/')"

# P17. 굵은 run 이 이어지거나 공백을 품어도 **** 나 ** 설명** 같은 깨진 표시가 없고, 왕복해도 같은 결과
cat > "$T/bsp.md" <<'MD'
## 예산
### **상반기** 실적
- **핵심** 과제
| **항목** 설명 | 금액 |
| --- | --- |
| 인건비 | **100** 원 |
MD
"$W" from-md "$T/bsp.md" "$T/bsp.pptx" > /dev/null 2>&1
"$W" read "$T/bsp.pptx" > "$T/p17.txt" 2>&1
tail -n +2 "$T/p17.txt" > "$T/bsp2.md"
"$W" from-md "$T/bsp2.md" "$T/bsp2.pptx" > /dev/null 2>&1
"$W" read "$T/bsp2.pptx" > "$T/p17b.txt" 2>&1
! grep -qF '****' "$T/p17.txt" && grep -qF '| 항목 설명 | 금액 |' "$T/p17.txt" && grep -qF '**100** 원' "$T/p17.txt" \
  && ! grep -qE '\*\* [^|]*\*\*' "$T/p17.txt" && diff <(tail -n +2 "$T/p17.txt") <(tail -n +2 "$T/p17b.txt") > /dev/null && pass bold-run-spaces || bad bold-run-spaces "$(tail -n +2 "$T/p17.txt" | tr '\n' '/') :: $(tail -n +2 "$T/p17b.txt" | tr '\n' '/')"

# P18. 들여쓰기가 아주 깊은 글머리(수준 9 이상)는 PowerPoint 최대 수준 8 로 맞춘다(크래시 없음)
printf '## 깊이\n- 하나\n                    - 아주 깊은 항목\n' > "$T/deep.md"
"$W" from-md "$T/deep.md" "$T/deep.pptx" > "$T/p18.txt" 2>&1; rc=$?
"$PY" -I -W ignore -c 'import sys, pptx
s = pptx.Presentation(sys.argv[1]).slides[0]
print(max(p.level for sh in s.shapes if sh.has_text_frame and sh != s.shapes.title for p in sh.text_frame.paragraphs))' "$T/deep.pptx" > "$T/p18b.txt" 2>&1
[ $rc -eq 0 ] && [ "$(cat "$T/p18b.txt")" = "8" ] && pass bullet-level-clamp || bad bullet-level-clamp "rc=$rc $(first "$T/p18.txt") $(cat "$T/p18b.txt")"

# P19. 제목이 빈 제목 슬라이드: 부제 글을 잃지 않는다
"$PY" -I -W ignore - "$T/notitle.pptx" <<'EOF'
import sys, pptx
p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[0])
s.placeholders[1].text = "부제만 있음"
p.save(sys.argv[1])
EOF
"$W" read "$T/notitle.pptx" > "$T/p19.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -qF '부제만 있음' "$T/p19.txt" && pass title-slide-no-title || bad title-slide-no-title "rc=$rc $(tail -n +2 "$T/p19.txt" | tr '\n' '/')"

# P20. 표가 아닌 | 줄(구분선 없음)은 그 글 그대로 본문 문단이 된다(파이썬 튜플 표시 금지)
printf '## 안내\n| 참고: 내용\n- 항목\n' > "$T/pipe.md"
"$W" from-md "$T/pipe.md" "$T/pipe.pptx" > "$T/p20.txt" 2>&1; rc=$?
"$W" read "$T/pipe.pptx" > "$T/p20r.txt" 2>&1
[ $rc -eq 0 ] && grep -qF '| 참고: 내용' "$T/p20r.txt" && ! grep -qF "('" "$T/p20r.txt" && pass non-table-pipe-line || bad non-table-pipe-line "rc=$rc $(tail -n +2 "$T/p20r.txt" | tr '\n' '/')"

# ── 혼합안(anthropics/skills 지침 반영) ─────────────────────────────────────────
cat > "$T/hy.md" <<'MD'
# 교육 소개
2026년 신입 과정
## 목표
- 첫째 단계
  - 둘째 단계
### 소제목
일반 문단
## 일정
설명 한 줄
| 주차 | 내용 |
| --- | --- |
| 1 | 오리엔테이션 |
MD
"$W" from-md "$T/hy.md" "$T/hy.pptx" > "$T/hyo.txt" 2>&1; hyrc=$?

# P21. 글자 크기를 모든 run 에 명시: 표지 제목 44pt 굵게·부제 24pt, 슬라이드 제목 36pt 굵게,
#      본문 수준 0 = 20pt·수준 1 이상 = 18pt·일반 문단 20pt·### 20pt 굵게, 표 위 글상자도 같음, 표 칸 16pt(머리 행 굵게)
"$PY" -I -W ignore - "$T/hy.pptx" > "$T/p21.txt" 2>&1 <<'EOF'
import sys
from pptx import Presentation
def rs(tf): return [r for p in tf.paragraphs for r in p.runs]
def sz(r): return None if r.font.size is None else round(r.font.size.pt)
out = []
for i, s in enumerate(Presentation(sys.argv[1]).slides):
    t = s.shapes.title
    out.append(f"S{i} title " + " ".join(f"{sz(r)}{'B' if r.font.bold else ''}" for r in rs(t.text_frame)))
    for sh in s.shapes:
        if sh.has_table:
            for ri, row in enumerate(sh.table.rows):
                out.append(f"S{i} cell{ri} " + " ".join(f"{sz(r)}{'B' if r.font.bold else ''}" for c in row.cells for r in rs(c.text_frame)))
        elif sh.has_text_frame and sh != t:
            for p in sh.text_frame.paragraphs:
                for r in p.runs: out.append(f"S{i} L{p.level} {r.text} {sz(r)}{'B' if r.font.bold else ''}")
print("\n".join(out))
EOF
cat > "$T/p21want.txt" <<'TXT'
S0 title 44B
S0 L0 2026년 신입 과정 24
S1 title 36B
S1 L0 첫째 단계 20
S1 L1 둘째 단계 18
S1 L0 소제목 20B
S1 L0 일반 문단 20
S2 title 36B
S2 L0 설명 한 줄 20
S2 cell0 16B 16B
S2 cell1 16 16
TXT
[ $hyrc -eq 0 ] && diff -q "$T/p21want.txt" "$T/p21.txt" > /dev/null && pass explicit-font-sizes || bad explicit-font-sizes "rc=$hyrc $(diff "$T/p21want.txt" "$T/p21.txt" | grep '^[<>]' | head -6 | tr '\n' '/')"

# P22. '* '·'• ' 글머리도 '- '처럼 수준이 있는 글머리가 되고 기호는 지운다
printf '## 기호\n* 별표\n  • 가운뎃점 둘째\n- 빼기\n' > "$T/star.md"
"$W" from-md "$T/star.md" "$T/star.pptx" > "$T/p22.txt" 2>&1; rc=$?
"$PY" -I -W ignore -c 'import sys, pptx
s = pptx.Presentation(sys.argv[1]).slides[0]
print([(p.level, p.text) for sh in s.shapes if sh.has_text_frame and sh != s.shapes.title for p in sh.text_frame.paragraphs if p.text])' "$T/star.pptx" > "$T/p22b.txt" 2>&1
[ $rc -eq 0 ] && [ "$(cat "$T/p22b.txt")" = "[(0, '별표'), (1, '가운뎃점 둘째'), (0, '빼기')]" ] && pass star-dot-bullets || bad star-dot-bullets "rc=$rc $(cat "$T/p22b.txt")"

# P23. 넘침 경고: 본문 항목이 8개를 넘는 슬라이드, 12행을 넘는 표는 슬라이드 번호와 함께 '경고 슬라이드 N:' 한 줄.
#      파일은 만들고 rc 0, 첫 줄 OK. 6개짜리 슬라이드와 작은 표는 경고하지 않는다
{ printf '## 적당\n'; for n in 1 2 3 4 5 6; do printf -- '- 항목 %s\n' "$n"; done
  printf '## 많음\n'; for n in 1 2 3 4 5 6 7 8 9; do printf -- '- 항목 %s\n' "$n"; done
  printf '## 큰 표\n| 번호 | 값 |\n| --- | --- |\n'; for n in $(seq 1 13); do printf '| %s | 값 |\n' "$n"; done
  printf '## 작은 표\n| 번호 | 값 |\n| --- | --- |\n| 1 | 값 |\n'; } > "$T/many.md"
"$W" from-md "$T/many.md" "$T/many.pptx" > "$T/p23.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/p23.txt")" = "OK $T/many.pptx" ] && [ -f "$T/many.pptx" ] \
  && [ "$(grep -c '^경고 슬라이드 ' "$T/p23.txt")" = "2" ] && grep -q '^경고 슬라이드 2:.*9' "$T/p23.txt" && grep -q '^경고 슬라이드 3:' "$T/p23.txt" \
  && ! grep -q '^경고' "$T/hyo.txt" && pass overflow-warning || bad overflow-warning "rc=$rc $(tr '\n' '/' < "$T/p23.txt")"

# P24. 자리 표시 경고: [ ]·lorem·xxx 등이 남으면 OK 다음에 '경고 자리 표시' 한 줄(파일 생성, rc 0)
printf '# 제목\n[여기에 부제]\n## 본문\n- Lorem ipsum\n- 담당 XXX\n| 가 | 나 |\n| --- | --- |\n| [ ] | 1 |\n' > "$T/ph.md"
"$W" from-md "$T/ph.md" "$T/ph.pptx" > "$T/p24.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/p24.txt")"
[ $rc -eq 0 ] && [ "$(first "$T/p24.txt")" = "OK $T/ph.pptx" ] && [ -f "$T/ph.pptx" ] && [ "$(grep -c '^경고 자리 표시' "$T/p24.txt")" = "1" ] \
  && printf '%s' "$w" | grep -qiF 'lorem' && printf '%s' "$w" | grep -qF '[ ]' && printf '%s' "$w" | grep -qiF 'xxx' \
  && pass placeholder-warning || bad placeholder-warning "rc=$rc $(tr '\n' '/' < "$T/p24.txt")"

# P25. 줄을 넘는 자리 표시('[' 다음 줄 ' ]')도 경고는 한 줄이다. OK·저장 요약 뒤 모든 줄이 '경고 '로 시작한다.
printf '# 제목\n## 쪽\n[\n ]\n' > "$T/mlph.md"
"$W" from-md "$T/mlph.md" "$T/mlph.pptx" > "$T/p25.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/p25.txt")" = "OK $T/mlph.pptx" ] && [ "$(sed -n '3,$p' "$T/p25.txt" | grep -vc '^경고 ')" = "0" ] \
  && [ "$(grep -c '^경고 자리 표시' "$T/p25.txt")" = "1" ] && grep '^경고 자리 표시' "$T/p25.txt" | grep -qF '[ ]' \
  && pass multiline-placeholder-one-line || bad multiline-placeholder-one-line "rc=$rc $(tr '\n' '/' < "$T/p25.txt")"

# P26. 서로 다른 자리 표시가 아주 많아도(20만 개, 2MB) 30초 안에 끝나고 경고에는 5개만 나온다.
"$PY" -I -c '
print("# 제목\n## 많음")
for r in range(4000):
    print(" ".join("[입력 %d]" % (r * 50 + i) for i in range(50)))' > "$T/manyph.md"
"$PY" -I -W ignore - "$W" "$T/manyph.md" "$T/manyph.pptx" > "$T/p26.txt" 2>&1 <<'EOF'
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
w = [l for l in r.stdout.splitlines() if l.startswith("경고 자리 표시")]
print(r.returncode, len(w), w[0].count("[입력 ") if w else 0)
EOF
[ "$(cat "$T/p26.txt")" = "0 1 5" ] && pass many-placeholders-fast || bad many-placeholders-fast "$(cat "$T/p26.txt")"


# P27. 자유 형식 대괄호 자리 표시도 경고한다: 채울 값의 이름(금액·이름·날짜 등)으로 끝나는 대괄호,
#      업무·목표·항목 등 뒤에 번호가 붙은 대괄호. 경고는 한 줄, 파일은 만들고 rc 0.
printf '# 주간 보고\n## 실적\n- [이번 주 완료한 업무 2]\n- [목표 1]\n- 기획 [기획 1월 금액]\n- 담당 [담당자 이름]\n- 시작 [시작 날짜]\n' > "$T/ffph.md"
"$W" from-md "$T/ffph.md" "$T/ffph.pptx" > "$T/p27.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/p27.txt")"; ok=1
for tok in '[이번 주 완료한 업무 2]' '[목표 1]' '[기획 1월 금액]' '[담당자 이름]' '[시작 날짜]'; do printf '%s' "$w" | grep -qF "$tok" || ok=0; done
[ $rc -eq 0 ] && [ "$(first "$T/p27.txt")" = "OK $T/ffph.pptx" ] && [ "$(grep -c '^경고 자리 표시' "$T/p27.txt")" = "1" ] && [ $ok -eq 1 ] \
  && pass freeform-placeholder-warning || bad freeform-placeholder-warning "rc=$rc $(tr '\n' '/' < "$T/p27.txt")"

# P28. 문서에 흔한 대괄호 글은 자리 표시가 아니다: 참고·별첨 번호, [단위: 원], 번호 없는 소제목([주요 업무]·[추진 목표]),
#      마크다운 링크 글자([담당자 이름](mailto:…)).
printf '# 보고\n## [주요 업무]\n- [참고 1] 관련 법령\n- [별첨 2] 예산표\n- [추진 목표] 정리\n- 금액 [단위: 원]\n- 문의: [담당자 이름](mailto:a@example.com)\n' > "$T/ffok.md"
"$W" from-md "$T/ffok.md" "$T/ffok.pptx" > "$T/p28.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/p28.txt")" = "OK $T/ffok.pptx" ] && ! grep -q '^경고 자리 표시' "$T/p28.txt" \
  && pass freeform-placeholder-no-false-positive || bad freeform-placeholder-no-false-positive "rc=$rc $(tr '\n' '/' < "$T/p28.txt")"


# P29. 대괄호 뒤 공백이 아주 길어도(20만 칸) 자리 표시 검사가 30초 안에 끝난다(역추적 폭주 없음).
"$PY" -I -c 'print("# 보고\n## 쪽\n- " + "[이름" + " " * 200000 + "!")' > "$T/ffsp.md"
"$PY" -I -W ignore - "$W" "$T/ffsp.md" "$T/ffsp.pptx" > "$T/p29.txt" 2>&1 <<'EOF'
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
print(r.returncode, r.stdout.splitlines()[0][:2] if r.stdout else "-")
EOF
[ "$(cat "$T/p29.txt")" = "0 OK" ] && pass freeform-placeholder-spaces-fast || bad freeform-placeholder-spaces-fast "$(cat "$T/p29.txt")"

# P30. 이름 대신 쓰는 말(회사명·성함·종료일 등)로 끝나는 대괄호도 자리 표시로 경고한다.
printf '# 보고\n## 쪽\n- 회사: [회사명]\n- 연락: [담당자 성함]\n- 끝: [종료일]\n' > "$T/ffmore.md"
"$W" from-md "$T/ffmore.md" "$T/ffmore.pptx" > "$T/p30.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/p30.txt")"; ok=1
for tok in '[회사명]' '[담당자 성함]' '[종료일]'; do printf '%s' "$w" | grep -qF "$tok" || ok=0; done
[ $rc -eq 0 ] && [ "$(grep -c '^경고 자리 표시' "$T/p30.txt")" = "1" ] && [ $ok -eq 1 ] \
  && pass freeform-placeholder-more-nouns || bad freeform-placeholder-more-nouns "rc=$rc $(tr '\n' '/' < "$T/p30.txt")"

# P31. 쌍점이 든 대괄호(참고·별첨 설명)와 참조식 링크 글자([담당자 이름][contact])는 자리 표시가 아니다.
printf '# 보고\n## 쪽\n- [참고: 도로명주소]\n- [별첨 2: 담당자 연락처]\n- 문의는 [담당자 이름][contact] 으로\n' > "$T/ffcolon.md"
"$W" from-md "$T/ffcolon.md" "$T/ffcolon.pptx" > "$T/p31.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/p31.txt")" = "OK $T/ffcolon.pptx" ] && ! grep -q '^경고 자리 표시' "$T/p31.txt" \
  && pass freeform-placeholder-colon-reflink || bad freeform-placeholder-colon-reflink "rc=$rc $(tr '\n' '/' < "$T/p31.txt")"

finish
