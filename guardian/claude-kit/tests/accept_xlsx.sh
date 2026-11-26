#!/bin/bash
# xlsx skill 인수 시험. 사용: CLAUDE_LMS_PY=<python> tests/accept_xlsx.sh
# 모든 시험이 통과하면 "ACCEPT PASS" 를 출력하고 0 으로 끝난다.
NAME=xlsx; EXT=xlsx
. "$(dirname "$0")/lib_office_accept.sh"

cat > "$T/in.md" <<'MD'
# 예산 자료
설명 문단은 엑셀에 들어가지 않는다.

## 예산
| 항목 | 금액 | 비율 |
| --- | --- | --- |
| 인건비 | 1,000 | 12% |
| 운영비 | 500 | 12.5% |
| **합계** | =SUM(B2:B3) | |

## 연락처
| 이름 | 전화 | 번호 |
| --- | --- | --- |
| 홍길동 | 010-1234-5678 | 007 |
MD
common_cases "$T/in.md" "## 예산" "## 연락처" "인건비" "1,000" "=SUM(B2:B3)" "010-1234-5678"

# X1. 시트: ## 제목 순서대로 시트 이름, 표 밖 글은 들어가지 않음
"$PY" -I -W ignore - "$T/out.xlsx" > "$T/x1.txt" 2>&1 <<'EOF'
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1])
print("/".join(wb.sheetnames))
print(any("설명" in str(c.value) for ws in wb for row in ws.iter_rows() for c in row if c.value is not None))
EOF
[ "$(cat "$T/x1.txt")" = "예산/연락처
False" ] && pass sheets || bad sheets "$(tr '\n' '/' < "$T/x1.txt")"

# X2. 칸 종류: 숫자·천 단위·백분율·수식·0으로 시작·긴 숫자·날짜·음수·빈 칸
cat > "$T/types.md" <<'MD'
## 종류
| 입력 | 값 |
| --- | --- |
| 정수 | 1000 |
| 소수 | 3.5 |
| 음수 | -5 |
| 영 | 0 |
| 천단위 | 1,000 |
| 천단위소수 | 1,234.50 |
| 백분율 | 12% |
| 백분율소수 | 12.5% |
| 음수백분율 | -3% |
| 수식 | =SUM(B2:B3) |
| 전화 | 010-1234-5678 |
| 앞영 | 007 |
| 십육자리 | 1234567890123456 |
| 십오자리 | 123456789012345 |
| 날짜 | 2026-11-10 |
| 지수 | 1e5 |
| 잘못된천단위 | 1,00 |
| 빈칸 |  |
MD
"$W" from-md "$T/types.md" "$T/types.xlsx" > "$T/x2.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/types.xlsx" > "$T/x2b.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
for r in range(2, ws.max_row + 1):
    c = ws.cell(r, 2)
    fmt = c.number_format if c.data_type == "n" and c.value is not None else "-"
    print(f"{ws.cell(r, 1).value}|{c.data_type}|{c.value!r}|{fmt}")
EOF
cat > "$T/x2.want" <<'W'
정수|n|1000|General
소수|n|3.5|General
음수|n|-5|General
영|n|0|General
천단위|n|1000|#,##0
천단위소수|n|1234.5|#,##0.00
백분율|n|0.12|0%
백분율소수|n|0.125|0.0%
음수백분율|n|-0.03|0%
수식|f|'=SUM(B2:B3)'|-
전화|s|'010-1234-5678'|-
앞영|s|'007'|-
십육자리|s|'1234567890123456'|-
십오자리|n|123456789012345|General
날짜|s|'2026-11-10'|-
지수|s|'1e5'|-
잘못된천단위|s|'1,00'|-
빈칸|n|None|-
W
[ $rc -eq 0 ] && diff -q "$T/x2.want" "$T/x2b.txt" > /dev/null && pass cell-types || bad cell-types "rc=$rc $(diff "$T/x2.want" "$T/x2b.txt" | grep '^[<>]' | head -6 | tr '\n' '/')"

# X3. 머리 행 굵게, A2 틀 고정, 열 너비(한글 긴 글은 넓게), 셀 **굵게** → 글자만 남고 굵은 글꼴
"$PY" -I -W ignore - "$T/out.xlsx" > "$T/x3.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1])["예산"]
print(ws["A1"].font.b, ws["B1"].font.b, ws["A2"].font.b, ws.freeze_panes)
print(ws["A4"].value, ws["A4"].font.b)
w = ws.column_dimensions["A"].width
print(w is not None and w >= 8)
EOF
[ "$(cat "$T/x3.txt")" = "True True False A2
합계 True
True" ] && pass header-freeze-width-bold || bad header-freeze-width-bold "$(tr '\n' '/' < "$T/x3.txt")"

# X4. 시트 이름: 금지 문자 []:*?/\ → _, 31자 자르기, 중복은 ' (2)', 제목 없는 표는 시트N(N=몇 번째 시트인지)
cat > "$T/names.md" <<'MD'
## 1/4분기:실적
| a |
| --- |
| 1 |

## 1/4분기:실적
| a |
| --- |
| 2 |

## 아주아주아주아주아주아주아주긴시트이름입니다정말로깁니다그래서잘라야합니다
| a |
| --- |
| 3 |

| b |
| --- |
| 4 |
MD
"$W" from-md "$T/names.md" "$T/names.xlsx" > "$T/x4.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/names.xlsx" > "$T/x4b.txt" 2>&1 <<'EOF'
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1])
print("|".join(wb.sheetnames)); print(max(len(n) for n in wb.sheetnames) <= 31)
EOF
n=$(head -1 "$T/x4b.txt")
case "$n" in "1_4분기_실적|1_4분기_실적 (2)|"*"|시트4") [ "$(sed -n 2p "$T/x4b.txt")" = "True" ] && [ $rc -eq 0 ] && pass sheet-names || bad sheet-names "rc=$rc $n";; *) bad sheet-names "rc=$rc $n";; esac

# X5. 표가 하나도 없으면 한 줄 ERROR, 출력 없음
printf '# 제목만\n본문만 있다\n' > "$T/notable.md"
"$W" from-md "$T/notable.md" "$T/notable.xlsx" > "$T/x5.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(lines "$T/x5.txt")" = "1" ] && grep -q '^ERROR .*표' "$T/x5.txt" && [ ! -e "$T/notable.xlsx" ] && pass no-table || bad no-table "rc=$rc $(first "$T/x5.txt")"

# X6. 위험한 수식(DDE '|', WEBSERVICE·HYPERLINK·CALL 등)은 수식이 아닌 글자로 넣는다
cat > "$T/danger.md" <<'MD'
## 위험
| 입력 | 값 |
| --- | --- |
| dde | =cmd\|' /C calc'!A0 |
| web | =WEBSERVICE("http://example.invalid/") |
| link | =HYPERLINK("http://example.invalid/","x") |
| call | =CALL("kernel32","x") |
| ok | =A2&"!" |
MD
"$W" from-md "$T/danger.md" "$T/danger.xlsx" > "$T/x6.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/danger.xlsx" > "$T/x6b.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print("/".join(f"{ws.cell(r,1).value}:{ws.cell(r,2).data_type}" for r in range(2, ws.max_row + 1)))
EOF
[ $rc -eq 0 ] && grep -q '^OK ' "$T/x6.txt" && [ "$(cat "$T/x6b.txt")" = "dde:s/web:s/link:s/call:s/ok:f" ] && pass dangerous-formula-as-text || bad dangerous-formula-as-text "rc=$rc $(cat "$T/x6b.txt") $(cat "$T/x6.txt" | tr '\n' ' ' | cut -c1-120)"

# X7. read 표시: 천 단위·백분율은 서식대로, 수식은 수식 글자, \| 는 이스케이프, 빈 칸은 빈 칸
"$W" read "$T/types.xlsx" > "$T/x7.txt" 2>&1
grep -qxF '| 천단위 | 1,000 |' "$T/x7.txt" && grep -qxF '| 천단위소수 | 1,234.50 |' "$T/x7.txt" && grep -qxF '| 백분율 | 12% |' "$T/x7.txt" \
  && grep -qxF '| 백분율소수 | 12.5% |' "$T/x7.txt" && grep -qxF '| 소수 | 3.5 |' "$T/x7.txt" && grep -qxF '| 수식 | =SUM(B2:B3) |' "$T/x7.txt" \
  && grep -qxF '| 빈칸 |  |' "$T/x7.txt" && grep -qx '## 종류' "$T/x7.txt" && grep -qxF '| --- | --- |' "$T/x7.txt" && pass read-display || bad read-display "$(sed -n '2,10p' "$T/x7.txt" | tr '\n' '/')"

# X8. 왕복: read 결과로 다시 만든 통합 문서는 시트 이름·칸 값·종류·서식이 같다
for f in out types; do
  "$W" read "$T/$f.xlsx" > "$T/x8-$f.txt" 2>&1; tail -n +2 "$T/x8-$f.txt" > "$T/rt-$f.md"
  "$W" from-md "$T/rt-$f.md" "$T/rt-$f.xlsx" > /dev/null 2>&1
done
dump() { "$PY" -I -W ignore - "$1" <<'EOF'
import sys, openpyxl
for ws in openpyxl.load_workbook(sys.argv[1]):
    print("##", ws.title)
    for row in ws.iter_rows():
        print([(c.value, c.data_type, c.number_format, bool(c.font.b)) for c in row])
EOF
}
if [ "$(dump "$T/out.xlsx")" = "$(dump "$T/rt-out.xlsx")" ] && [ "$(dump "$T/types.xlsx")" = "$(dump "$T/rt-types.xlsx")" ]; then pass roundtrip; else bad roundtrip "$(diff <(dump "$T/types.xlsx") <(dump "$T/rt-types.xlsx") | head -4 | tr '\n' '/')"; fi

# X9. Excel 로 만든 듯한 외부 파일(날짜·병합·빈 시트·수식 캐시 없음)도 내부 오류 없이 읽는다
"$PY" -I -W ignore - "$T/ext.xlsx" <<'EOF'
import sys, datetime, openpyxl
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "자료"
ws["A1"] = "날짜"; ws["B1"] = "값"
ws["A2"] = datetime.datetime(2026, 11, 10); ws["B2"] = 1.0
ws.merge_cells("A3:B3"); ws["A3"] = "병합"
wb.create_sheet("빈 시트")
wb.save(sys.argv[1])
EOF
"$W" read "$T/ext.xlsx" > "$T/x9.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '2026-11-10' "$T/x9.txt" && grep -q '병합' "$T/x9.txt" && grep -qx '## 빈 시트' "$T/x9.txt" && ! grep -q '00:00:00' "$T/x9.txt" && pass read-foreign-xlsx || bad read-foreign-xlsx "rc=$rc $(sed -n '1,8p' "$T/x9.txt" | tr '\n' '/')"

# X10. 칸 하나가 XFD1048576 에 있는 성긴 시트: 쓰인 범위만큼 칸을 만들지 않고, 일부만 보인다고 알린다
"$PY" -I -W ignore - "$T/sparse.xlsx" <<'EOF'
import sys, openpyxl
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "성긴"
ws["A1"] = "머리"; ws["B1"] = "값"; ws["A2"] = "가"; ws["B2"] = 1; ws["XFD1048576"] = "끝"
wb.save(sys.argv[1])
EOF
limited 60 "$W" read "$T/sparse.xlsx" > "$T/x10.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/x10.txt")" = "OK $T/sparse.xlsx" ] && grep -q '머리' "$T/x10.txt" && grep -q '일부만' "$T/x10.txt" && pass read-sparse-far-cell || bad read-sparse-far-cell "rc=$rc $(head -3 "$T/x10.txt" | tr '\n' '/')"

# X11. 너무 넓거나 큰 표: 16384열 초과, 칸 합계 100만 초과면 만들기 전에 한 줄 ERROR, 출력 없음(빨리 끝남)
wide_table_md "$T/wide.md" 20000 1
limited 60 "$W" from-md "$T/wide.md" "$T/wide.xlsx" > "$T/x11.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ $rc -ne 142 ] && [ "$(lines "$T/x11.txt")" = "1" ] && grep -q '^ERROR ' "$T/x11.txt" && [ ! -e "$T/wide.xlsx" ] && pass table-too-wide || bad table-too-wide "rc=$rc $(first "$T/x11.txt")"
wide_table_md "$T/many.md" 1000 1001
limited 60 "$W" from-md "$T/many.md" "$T/many.xlsx" > "$T/x11b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ $rc -ne 142 ] && [ "$(lines "$T/x11b.txt")" = "1" ] && grep -q '^ERROR ' "$T/x11b.txt" && [ ! -e "$T/many.xlsx" ] && pass table-too-many-cells || bad table-too-many-cells "rc=$rc $(first "$T/x11b.txt")"

# X12. 천 단위·백분율도 유효 숫자 15자리를 넘으면 글자, 터무니없이 큰 백분율이 inf 가 되지 않는다
cat > "$T/big-num.md" <<'MD'
## 큰 수
| 입력 | 값 |
| --- | --- |
| 천단위16자리 | 1,234,567,890,123,456 |
| 천단위소수 | 123,456,789,012,345.67 |
| 백분율16자리 | 1234567890123456% |
| 큰백분율 | 99999999999999999999999% |
| 보통천단위 | 1,000 |
| 보통백분율 | 12.5% |
MD
"$W" from-md "$T/big-num.md" "$T/big-num.xlsx" > /dev/null 2>&1
"$PY" -I -W ignore - "$T/big-num.xlsx" > "$T/x12.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
for r in range(2, ws.max_row + 1):
    c = ws.cell(r, 2); print(ws.cell(r, 1).value, c.data_type, repr(c.value))
EOF
[ "$(cut -d' ' -f1,2 "$T/x12.txt" | tr '\n' '/')" = "천단위16자리 s/천단위소수 s/백분율16자리 s/큰백분율 s/보통천단위 n/보통백분율 n/" ] && ! grep -q 'inf' "$T/x12.txt" && pass number-precision-all-forms || bad number-precision-all-forms "$(tr '\n' '/' < "$T/x12.txt")"

# X13. 시트 이름 앞뒤의 작은따옴표는 Excel 이 거부하므로 떼어 낸다
printf "## '예산'\n| a | b |\n| --- | --- |\n| 1 | 2 |\n" > "$T/quote.md"
"$W" from-md "$T/quote.md" "$T/quote.xlsx" > "$T/x13.txt" 2>&1
"$PY" -I -W ignore -c 'import sys, openpyxl; print(openpyxl.load_workbook(sys.argv[1]).sheetnames)' "$T/quote.xlsx" > "$T/x13b.txt" 2>&1
[ "$(cat "$T/x13b.txt")" = "['예산']" ] && pass sheet-name-apostrophe || bad sheet-name-apostrophe "$(first "$T/x13.txt") $(cat "$T/x13b.txt")"

# X14. UTF-8 BOM 으로 시작하는 md: 첫 제목이 BOM 에 가려지지 않는다
printf '\xef\xbb\xbf## 표지\n| a | b |\n| --- | --- |\n| 1 | 2 |\n' > "$T/bom.md"
"$W" from-md "$T/bom.md" "$T/bom.xlsx" > "$T/x14.txt" 2>&1
"$PY" -I -W ignore -c 'import sys, openpyxl; print(openpyxl.load_workbook(sys.argv[1]).sheetnames)' "$T/bom.xlsx" > "$T/x14b.txt" 2>&1
[ "$(cat "$T/x14b.txt")" = "['표지']" ] && pass utf8-bom || bad utf8-bom "$(first "$T/x14.txt") $(cat "$T/x14b.txt")"

# X15. 칸 안 줄바꿈(Alt+Enter)은 read 에서 한 칸 한 줄로 펴서 표가 깨지지 않고, 왕복해도 행이 사라지지 않는다
"$PY" -I -W ignore - "$T/nl.xlsx" <<'EOF'
import sys, openpyxl
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "줄"
ws.append(["항목", "금액\n(원)"]); ws.append(["인건비", "1차\n2차"]); ws.append(["운영비", "가\r\n나"]); ws.append(["합", 500])
wb.save(sys.argv[1])
EOF
"$W" read "$T/nl.xlsx" > "$T/x15.txt" 2>&1
tail -n +2 "$T/x15.txt" > "$T/nl.md"
"$W" from-md "$T/nl.md" "$T/nl2.xlsx" > /dev/null 2>&1
"$PY" -I -W ignore -c 'import sys, openpyxl; ws = openpyxl.load_workbook(sys.argv[1]).active; print(ws.max_row, [c.value for c in ws["A"]])' "$T/nl2.xlsx" > "$T/x15b.txt" 2>&1
grep -qF '| 항목 | 금액 (원) |' "$T/x15.txt" && grep -qF '| 인건비 | 1차 2차 |' "$T/x15.txt" && grep -qF '| 운영비 | 가 나 |' "$T/x15.txt" \
  && [ "$(cat "$T/x15b.txt")" = "4 ['항목', '인건비', '운영비', '합']" ] && pass multiline-cell || bad multiline-cell "$(tr '\n' '/' < "$T/x15.txt") :: $(cat "$T/x15b.txt")"

# X16. 배열 수식(Excel 365 동적 배열)은 수식 글자로, <v>inf</v> 같은 비정상 숫자도 내부 오류 없이 읽는다
"$PY" -I -W ignore - "$T/arr.xlsx" <<'EOF'
import sys, zipfile, openpyxl
from openpyxl.worksheet.formula import ArrayFormula
p = sys.argv[1]
wb = openpyxl.Workbook(); ws = wb.active
ws["A1"] = "값"; ws["B1"] = "정렬"; ws["A2"] = 1.5; ws["B2"] = ArrayFormula("B2:B3", "=SORT(A2:A3)")
wb.save(p)
with zipfile.ZipFile(p) as z: items = [(i, z.read(i.filename)) for i in z.infolist()]
with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z:
    for i, data in items:
        if i.filename == "xl/worksheets/sheet1.xml":
            data = data.replace(b"<v>1.5</v>", b"<v>inf</v>")
        z.writestr(i, data)
EOF
"$W" read "$T/arr.xlsx" > "$T/x16.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -qF '=SORT(A2:A3)' "$T/x16.txt" && ! grep -q 'object at' "$T/x16.txt" && pass read-array-formula-inf || bad read-array-formula-inf "rc=$rc $(tr '\n' '/' < "$T/x16.txt")"

# X17. 천 단위 소수 자릿수 보존(1,234.567), 1000% 이상 백분율에 쉼표를 넣지 않아 왕복해도 숫자로 남는다
printf '## 정밀\n| 입력 | 값 |\n| --- | --- |\n| 세자리 | 1,234.567 |\n| 한자리 | 1,234.5 |\n| 큰백분율 | 1200%% |\n' > "$T/prec.md"
"$W" from-md "$T/prec.md" "$T/prec.xlsx" > /dev/null 2>&1
"$W" read "$T/prec.xlsx" > "$T/x17.txt" 2>&1
tail -n +2 "$T/x17.txt" > "$T/prec2.md"
"$W" from-md "$T/prec2.md" "$T/prec2.xlsx" > /dev/null 2>&1
"$PY" -I -W ignore -c 'import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print(" ".join(f"{ws.cell(r, 2).data_type}:{ws.cell(r, 2).value}" for r in range(2, 5)))' "$T/prec2.xlsx" > "$T/x17b.txt" 2>&1
grep -qF '| 세자리 | 1,234.567 |' "$T/x17.txt" && grep -qF '| 한자리 | 1,234.5 |' "$T/x17.txt" && grep -qF '| 큰백분율 | 1200% |' "$T/x17.txt" \
  && [ "$(cat "$T/x17b.txt")" = "n:1234.567 n:1234.5 n:12" ] && pass comma-decimals-big-percent || bad comma-decimals-big-percent "$(tr '\n' '/' < "$T/x17.txt") :: $(cat "$T/x17b.txt")"

# X18. Excel 예약 이름 History, 작은따옴표만 있는 제목은 시트N 으로
printf "## History\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n## '''\n| a | b |\n| --- | --- |\n| 1 | 2 |\n" > "$T/resv.md"
"$W" from-md "$T/resv.md" "$T/resv.xlsx" > "$T/x18.txt" 2>&1
"$PY" -I -W ignore -c 'import sys, openpyxl; print(openpyxl.load_workbook(sys.argv[1]).sheetnames)' "$T/resv.xlsx" > "$T/x18b.txt" 2>&1
[ "$(cat "$T/x18b.txt")" = "['시트1', '시트2']" ] && pass sheet-name-reserved || bad sheet-name-reserved "$(first "$T/x18.txt") $(cat "$T/x18b.txt")"

# X19. 위험 수식: RTD·SQL.REQUEST·외부 통합 문서/UNC/URL 참조는 글자로, 이름 일부에 CALL/EXEC 가 든 수식은 수식으로
cat > "$T/inj2.md" <<'MD'
## 수식
| 입력 | 값 |
| --- | --- |
| rtd | =RTD("prog",,"topic") |
| sql | =SQL.REQUEST("dsn") |
| unc | ='\\srv\share\[a.xlsx]S'!A1 |
| ext | =[1]Sheet1!A1 |
| url | ='https://x.test/[b.xlsx]S'!A1 |
| recall | =SUM(RECALL_TOTAL) |
| exec | =EXECUTIVE!A1 |
| sum | =SUM(1,2) |
MD
"$W" from-md "$T/inj2.md" "$T/inj2.xlsx" > "$T/x19.txt" 2>&1
"$PY" -I -W ignore -c 'import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print(" ".join(f"{ws.cell(r, 1).value}:{ws.cell(r, 2).data_type}" for r in range(2, ws.max_row + 1)))' "$T/inj2.xlsx" > "$T/x19b.txt" 2>&1
[ "$(cat "$T/x19b.txt")" = "rtd:s sql:s unc:s ext:s url:s recall:f exec:f sum:f" ] && [ "$(grep -c '^경고 ' "$T/x19.txt")" = "5" ] && pass formula-injection-more || bad formula-injection-more "$(cat "$T/x19b.txt") :: $(tr '\n' '/' < "$T/x19.txt")"

# X20. 서식만 있고 값이 없는 칸(A1 굵게 등)이 표시 창을 차지해도: 값이 있는 칸을 기준으로 보여 주고 내부 오류가 없다
"$PY" -I -W ignore - "$T/styled.xlsx" <<'EOF'
import sys, openpyxl
from openpyxl.styles import Font, PatternFill
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "아래"
ws["A1"].font = Font(bold=True); ws["A300"] = "끝값"
ws2 = wb.create_sheet("오른쪽"); ws2["A1"].fill = PatternFill("solid", fgColor="FFFF00"); ws2["BA1"] = "오른쪽값"
wb.save(sys.argv[1])
EOF
"$W" read "$T/styled.xlsx" > "$T/x20.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '끝값' "$T/x20.txt" && grep -q '오른쪽값' "$T/x20.txt" && ! grep -q '내부 오류' "$T/x20.txt" \
  && pass read-style-only-cells || bad read-style-only-cells "rc=$rc $(first "$T/x20.txt")"

# X21. 값이 대각선 반대쪽에 떨어져 있어도(CV1 과 A300 — 첫 행의 값은 50열 밖, 첫 열의 값은 200행 밖):
#      내부 오류 없이 창 안의 값을 보여 주고 (일부만 표시 …) 로 잘림을 알린다
"$PY" -I -W ignore - "$T/diag.xlsx" <<'EOF'
import sys, openpyxl
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "대각"
ws.cell(row=1, column=100, value="오른쪽위"); ws.cell(row=300, column=1, value="왼쪽아래")
wb.save(sys.argv[1])
EOF
"$W" read "$T/diag.xlsx" > "$T/x21.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '오른쪽위' "$T/x21.txt" && grep -q '일부만 표시' "$T/x21.txt" && ! grep -q '내부 오류' "$T/x21.txt" \
  && pass read-diagonal-values || bad read-diagonal-values "rc=$rc $(first "$T/x21.txt")"

# ── 혼합안(anthropics/skills 지침 반영) ─────────────────────────────────────────
# X22. 글꼴 통일: 쓴 칸은 머리 행까지 모두 '맑은 고딕', 머리 행만 굵게
cat > "$T/q1.md" <<'MD'
## 예산
| 부서 | 1월 | 2월 | 3월 | 합계 | 비율 |
| --- | --- | --- | --- | --- | --- |
| 기획 | 1,000 | 1,200 | 1,100 | =SUM(B2:D2) | =E2/E5 |
| 개발 | 2,500 | 2,600 | 2,700 | =SUM(B3:D3) | =E3/E5 |
| 영업 | 1,800 | 1,900 | 2,000 | =B4+C4+D4 | =E4/E5 |
| 합계 | =SUM(B2:B4) | =SUM(C2:C4) | =SUM(D2:D4) | =SUM(E2:E4) | |

## 비율
| 항목 | 비율 | 다른시트 |
| --- | --- | --- |
| 가 | 12% | =SUM(예산!B2:B4) |
| 나 | 13% | 1,000 |
| 평균 | =AVERAGE(B2:B3) | =MAX(C2:C3) |
MD
"$W" from-md "$T/q1.md" "$T/q1.xlsx" > "$T/x22o.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/q1.xlsx" > "$T/x22.txt" 2>&1 <<'EOF'
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1])
names, bold_hdr, bold_data = set(), [], []
for ws in wb:
    for row in ws.iter_rows():
        for c in row:
            if c.value is None: continue
            names.add(c.font.name)
            (bold_hdr if c.row == 1 else bold_data).append(bool(c.font.b))
print(sorted(names, key=str), all(bold_hdr), any(bold_data))
EOF
[ $rc -eq 0 ] && [ "$(cat "$T/x22.txt")" = "['맑은 고딕'] True False" ] && pass consistent-font || bad consistent-font "rc=$rc $(cat "$T/x22.txt")"

# X23. 수식 칸 표시 형식: 합·평균·최소·최대(SUM/AVERAGE/MIN/MAX)와 칸끼리 더하고 빼는 수식은
#      수식 안 첫 칸(같은 시트)의 형식을 따른다(수식이 수식을 가리켜도 이어서). 나누기 등 그 밖의 수식,
#      다른 시트를 가리키는 수식은 General 로 둔다(비율이 #,##0 으로 0 처럼 보이면 안 됨).
"$PY" -I -W ignore - "$T/q1.xlsx" > "$T/x23.txt" 2>&1 <<'EOF'
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1])
a, b = wb["예산"], wb["비율"]
print(" ".join(f"{k}={a[k].number_format}" for k in ("B5", "C5", "D5", "E2", "E3", "E4", "E5", "F2", "F4")))
print(" ".join(f"{k}={b[k].number_format}" for k in ("B4", "C2", "C4")))
EOF
[ "$(sed -n 1p "$T/x23.txt")" = "B5=#,##0 C5=#,##0 D5=#,##0 E2=#,##0 E3=#,##0 E4=#,##0 E5=#,##0 F2=General F4=General" ] \
  && [ "$(sed -n 2p "$T/x23.txt")" = "B4=0% C2=General C4=#,##0" ] && pass formula-number-format || bad formula-number-format "$(tr '\n' '/' < "$T/x23.txt")"

# X24. 왕복: 수식 형식을 물려받은 통합 문서도 read → from-md 로 같은 값·종류·형식이 된다
"$W" read "$T/q1.xlsx" > "$T/x24.txt" 2>&1; tail -n +2 "$T/x24.txt" > "$T/q1rt.md"
"$W" from-md "$T/q1rt.md" "$T/q1rt.xlsx" > /dev/null 2>&1
if [ "$(dump "$T/q1.xlsx")" = "$(dump "$T/q1rt.xlsx")" ]; then pass roundtrip-formula-format; else bad roundtrip-formula-format "$(diff <(dump "$T/q1.xlsx") <(dump "$T/q1rt.xlsx") | head -4 | tr '\n' '/')"; fi

# X25. 자리 표시 경고: [ ]·TODO·lorem 등이 남으면 OK 다음 줄에 '경고 자리 표시' 한 줄(파일은 만들고 rc 0).
#      깨끗한 입력에는 경고가 없다.
printf '## 명단\n| 이름 | 메모 |\n| --- | --- |\n| [ ] | TODO 확인 |\n| 홍길동 | Lorem ipsum |\n' > "$T/ph.md"
"$W" from-md "$T/ph.md" "$T/ph.xlsx" > "$T/x25.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/x25.txt")" = "OK $T/ph.xlsx" ] && [ -f "$T/ph.xlsx" ] \
  && [ "$(grep -c '^경고 자리 표시' "$T/x25.txt")" = "1" ] && grep '^경고 자리 표시' "$T/x25.txt" | grep -qF '[ ]' \
  && grep '^경고 자리 표시' "$T/x25.txt" | grep -qF 'TODO' && ! grep -q '^경고' "$T/x22o.txt" \
  && pass placeholder-warning || bad placeholder-warning "rc=$rc $(tr '\n' '/' < "$T/x25.txt") | clean: $(grep '^경고' "$T/x22o.txt" | tr '\n' '/')"

# X26. 옛 엑셀에 없는 함수(XLOOKUP·FILTER·TEXTJOIN 등)는 수식으로 넣되 칸 주소와 함께 경고한다.
#      따옴표 안 글자("SORT(")는 함수로 보지 않는다. 경고가 있어도 첫 줄은 OK, rc 0.
printf '## 찾기\n| 키 | 값 |\n| --- | --- |\n| 가 | =XLOOKUP(A2,A3:A4,B3:B4) |\n| 나 | =IF(A3="SORT(",1,0) |\n| 다 | =TEXTJOIN(",",TRUE,A2:A3) |\n' > "$T/fn.md"
"$W" from-md "$T/fn.md" "$T/fn.xlsx" > "$T/x26.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/fn.xlsx" > "$T/x26b.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print(ws["B2"].data_type, ws["B3"].data_type, ws["B4"].data_type)
EOF
[ $rc -eq 0 ] && [ "$(first "$T/x26.txt")" = "OK $T/fn.xlsx" ] && [ "$(cat "$T/x26b.txt")" = "f f f" ] \
  && grep '^경고' "$T/x26.txt" | grep 'XLOOKUP' | grep -q 'B2' && grep '^경고' "$T/x26.txt" | grep 'TEXTJOIN' | grep -q 'B4' \
  && ! grep '^경고' "$T/x26.txt" | grep -q 'B3' && pass newer-function-warning || bad newer-function-warning "rc=$rc $(tr '\n' '/' < "$T/x26.txt") $(cat "$T/x26b.txt")"

# X27. 열 전체(A:A)·행 전체(1:1048576) 범위는 1만 칸을 넘는 범위로 보고 표시 형식을 물려주지 않는다.
printf '## 열\n| 가 | 나 |\n| --- | --- |\n| 1 | 25%% |\n| 합 | =SUM(A:A,B2) |\n| 합2 | =SUM(1:1048576,B2) |\n| 합3 | =SUM(B2:B2) |\n' > "$T/wc.md"
"$W" from-md "$T/wc.md" "$T/wc.xlsx" > "$T/x27.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/wc.xlsx" > "$T/x27b.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print(ws["B3"].number_format, ws["B4"].number_format, ws["B5"].number_format)
EOF
[ $rc -eq 0 ] && [ "$(cat "$T/x27b.txt")" = "General General 0%" ] && pass whole-column-range-no-format \
  || bad whole-column-range-no-format "rc=$rc $(cat "$T/x27b.txt") $(tr '\n' '/' < "$T/x27.txt")"

# X28. 큰 범위를 여러 번 쓴 수식(A1:A10000 x 3000)도 메모리를 크게 쓰지 않고 60초 안에 끝난다(최대 RSS 400MB 미만).
"$PY" -I -c 'print("## 큰\n| 가 |\n| --- |\n| =SUM(" + ",".join(["A1:A10000"] * 3000) + ") |")' > "$T/bigr.md"
"$PY" -I -W ignore - "$W" "$T/bigr.md" "$T/bigr.xlsx" > "$T/x28.txt" 2>&1 <<'EOF'
import resource, subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=60)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
mb = rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024
print(r.returncode, r.stdout.splitlines()[0] if r.stdout else "-", "BIG" if mb >= 400 else "SMALL", int(mb))
EOF
case "$(cat "$T/x28.txt")" in "0 OK $T/bigr.xlsx SMALL "*) pass big-range-memory;; *) bad big-range-memory "$(cat "$T/x28.txt")";; esac

# X29. 서로 다른 자리 표시가 아주 많아도(20만 개, 2MB) 30초 안에 끝나고 경고에는 5개만 나온다.
"$PY" -I -c '
print("## 많음\n| 메모 |\n| --- |")
for r in range(4000):
    print("| " + " ".join("[입력 %d]" % (r * 50 + i) for i in range(50)) + " |")' > "$T/manyph.md"
"$PY" -I -W ignore - "$W" "$T/manyph.md" "$T/manyph.xlsx" > "$T/x29.txt" 2>&1 <<'EOF'
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
w = [l for l in r.stdout.splitlines() if l.startswith("경고 자리 표시")]
print(r.returncode, len(w), w[0].count("[입력 ") if w else 0)
EOF
[ "$(cat "$T/x29.txt")" = "0 1 5" ] && pass many-placeholders-fast || bad many-placeholders-fast "$(cat "$T/x29.txt")"

# X30. 콜론 앞뒤 공백(A : A, 1 : 1048576)도 열·행 전체로 보아 형식을 물려주지 않는다. B2 : B2 는 B2:B2 와 같이 물려받고,
#      공백 교집합(B2 B2)처럼 해석할 수 없는 참조는 General 로 둔다.
printf '## 공백\n| 가 | 나 |\n| --- | --- |\n| 1 | 25%% |\n| 합 | =SUM(A : A,B2) |\n| 합2 | =SUM(1 : 1048576,B2) |\n| 합3 | =SUM(B2 : B2) |\n| 합4 | =SUM(B2 B2) |\n' > "$T/sp.md"
"$W" from-md "$T/sp.md" "$T/sp.xlsx" > "$T/x30.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/sp.xlsx" > "$T/x30b.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print(ws["B3"].number_format, ws["B4"].number_format, ws["B5"].number_format, ws["B6"].number_format)
EOF
[ $rc -eq 0 ] && [ "$(cat "$T/x30b.txt")" = "General General 0% General" ] && pass spaced-range-colon \
  || bad spaced-range-colon "rc=$rc $(cat "$T/x30b.txt") $(tr '\n' '/' < "$T/x30.txt")"


# X31. 자유 형식 대괄호 자리 표시도 경고한다: 채울 값의 이름(금액·이름·날짜 등)으로 끝나는 대괄호,
#      업무·목표·항목 등 뒤에 번호가 붙은 대괄호. 경고는 한 줄, 파일은 만들고 rc 0.
printf '## 예산\n| 부서 | 1월 | 메모 |\n| --- | --- | --- |\n| 기획 | [기획 1월 금액] | [이번 주 완료한 업무 2] |\n| [목표 1] | [담당자 이름] | [시작 날짜] |\n' > "$T/ffph.md"
"$W" from-md "$T/ffph.md" "$T/ffph.xlsx" > "$T/x31.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/x31.txt")"; ok=1
for tok in '[이번 주 완료한 업무 2]' '[목표 1]' '[기획 1월 금액]' '[담당자 이름]' '[시작 날짜]'; do printf '%s' "$w" | grep -qF "$tok" || ok=0; done
[ $rc -eq 0 ] && [ "$(first "$T/x31.txt")" = "OK $T/ffph.xlsx" ] && [ "$(grep -c '^경고 자리 표시' "$T/x31.txt")" = "1" ] && [ $ok -eq 1 ] \
  && pass freeform-placeholder-warning || bad freeform-placeholder-warning "rc=$rc $(tr '\n' '/' < "$T/x31.txt")"

# X32. 문서에 흔한 대괄호 글은 자리 표시가 아니다: 참고·별첨 번호, [단위: 원], 번호 없는 소제목([주요 업무]·[추진 목표]),
#      마크다운 링크 글자([담당자 이름](mailto:…)).
printf '## 메모\n| 구분 | 메모 |\n| --- | --- |\n| [참고 1] | 관련 법령 |\n| [별첨 2] | [단위: 원] |\n| [주요 업무] | [추진 목표] |\n| 문의 | [담당자 이름](mailto:a@example.com) |\n' > "$T/ffok.md"
"$W" from-md "$T/ffok.md" "$T/ffok.xlsx" > "$T/x32.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/x32.txt")" = "OK $T/ffok.xlsx" ] && ! grep -q '^경고 자리 표시' "$T/x32.txt" \
  && pass freeform-placeholder-no-false-positive || bad freeform-placeholder-no-false-positive "rc=$rc $(tr '\n' '/' < "$T/x32.txt")"


# X33. 대괄호 뒤 공백이 아주 길어도(20만 칸) 자리 표시 검사가 30초 안에 끝난다(역추적 폭주 없음).
"$PY" -I -c 'print("## 메모\n| 메모 |\n| --- |\n| " + "[이름" + " " * 200000 + "! |")' > "$T/ffsp.md"
"$PY" -I -W ignore - "$W" "$T/ffsp.md" "$T/ffsp.xlsx" > "$T/x33.txt" 2>&1 <<'EOF'
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
print(r.returncode, r.stdout.splitlines()[0][:2] if r.stdout else "-")
EOF
[ "$(cat "$T/x33.txt")" = "0 OK" ] && pass freeform-placeholder-spaces-fast || bad freeform-placeholder-spaces-fast "$(cat "$T/x33.txt")"

# X34. 이름 대신 쓰는 말(회사명·성함·종료일 등)로 끝나는 대괄호도 자리 표시로 경고한다.
printf '## 메모\n| 구분 | 값 |\n| --- | --- |\n| 회사 | [회사명] |\n| 연락 | [담당자 성함] |\n| 끝 | [종료일] |\n' > "$T/ffmore.md"
"$W" from-md "$T/ffmore.md" "$T/ffmore.xlsx" > "$T/x34.txt" 2>&1; rc=$?
w="$(grep '^경고 자리 표시' "$T/x34.txt")"; ok=1
for tok in '[회사명]' '[담당자 성함]' '[종료일]'; do printf '%s' "$w" | grep -qF "$tok" || ok=0; done
[ $rc -eq 0 ] && [ "$(grep -c '^경고 자리 표시' "$T/x34.txt")" = "1" ] && [ $ok -eq 1 ] \
  && pass freeform-placeholder-more-nouns || bad freeform-placeholder-more-nouns "rc=$rc $(tr '\n' '/' < "$T/x34.txt")"

# X35. 쌍점이 든 대괄호(참고·별첨 설명)와 참조식 링크 글자([담당자 이름][contact])는 자리 표시가 아니다.
printf '## 메모\n| 구분 | 값 |\n| --- | --- |\n| [참고: 도로명주소] | [별첨 2: 담당자 연락처] |\n| 문의 | [담당자 이름][contact] |\n' > "$T/ffcolon.md"
"$W" from-md "$T/ffcolon.md" "$T/ffcolon.xlsx" > "$T/x35.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/x35.txt")" = "OK $T/ffcolon.xlsx" ] && ! grep -q '^경고 자리 표시' "$T/x35.txt" \
  && pass freeform-placeholder-colon-reflink || bad freeform-placeholder-colon-reflink "rc=$rc $(tr '\n' '/' < "$T/x35.txt")"

# X36. 깨진 수식(생략 부호 ...·…, 괄호 짝 안 맞음, 닫히지 않은 문자열, 끝에 남은 연산자, = 하나)은 엑셀이 열 때
#      '복구' 창을 띄우고 수식을 지우므로 글자로 넣고, 경고 한 줄로 칸 주소(최대 5개 + 외 N칸)와 첫 수식 예를 알린다.
#      rc 는 0, 파일은 만든다(경고는 결과를 바꾸지 않는다). **…** 굵게 감싼 수식도 같다.
cat > "$T/badf.md" <<'MD'
## 표
| 이름 | 값 |
| --- | --- |
| a | 1 |
| ell | =SUM(...) |
| uell | =SUM(B2…B3) |
| open | =SUM(B2:B3 |
| close | =SUM(B2:B3)) |
| quote | ="abc |
| trail | =B2+ |
| lone | = |
| bold | **=SUM(...)** |
MD
"$W" from-md "$T/badf.md" "$T/badf.xlsx" > "$T/x36.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/badf.xlsx" > "$T/x36b.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print(" ".join(f"{ws.cell(r, 1).value}:{ws.cell(r, 2).data_type}:{ws.cell(r, 2).value}" for r in range(3, ws.max_row + 1)))
EOF
w="$(grep '^경고 깨진 수식' "$T/x36.txt")"
[ $rc -eq 0 ] && [ "$(first "$T/x36.txt")" = "OK $T/badf.xlsx" ] && [ "$(grep -c '^경고 깨진 수식' "$T/x36.txt")" = "1" ] \
  && ! grep -q '^경고 위험한 수식' "$T/x36.txt" \
  && printf '%s' "$w" | grep -qF 'B3, B4, B5, B6, B7 외 3칸' && printf '%s' "$w" | grep -qF '=SUM(...)' \
  && [ "$(cat "$T/x36b.txt")" = "ell:s:=SUM(...) uell:s:=SUM(B2…B3) open:s:=SUM(B2:B3 close:s:=SUM(B2:B3)) quote:s:=\"abc trail:s:=B2+ lone:s:= bold:s:=SUM(...)" ] \
  && pass broken-formula-as-text || bad broken-formula-as-text "rc=$rc $(cat "$T/x36b.txt") | $(tr '\n' '/' < "$T/x36.txt")"

# X37. 바른 수식은 그대로 수식이다: 문자열 안 괄호·생략 부호, 겹 따옴표(""), 인수 없는 함수, 단항 음수, 뒤붙이 %,
#      빈 인수(IF(B2,,1)), 작은따옴표로 감싼 시트 이름 안 괄호('합계(원)'!B2). 경고 없음.
cat > "$T/goodf.md" <<'MD'
## 표
| 이름 | 값 |
| --- | --- |
| a | 1 |
| b | 2 |
| sum | =SUM(B2:B3) |
| str | =IF(B2>0,"(열림",")") |
| dots | =IF(B2>0,"...","…") |
| esc | ="a""b" |
| today | =TODAY() |
| neg | =-B2*-1 |
| pct | =B2% |
| emptyarg | =IF(B2,,1) |
| sheet | ='합계(원)'!B2 |

## 합계(원)
| 이름 | 값 |
| --- | --- |
| x | 5 |
MD
"$W" from-md "$T/goodf.md" "$T/goodf.xlsx" > "$T/x37.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/goodf.xlsx" > "$T/x37b.txt" 2>&1 <<'EOF'
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1]); ws = wb["표"]
print("/".join(wb.sheetnames), " ".join(f"{ws.cell(r, 1).value}:{ws.cell(r, 2).data_type}" for r in range(4, ws.max_row + 1)))
EOF
[ $rc -eq 0 ] && [ "$(first "$T/x37.txt")" = "OK $T/goodf.xlsx" ] && ! grep -q '^경고' "$T/x37.txt" \
  && [ "$(cat "$T/x37b.txt")" = "표/합계(원) sum:f str:f dots:f esc:f today:f neg:f pct:f emptyarg:f sheet:f" ] \
  && pass valid-formula-kept || bad valid-formula-kept "rc=$rc $(cat "$T/x37b.txt") | $(tr '\n' '/' < "$T/x37.txt")"

# X38. 아주 긴 수식(괄호 10만 겹, 닫히지 않은 문자열 속 겹 따옴표 10만 쌍)도 수식 검사가 30초 안에 끝난다.
#      괄호 짝이 맞는 쪽은 수식으로 두고, 문자열이 닫히지 않은 쪽만 깨진 수식으로 경고한다(경고 한 줄).
"$PY" -I -c 'print("## 긴\n| 이름 | 값 |\n| --- | --- |\n| p | =" + "(" * 100000 + "1" + ")" * 100000 + " |\n| q | =\"" + "\"\"" * 100000 + " |")' > "$T/longf.md"
"$PY" -I -W ignore - "$W" "$T/longf.md" "$T/longf.xlsx" > "$T/x38.txt" 2>&1 <<'EOF'
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1], "from-md", sys.argv[2], sys.argv[3]], capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    print("TIMEOUT"); sys.exit(0)
lines = r.stdout.splitlines()
print(r.returncode, lines[0][:2] if lines else "-", sum(1 for l in lines if l.startswith("경고 깨진 수식")),
      next((l.split(":")[1].split()[0] for l in lines if l.startswith("경고 깨진 수식")), "-"))
EOF
[ "$(cat "$T/x38.txt")" = "0 OK 1 B3" ] && pass broken-formula-long-fast || bad broken-formula-long-fast "$(cat "$T/x38.txt")"

# X39. 더 깨진 수식(codex 검토): 배열 상수 밖의 ; , 짝 안 맞는 { }, 끝에 남은 : , 이항 연산자 * / ^ 가 연산자·여는 괄호·
#      맨 앞 바로 뒤에 오는 경우(+ * , =*B2), 칸 주소 사이 생략 부호(B2...B2)도 글자로 넣고 경고 한 줄.
cat > "$T/badf2.md" <<'MD'
## 표
| 이름 | 값 |
| --- | --- |
| a | 1 |
| semi | =SUM(B2;B2) |
| trailsemi | =SUM(B2:B2); |
| ops | =SUM(B2:B2) + * 2 |
| arr | =SUM({1,2;3,4) |
| colon | =SUM(B2:B2): |
| lead | =*B2 |
| dots3 | =SUM(B2...B2) |
| brace | =SUM(1,2}) |
MD
"$W" from-md "$T/badf2.md" "$T/badf2.xlsx" > "$T/x39.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/badf2.xlsx" > "$T/x39b.txt" 2>&1 <<'EOF'
import sys, openpyxl
ws = openpyxl.load_workbook(sys.argv[1]).active
print(" ".join(f"{ws.cell(r, 1).value}:{ws.cell(r, 2).data_type}" for r in range(3, ws.max_row + 1)))
EOF
w="$(grep '^경고 깨진 수식' "$T/x39.txt")"
[ $rc -eq 0 ] && [ "$(first "$T/x39.txt")" = "OK $T/badf2.xlsx" ] && [ "$(grep -c '^경고 깨진 수식' "$T/x39.txt")" = "1" ] \
  && printf '%s' "$w" | grep -qF 'B3, B4, B5, B6, B7 외 3칸' && printf '%s' "$w" | grep -qF '=SUM(B2;B2)' \
  && [ "$(cat "$T/x39b.txt")" = "semi:s trailsemi:s ops:s arr:s colon:s lead:s dots3:s brace:s" ] \
  && pass broken-formula-more || bad broken-formula-more "rc=$rc $(cat "$T/x39b.txt") | $(tr '\n' '/' < "$T/x39.txt")"

# X40. 바른 수식은 그대로(codex 검토): 배열 상수 안 ; , 연산자 뒤 단항 +·- , 비교 연산자 >= <> <= , % 뒤 곱하기,
#      이름에 ... 이 든 시트를 따옴표 없이 참조(Sales...2026!B2, 스펙상 유효). 경고 없음.
cat > "$T/goodf2.md" <<'MD'
## 표
| 이름 | 값 |
| --- | --- |
| a | 1 |
| arr | =SUM({1,2;3,4}) |
| pow | =2^-1 |
| ge | =B2>=1 |
| ne | =B2<>1 |
| le | =B2<=-1 |
| pctmul | =B2%*2 |
| amp | =B2&-1 |
| plus | =+B2 |
| sheetdots | =Sales...2026!B2 |

## Sales...2026
| 이름 | 값 |
| --- | --- |
| x | 42 |
MD
"$W" from-md "$T/goodf2.md" "$T/goodf2.xlsx" > "$T/x40.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/goodf2.xlsx" > "$T/x40b.txt" 2>&1 <<'EOF'
import sys, openpyxl
wb = openpyxl.load_workbook(sys.argv[1]); ws = wb["표"]
print("/".join(wb.sheetnames), " ".join(f"{ws.cell(r, 1).value}:{ws.cell(r, 2).data_type}" for r in range(3, ws.max_row + 1)))
EOF
[ $rc -eq 0 ] && [ "$(first "$T/x40.txt")" = "OK $T/goodf2.xlsx" ] && ! grep -q '^경고' "$T/x40.txt" \
  && [ "$(cat "$T/x40b.txt")" = "표/Sales...2026 arr:f pow:f ge:f ne:f le:f pctmul:f amp:f plus:f sheetdots:f" ] \
  && pass valid-formula-kept-more || bad valid-formula-kept-more "rc=$rc $(cat "$T/x40b.txt") | $(tr '\n' '/' < "$T/x40.txt")"

finish
