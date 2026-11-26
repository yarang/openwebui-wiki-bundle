#!/bin/bash
# hwpx skill 인수 시험. 사용: CLAUDE_LMS_PY=<python> tests/accept_hwpx.sh
# - CLAUDE_LMS_PY 는 python-hwpx 를 import 할 수 있는 파이썬(배포 시 ~/.guardian-llm/venv/bin/python).
# - 모든 시험이 통과하면 "ACCEPT PASS" 를 출력하고 0 으로 끝난다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
H="$KIT/skills/hwpx/scripts/hwpx"
PY="${CLAUDE_LMS_PY:-$HOME/.guardian-llm/venv/bin/python}"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-hwpx.XXXXXX")"
T="$(cd "$T" && pwd)"   # TMPDIR 끝의 '/' 로 생기는 '//' 제거(도구는 정규화된 경로를 출력)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
first() { head -1 "$1"; }

[ -x "$H" ] || { echo "FAIL wrapper missing or not executable: $H"; exit 1; }

# 1. from-md: 제목·개조식·표·굵게 → OK, 검증 통과, read 로 되읽기
cat > "$T/in.md" <<'MD'
# 추진 보고

□ 추진 배경
ㅇ 문서 작업 **자동화** 필요
- 세부 항목

| 항목 | 값 |
| --- | --- |
| 예산 | 1,000 |
MD
"$H" from-md "$T/in.md" "$T/out.hwpx" > "$T/1.txt" 2>&1; rc=$?
if [ $rc -eq 0 ] && [ "$(first "$T/1.txt")" = "OK $T/out.hwpx" ] && [ -s "$T/out.hwpx" ]; then pass from-md; else bad from-md "rc=$rc $(first "$T/1.txt")"; fi
"$H" validate "$T/out.hwpx" > "$T/1v.txt" 2>&1 && grep -q '^OK ' "$T/1v.txt" && pass validate || bad validate "$(first "$T/1v.txt")"
"$H" read "$T/out.hwpx" > "$T/1r.txt" 2>&1
if grep -q '^OK ' "$T/1r.txt" && grep -q '추진 보고' "$T/1r.txt" && grep -q '예산' "$T/1r.txt" && grep -q '1,000' "$T/1r.txt" && grep -q '자동화' "$T/1r.txt"; then pass read; else bad read "$(head -3 "$T/1r.txt" | tr '\n' ' ')"; fi

# 2. fields / fill: 라벨 표 양식
"$PY" -I - "$T/form.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("신청서")
t = d.add_table(2, 2); t.cell(0, 0).text = "성명"; t.cell(1, 0).text = "연락처"
d.save_to_path(sys.argv[1])
EOF
"$H" fields "$T/form.hwpx" > "$T/2f.txt" 2>&1
grep -q '^OK ' "$T/2f.txt" && grep -q '성명' "$T/2f.txt" && grep -q '연락처' "$T/2f.txt" && pass fields || bad fields "$(head -3 "$T/2f.txt" | tr '\n' ' ')"
printf '{"성명": "홍길동", "연락처": "010-1234-5678"}' > "$T/v.json"
"$H" fill "$T/form.hwpx" "$T/v.json" "$T/filled.hwpx" > "$T/2.txt" 2>&1; rc=$?
"$H" read "$T/filled.hwpx" > "$T/2r.txt" 2>&1
if [ $rc -eq 0 ] && [ "$(first "$T/2.txt")" = "OK $T/filled.hwpx" ] && grep -q '홍길동' "$T/2r.txt" && grep -q '010-1234-5678' "$T/2r.txt"; then pass fill; else bad fill "rc=$rc $(first "$T/2.txt")"; fi
printf '{"없는라벨": "x"}' > "$T/v2.json"
"$H" fill "$T/form.hwpx" "$T/v2.json" "$T/filled2.hwpx" > "$T/2b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/2b.txt" && pass fill-unknown-key || bad fill-unknown-key "rc=$rc $(first "$T/2b.txt")"

# 3. 원본 덮어쓰기 금지: 출력 경로 = 입력 경로
m0=$(stat -f %m "$T/form.hwpx"); s0=$(shasum "$T/form.hwpx")
"$H" fill "$T/form.hwpx" "$T/v.json" "$T/form.hwpx" > "$T/3.txt" 2>&1; rc=$?
if [ $rc -ne 0 ] && grep -q '^ERROR ' "$T/3.txt" && [ "$(shasum "$T/form.hwpx")" = "$s0" ] && [ "$(stat -f %m "$T/form.hwpx")" = "$m0" ]; then pass no-overwrite; else bad no-overwrite "rc=$rc $(first "$T/3.txt")"; fi
cp "$T/out.hwpx" "$T/exists.hwpx"
"$H" from-md "$T/in.md" "$T/exists.hwpx" > "$T/3b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/3b.txt" && pass no-clobber-existing || bad no-clobber-existing "rc=$rc $(first "$T/3b.txt")"

# 4. 가짜 .hwp(OLE 매직만 있는 파일): 트레이스백 없이 ERROR + HWPX 저장 안내
printf '\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1garbage' > "$T/fake.hwp"
"$H" read "$T/fake.hwp" > "$T/4.txt" 2>&1; rc=$?
if [ $rc -ne 0 ] && [ "$(first "$T/4.txt" | cut -c1-6)" = "ERROR " ] && grep -q 'HWPX' "$T/4.txt" && ! grep -q 'Traceback' "$T/4.txt"; then pass fake-hwp; else bad fake-hwp "rc=$rc $(head -2 "$T/4.txt" | tr '\n' ' ')"; fi

# 5. 없는 파일 / 잘못된 명령 / 파이썬 없음
"$H" read "$T/nope.hwpx" > "$T/5.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/5.txt" && ! grep -q Traceback "$T/5.txt" && pass missing-file || bad missing-file "rc=$rc $(first "$T/5.txt")"
"$H" bogus > "$T/5b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/5b.txt" && pass bad-command || bad bad-command "rc=$rc $(first "$T/5b.txt")"
CLAUDE_LMS_PY="$T/no-python" "$H" read "$T/out.hwpx" > "$T/5c.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(wc -l < "$T/5c.txt" | tr -d ' ')" = "1" ] && grep -q '^ERROR ' "$T/5c.txt" && pass no-python || bad no-python "rc=$rc $(first "$T/5c.txt")"

# 6. --help
"$H" --help > "$T/6.txt" 2>&1 && grep -q 'from-md' "$T/6.txt" && grep -q 'fill' "$T/6.txt" && pass help || bad help "$(first "$T/6.txt")"

# 7. read 전체본 저장: <파일>.hwpx.md 로만 쓰고, 기존 <stem>.md·기존 사이드카·심볼릭 링크 대상은 건드리지 않는다
cp "$T/out.hwpx" "$T/big.hwpx"; echo "원본 메모" > "$T/big.md"; s_md=$(shasum "$T/big.md")
"$H" read "$T/big.hwpx" --max-chars 5 > "$T/7.txt" 2>&1; rc=$?
if [ $rc -eq 0 ] && [ "$(first "$T/7.txt")" = "OK $T/big.hwpx" ] && [ "$(shasum "$T/big.md")" = "$s_md" ] \
   && grep -q '1,000' "$T/big.hwpx.md" 2>/dev/null && grep -qF "$T/big.hwpx.md" "$T/7.txt"; then pass read-sidecar; else bad read-sidecar "rc=$rc $(head -3 "$T/7.txt" | tr '\n' ' ')"; fi
cp "$T/out.hwpx" "$T/big2.hwpx"; echo "피해자" > "$T/victim.txt"; s_v=$(shasum "$T/victim.txt")
ln -s "$T/victim.txt" "$T/big2.hwpx.md"
"$H" read "$T/big2.hwpx" --max-chars 5 > "$T/7b.txt" 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q '^OK ' "$T/7b.txt" && [ "$(shasum "$T/victim.txt")" = "$s_v" ] && [ -L "$T/big2.hwpx.md" ]; then pass read-sidecar-no-clobber; else bad read-sidecar-no-clobber "rc=$rc $(head -3 "$T/7b.txt" | tr '\n' ' ')"; fi

# 8. 쓰기 출력이 끊어진 심볼릭 링크면 거부하고, 링크 대상도 만들지 않는다
ln -s "$T/link-target.hwpx" "$T/dangling.hwpx"
"$H" from-md "$T/in.md" "$T/dangling.hwpx" > "$T/8.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/8.txt" && [ ! -e "$T/link-target.hwpx" ] && pass no-follow-dangling-symlink || bad no-follow-dangling-symlink "rc=$rc $(first "$T/8.txt")"

# 9. Markdown 표: 셀 안 굵게 유지, 빈 데이터 행 유지, \| 는 칸 구분이 아닌 글자
cat > "$T/tbl.md" <<'MD'
| 항목 | 값 |
| --- | --- |
| **굵은항목** | 1 |
|  |  |
| a \| b | 2 |
MD
"$H" from-md "$T/tbl.md" "$T/tbl.hwpx" > "$T/9.txt" 2>&1; rc=$?
"$H" read "$T/tbl.hwpx" > "$T/9r.txt" 2>&1
[ $rc -eq 0 ] && grep -qF '**굵은항목**' "$T/9r.txt" && pass table-cell-bold || bad table-cell-bold "rc=$rc $(grep '굵은항목' "$T/9r.txt" | head -1)"
shape=$("$PY" -I - "$T/tbl.hwpx" <<'EOF' 2>&1
import sys, warnings; warnings.filterwarnings("ignore")
from hwpx import HwpxDocument
t = HwpxDocument.open(sys.argv[1]).tables.map()["tables"][0]
cells = {(c["row"], c["col"]): c["text"] for c in t["cells"]}
print(t["rows"], t["cols"], cells.get((3, 0), "?"))
EOF
)
[ "$shape" = "4 2 a | b" ] && pass table-empty-row-and-escaped-pipe || bad table-empty-row-and-escaped-pipe "rows cols cell(3,0) = '$shape' (기대 '4 2 a | b')"

# 10. fill: 같은 라벨이 여러 칸이면 모호하므로 거부하고 출력 파일을 만들지 않는다
"$PY" -I - "$T/dup.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("신청서")
t = d.add_table(2, 2); t.cell(0, 0).text = "성명"; t.cell(1, 0).text = "성명"
d.save_to_path(sys.argv[1])
EOF
printf '{"성명": "홍길동"}' > "$T/v3.json"
"$H" fill "$T/dup.hwpx" "$T/v3.json" "$T/dup-out.hwpx" > "$T/10.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/10.txt" && grep -q '성명' "$T/10.txt" && [ ! -e "$T/dup-out.hwpx" ] && pass fill-ambiguous-label || bad fill-ambiguous-label "rc=$rc $(first "$T/10.txt")"

# 11. 한 줄 규약: 제어 문자(줄바꿈)가 든 경로는 출력이 정확히 한 줄 ERROR, 파일도 만들지 않는다
NL="$T/new
line.hwpx"
"$H" from-md "$T/in.md" "$NL" > "$T/11.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(wc -l < "$T/11.txt" | tr -d ' ')" = "1" ] && grep -q '^ERROR ' "$T/11.txt" && [ ! -e "$NL" ] && pass newline-path || bad newline-path "rc=$rc lines=$(wc -l < "$T/11.txt" | tr -d ' ')"
"$H" read "$T/no
such.hwpx" > "$T/11b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(wc -l < "$T/11b.txt" | tr -d ' ')" = "1" ] && grep -q '^ERROR ' "$T/11b.txt" && pass newline-in-error || bad newline-in-error "rc=$rc lines=$(wc -l < "$T/11b.txt" | tr -d ' ')"

# 12. 크기 제한: 입력 파일 50MB 초과, 또는 압축 해제 합계 200MB 초과면 열기 전에 거부
printf 'PK\003\004' > "$T/huge.hwpx"; dd if=/dev/zero of="$T/huge.hwpx" bs=1 count=0 seek=60m 2>/dev/null
"$H" read "$T/huge.hwpx" > "$T/12.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*너무 큽니다' "$T/12.txt" && ! grep -q Traceback "$T/12.txt" && pass size-limit || bad size-limit "rc=$rc $(first "$T/12.txt")"
"$PY" -I - "$T/out.hwpx" "$T/bomb.hwpx" <<'EOF'
import shutil, sys, zipfile
shutil.copy(sys.argv[1], sys.argv[2])
with zipfile.ZipFile(sys.argv[2], "a", zipfile.ZIP_DEFLATED) as z, z.open("BinData/pad.bin", "w", force_zip64=True) as f:
    chunk = b"\0" * (1 << 20)
    for _ in range(300):
        f.write(chunk)
EOF
"$H" read "$T/bomb.hwpx" > "$T/12b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*너무 큽니다' "$T/12b.txt" && ! grep -q Traceback "$T/12b.txt" && pass zip-bomb-limit || bad zip-bomb-limit "rc=$rc $(first "$T/12b.txt")"

# 13. from-md 문단 서식: 제목 뒤 본문이 개요 스타일을 물려받지 않고, read 가 제목을 제목으로 되돌린다.
#     짝 없는 ** 는 글자 그대로 남고, '****' 만 있는 줄도 글자가 사라지지 않는다.
cat > "$T/st.md" <<'MD'
# 추진 배경

본문 첫 줄

## 1. 목적

2 ** 3 = 8 이다

****
MD
"$H" from-md "$T/st.md" "$T/st.hwpx" > "$T/13.txt" 2>&1; rc=$?
style=$("$PY" -I - "$T/st.hwpx" <<'EOF' 2>&1
import sys, warnings; warnings.filterwarnings("ignore")
from hwpx import HwpxDocument
d = HwpxDocument.open(sys.argv[1])
names = {str(s.id): s.name for s in d.styles.values()}
by = {p.text: names.get(p.element.get("styleIDRef"), "?") for p in d.paragraphs}
print(by.get("본문 첫 줄", "없음"), "|", by.get("2 ** 3 = 8 이다", "없음"), "|", by.get("****", "없음"))
EOF
)
case "$style" in *개요*|*없음*|*Traceback*) bad body-style-and-literal-stars "본문/별표 문단 스타일 = '$style'";; *) [ $rc -eq 0 ] && pass body-style-and-literal-stars || bad body-style-and-literal-stars "rc=$rc";; esac
"$H" read "$T/st.hwpx" > "$T/13r.txt" 2>&1
grep -qx '# 추진 배경' "$T/13r.txt" && grep -qx '## 1\. 목적' "$T/13r.txt" && grep -qx '본문 첫 줄' "$T/13r.txt" && pass heading-roundtrip || bad heading-roundtrip "$(grep -E '추진 배경|목적|본문' "$T/13r.txt" | tr '\n' '/')"

# 14. fields 와 fill 의 일관성(표 라벨)
"$PY" -I - "$T/form2.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("신청서")
a = d.add_table(4, 2)
a.cell(0, 0).text = "성명"; a.cell(1, 0).text = "직위"; a.cell(1, 1).text = "과장"
a.cell(2, 0).text = "부서 > 팀"; a.cell(3, 0).text = "비\n고"
b = d.add_table(1, 2); b.cell(0, 0).text = "성명"; b.cell(0, 1).text = "김철수"
d.save_to_path(sys.argv[1])
EOF
"$H" fields "$T/form2.hwpx" > "$T/14.txt" 2>&1
# 14a. 다른 표에 같은 라벨이 있어도 빈 칸은 위치 키 '성명 (표 0, 행 0)' 으로 채울 수 있으므로 'fill 불가' 가 아니다
#      (맨 이름 '성명' 은 여전히 모호하다며 거부: 10, 100f). 값이 있는 표 1 의 성명 칸은 목록에 없다
[ "$(grep -c '성명' "$T/14.txt")" = "1" ] && grep '성명' "$T/14.txt" | grep -q '(표 0, 행 0)' && ! grep '성명' "$T/14.txt" | grep -q 'fill 불가' && pass fields-poskey-not-blocked || bad fields-poskey-not-blocked "$(grep '성명' "$T/14.txt" | tr '\n' '/')"
# 14b. fields 출력도 항목당 한 줄(셀 글자의 줄바꿈은 \n 으로)
! grep -qx '소.*' "$T/14.txt" && grep -qF '비\n고' "$T/14.txt" && pass fields-one-line || bad fields-one-line "$(tr '\n' '/' < "$T/14.txt")"
# 14c. 이미 값이 있는 칸은 덮어쓰지 않는다
printf '{"직위": "부장"}' > "$T/v4.json"
"$H" fill "$T/form2.hwpx" "$T/v4.json" "$T/o4.hwpx" > "$T/14c.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*직위' "$T/14c.txt" && grep -q '이미 값' "$T/14c.txt" && [ ! -e "$T/o4.hwpx" ] && pass fill-no-overwrite-value || bad fill-no-overwrite-value "rc=$rc $(first "$T/14c.txt")"
# 14d. 라벨에 '>' 가 있으면 경로 구분자와 겹치므로 그 이유로 거부
printf '{"부서 > 팀": "기획"}' > "$T/v5.json"
"$H" fill "$T/form2.hwpx" "$T/v5.json" "$T/o5.hwpx" > "$T/14d.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -qF '라벨에 > 가 있음' "$T/14d.txt" && [ ! -e "$T/o5.hwpx" ] && pass fill-gt-in-label || bad fill-gt-in-label "rc=$rc $(first "$T/14d.txt")"

# 15. 누름틀 필드: 같은 이름의 누름틀·표 라벨 공존, 같은 이름 누름틀 여러 개 → 한국어 ERROR, 출력 없음
"$PY" -I -W ignore - "$T/mix.hwpx" "$T/dupff.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("신청서"); d.fields.add("성명")
t = d.add_table(1, 2); t.cell(0, 0).text = "성명"
d.save_to_path(sys.argv[1])
e = HwpxDocument.new(); e.add_paragraph("서약서"); e.fields.add("서명"); e.fields.add("서명")
e.save_to_path(sys.argv[2])
EOF
printf '{"성명": "홍길동"}' > "$T/v6.json"
"$H" fill "$T/mix.hwpx" "$T/v6.json" "$T/o6.hwpx" > "$T/15.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*성명' "$T/15.txt" && [ ! -e "$T/o6.hwpx" ] && pass fill-field-and-label-same-name || bad fill-field-and-label-same-name "rc=$rc $(first "$T/15.txt")"
printf '{"서명": "홍길동"}' > "$T/v7.json"
"$H" fill "$T/dupff.hwpx" "$T/v7.json" "$T/o7.hwpx" > "$T/15b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '같은 이름의 누름틀' "$T/15b.txt" && [ ! -e "$T/o7.hwpx" ] && pass fill-duplicate-form-field || bad fill-duplicate-form-field "rc=$rc $(first "$T/15b.txt")"

# 16. 출력 파일 권한은 umask 를 따른다(umask 022 → 644)
( umask 022; "$H" from-md "$T/in.md" "$T/perm.hwpx" > "$T/16.txt" 2>&1 )
[ "$(stat -f %Lp "$T/perm.hwpx" 2>/dev/null)" = "644" ] && pass output-mode-umask || bad output-mode-umask "mode=$(stat -f %Lp "$T/perm.hwpx" 2>/dev/null)"

# 17. read 옵션: --max-chars 는 1 이상만, --md 는 받아들인다(설계 문서의 기본 동작과 같음)
"$H" read "$T/out.hwpx" --max-chars 0 > "$T/17.txt" 2>&1; rc=$?
[ $rc -eq 2 ] && grep -q '^ERROR ' "$T/17.txt" && pass max-chars-min || bad max-chars-min "rc=$rc $(first "$T/17.txt")"
"$H" read "$T/out.hwpx" --md > "$T/17b.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '^OK ' "$T/17b.txt" && pass read-md-flag || bad read-md-flag "rc=$rc $(first "$T/17b.txt")"

# 18. 구분선만 있는 표 블록도 글자를 잃지 않는다(일반 문단으로)
printf '머리 문단\n| --- | --- |\n' > "$T/sep.md"
"$H" from-md "$T/sep.md" "$T/sep.hwpx" > "$T/18.txt" 2>&1; rc=$?
sep=$("$PY" -I - "$T/sep.hwpx" <<'EOF' 2>&1
import sys, warnings; warnings.filterwarnings("ignore")
from hwpx import HwpxDocument
print(any("---" in p.text for p in HwpxDocument.open(sys.argv[1]).paragraphs))
EOF
)
[ $rc -eq 0 ] && [ "$sep" = "True" ] && pass separator-only-block || bad separator-only-block "rc=$rc found=$sep"

# 19. 래퍼는 CDPATH 의 영향을 받지 않는다(상대 경로로 실행)
mkdir -p "$T/decoy/skills/hwpx/scripts"
( cd "$KIT" && CDPATH="$T/decoy" skills/hwpx/scripts/hwpx --help ) > "$T/19.txt" 2>&1
grep -q 'from-md' "$T/19.txt" && pass wrapper-cdpath || bad wrapper-cdpath "$(first "$T/19.txt")"

# 20. 같은 칸을 가리키는 JSON 키가 여럿이면(정규화 후 같음, 또는 원문 키 중복) 조용히 덮어쓰지 않고 거부
printf '{"성명": "홍길동", "성명:": "김철수"}' > "$T/v8.json"
"$H" fill "$T/form.hwpx" "$T/v8.json" "$T/o8.hwpx" > "$T/20.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*성명' "$T/20.txt" && [ ! -e "$T/o8.hwpx" ] && pass fill-normalized-duplicate-keys || bad fill-normalized-duplicate-keys "rc=$rc $(first "$T/20.txt")"
printf '{"성명": "홍길동", "성명": "김철수"}' > "$T/v9.json"
"$H" fill "$T/form.hwpx" "$T/v9.json" "$T/o9.hwpx" > "$T/20b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*성명' "$T/20b.txt" && [ ! -e "$T/o9.hwpx" ] && pass fill-raw-duplicate-keys || bad fill-raw-duplicate-keys "rc=$rc $(first "$T/20b.txt")"

# 21. 같은 글자의 본문과 제목이 있어도 문서 순서대로 되읽는다
printf '동일 문구\n\n# 동일 문구\n' > "$T/same.md"
"$H" from-md "$T/same.md" "$T/same.hwpx" > /dev/null 2>&1
"$H" read "$T/same.hwpx" > "$T/21.txt" 2>&1
order=$(grep -xE '(# )?동일 문구' "$T/21.txt" | tr '\n' '/')
[ "$order" = "동일 문구/# 동일 문구/" ] && pass heading-order || bad heading-order "$order"

# 22. fields 는 fill 이 거부할 항목을 모두 'fill 불가' 로 표시
"$H" fields "$T/form2.hwpx" > "$T/22a.txt" 2>&1
grep -F '부서 > 팀' "$T/22a.txt" | grep -q 'fill 불가' && pass fields-marks-gt || bad fields-marks-gt "$(grep -F '부서' "$T/22a.txt")"
"$H" fields "$T/dupff.hwpx" > "$T/22b.txt" 2>&1
grep '서명' "$T/22b.txt" | grep -q 'fill 불가' && ! grep '서명' "$T/22b.txt" | grep -vq 'fill 불가' && pass fields-marks-duplicate-form-field || bad fields-marks-duplicate-form-field "$(grep '서명' "$T/22b.txt" | tr '\n' '/')"
"$H" fields "$T/mix.hwpx" > "$T/22c.txt" 2>&1
grep '성명' "$T/22c.txt" | grep -q 'fill 불가' && ! grep '성명' "$T/22c.txt" | grep -vq 'fill 불가' && pass fields-marks-field-and-label || bad fields-marks-field-and-label "$(grep '성명' "$T/22c.txt" | tr '\n' '/')"

# 23. 표 안의 표(중첩 표)도 라벨 판정에 넣는다: fields 에 보이고, 값이 있는 칸은 덮어쓰지 않는다
"$PY" -I -W ignore - "$T/nest.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("신청서")
n = d.add_table(1, 1).cell(0, 0).add_table(2, 2)
n.cell(0, 0).text = "성명"; n.cell(0, 1).text = "홍길동"; n.cell(1, 0).text = "연락처"
d.save_to_path(sys.argv[1])
EOF
"$H" fields "$T/nest.hwpx" > "$T/23.txt" 2>&1
grep -q '연락처' "$T/23.txt" && pass fields-nested-table || bad fields-nested-table "$(tr '\n' '/' < "$T/23.txt")"
printf '{"성명": "김철수"}' > "$T/v10.json"
"$H" fill "$T/nest.hwpx" "$T/v10.json" "$T/o10.hwpx" > "$T/23b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '이미 값' "$T/23b.txt" && [ ! -e "$T/o10.hwpx" ] && pass fill-nested-no-overwrite || bad fill-nested-no-overwrite "rc=$rc $(first "$T/23b.txt")"

# 24. 래퍼의 파이썬 없음 ERROR 도 정확히 한 줄(경로에 줄바꿈이 있어도)
CLAUDE_LMS_PY="$T/no
python" "$H" --help > "$T/24.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(wc -l < "$T/24.txt" | tr -d ' ')" = "1" ] && grep -q '^ERROR ' "$T/24.txt" && pass wrapper-error-one-line || bad wrapper-error-one-line "rc=$rc lines=$(wc -l < "$T/24.txt" | tr -d ' ')"

# 25. 사슬 채우기 금지: 표에 없는 키는 라이브러리로 넘기지 않고 '라벨 없음' 으로 거부(값이 라벨이 되는 일 없음)
"$PY" -I -W ignore - "$T/chain.hwpx" "$T/ffval.hwpx" "$T/ffph.hwpx" "$T/vmerge.hwpx" "$T/fake.hwpx" <<'EOF'
import sys, zipfile
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("신청서")
d.add_table(1, 3).cell(0, 0).text = "성명"
d.save_to_path(sys.argv[1])
e = HwpxDocument.new(); e.add_paragraph("신청서"); e.fields.add("성명").value = "홍길동"
e.save_to_path(sys.argv[2])
f = HwpxDocument.new(); f.add_paragraph("신청서"); f.fields.add("주소", prompt="주소 입력")
f.save_to_path(sys.argv[3])
g = HwpxDocument.new(); g.add_paragraph("신청서")
t = g.add_table(2, 2); t.cell(0, 0).text = "성명"; t.merge_cells(0, 0, 1, 0)
g.save_to_path(sys.argv[4])
with zipfile.ZipFile(sys.argv[5], "w") as z:
    z.writestr("word/document.xml", "<w:document/>")
EOF
printf '{"성명": "직위", "직위": "과장"}' > "$T/v11.json"
"$H" fill "$T/chain.hwpx" "$T/v11.json" "$T/o11.hwpx" > "$T/25.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*직위(라벨 없음)' "$T/25.txt" && [ ! -e "$T/o11.hwpx" ] && pass fill-no-chain || bad fill-no-chain "rc=$rc $(first "$T/25.txt")"

# 26. 누름틀: 이미 값이 있으면 덮어쓰지 않음(fields 도 fill 불가 표시), 안내문만 있는 누름틀은 채움
printf '{"성명": "김철수"}' > "$T/v12.json"
"$H" fill "$T/ffval.hwpx" "$T/v12.json" "$T/o12.hwpx" > "$T/26.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*이미 값' "$T/26.txt" && [ ! -e "$T/o12.hwpx" ] && pass fill-form-field-no-overwrite || bad fill-form-field-no-overwrite "rc=$rc $(first "$T/26.txt")"
"$H" fields "$T/ffval.hwpx" > "$T/26b.txt" 2>&1
grep '성명' "$T/26b.txt" | grep -q 'fill 불가' && pass fields-marks-filled-form-field || bad fields-marks-filled-form-field "$(grep '성명' "$T/26b.txt")"
printf '{"주소": "서울시"}' > "$T/v13.json"
"$H" fill "$T/ffph.hwpx" "$T/v13.json" "$T/o13.hwpx" > "$T/26c.txt" 2>&1; rc=$?
"$H" read "$T/o13.hwpx" > "$T/26d.txt" 2>&1
[ $rc -eq 0 ] && grep -q '서울시' "$T/26d.txt" && pass fill-placeholder-form-field || bad fill-placeholder-form-field "rc=$rc $(first "$T/26c.txt")"

# 27. 누름틀 이름도 표 라벨과 같은 규칙으로 비교: '성명:' 키로 공존 검사를 피해 갈 수 없다
printf '{"성명:": "홍길동"}' > "$T/v14.json"
"$H" fill "$T/mix.hwpx" "$T/v14.json" "$T/o14.hwpx" > "$T/27.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*성명' "$T/27.txt" && [ ! -e "$T/o14.hwpx" ] && pass fill-normalized-field-and-label || bad fill-normalized-field-and-label "rc=$rc $(first "$T/27.txt")"

# 28. 세로 병합된 라벨은 fields 에 한 번만
"$H" fields "$T/vmerge.hwpx" > "$T/28.txt" 2>&1
[ "$(grep -c '성명' "$T/28.txt")" = "1" ] && pass fields-vertical-merge-once || bad fields-vertical-merge-once "$(grep '성명' "$T/28.txt" | tr '\n' '/')"

# 29. HWPX 가 아닌 zip(mimetype 없음): read·validate 모두 '내부 오류' 가 아닌 한 줄 ERROR
"$H" read "$T/fake.hwpx" > "$T/29a.txt" 2>&1; rc1=$?
"$H" validate "$T/fake.hwpx" > "$T/29b.txt" 2>&1; rc2=$?
if [ $rc1 -ne 0 ] && [ $rc2 -ne 0 ] && grep -q '^ERROR ' "$T/29a.txt" && grep -q '^ERROR ' "$T/29b.txt" \
   && ! grep -q '내부 오류' "$T/29a.txt" "$T/29b.txt" \
   && [ "$(wc -l < "$T/29a.txt" | tr -d ' ')" = "1" ] && [ "$(wc -l < "$T/29b.txt" | tr -d ' ')" = "1" ]; then
  pass invalid-zip-message; else bad invalid-zip-message "$(first "$T/29a.txt") / $(first "$T/29b.txt")"; fi

# 30. 공백에 붙은 ** 는 굵게 표시가 아니다(거듭제곱 표기 보존)
printf '2 ** 3 = 8, 3 ** 2 = 9\n\n**굵게** 끝\n' > "$T/pow.md"
"$H" from-md "$T/pow.md" "$T/pow.hwpx" > /dev/null 2>&1
"$PY" -I -W ignore - "$T/pow.hwpx" > "$T/30.txt" 2>&1 <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.open(sys.argv[1])
for p in d.paragraphs:
    for r in p.runs:
        if r.text:
            print(f"{'B' if r.bold else 'N'}|{r.text}")
EOF
grep -qx 'N|2 \*\* 3 = 8, 3 \*\* 2 = 9' "$T/30.txt" && grep -qx 'B|굵게' "$T/30.txt" && pass bold-needs-tight-stars || bad bold-needs-tight-stars "$(tr '\n' '/' < "$T/30.txt")"

# 31. 제목 글자에 Markdown 특수문자([ ] _ 등)가 있어도 read 가 제목으로 되돌린다
printf '# [붙임 1] 계획_안\n\n본문\n' > "$T/esc.md"
"$H" from-md "$T/esc.md" "$T/esc.hwpx" > /dev/null 2>&1
"$H" read "$T/esc.hwpx" > "$T/31.txt" 2>&1
grep -qE '^# \\?\[붙임 1\\?\] 계획\\?_안$' "$T/31.txt" && pass heading-with-md-escapes || bad heading-with-md-escapes "$(grep '붙임' "$T/31.txt")"

# 32. 머리 행 + 구분선이 없는 '|' 줄은 표가 아니라 문단(글자 그대로)
printf '| 참고: 내용\n' > "$T/pipe.md"
"$H" from-md "$T/pipe.md" "$T/pipe.hwpx" > "$T/32.txt" 2>&1; rc=$?
"$PY" -I -W ignore - "$T/pipe.hwpx" > "$T/32b.txt" 2>&1 <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.open(sys.argv[1])
print(len(list(d.tables.all)), any(p.text == "| 참고: 내용" for p in d.paragraphs))
EOF
[ $rc -eq 0 ] && [ "$(cat "$T/32b.txt")" = "0 True" ] && pass pipe-line-not-table || bad pipe-line-not-table "rc=$rc $(cat "$T/32b.txt")"

# 33. 두 라벨의 오른쪽 칸이 하나로 병합돼 있으면 두 키를 함께 채우지 않는다(값 유실 방지), 한 키만은 채운다
"$PY" -I -W ignore - "$T/shared.hwpx" "$T/vrow.hwpx" "$T/edge.hwpx" "$T/edgeff.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("서약서")
t = d.add_table(2, 2); t.cell(0, 0).text = "성명"; t.cell(1, 0).text = "서명"; t.merge_cells(0, 1, 1, 1)
d.save_to_path(sys.argv[1])
e = HwpxDocument.new(); e.add_paragraph("신청서")
t = e.add_table(2, 2); t.cell(0, 0).text = "성명"; t.cell(1, 0).text = "직위"
e.save_to_path(sys.argv[2])
f = HwpxDocument.new(); f.add_paragraph("목록")
t = f.add_table(1, 2); t.cell(0, 0).text = "항목"; t.cell(0, 1).text = "비고"
f.save_to_path(sys.argv[3])
g = HwpxDocument.new(); g.add_paragraph("목록"); g.fields.add("비고")
t = g.add_table(1, 2); t.cell(0, 0).text = "항목"; t.cell(0, 1).text = "비고"
g.save_to_path(sys.argv[4])
EOF
printf '{"성명": "홍길동", "서명": "김철수"}' > "$T/v15.json"
"$H" fill "$T/shared.hwpx" "$T/v15.json" "$T/o15.hwpx" > "$T/33.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -qE '^ERROR .*(성명|서명)' "$T/33.txt" && [ ! -e "$T/o15.hwpx" ] && pass fill-shared-target-cell || bad fill-shared-target-cell "rc=$rc $(first "$T/33.txt")"
printf '{"성명": "홍길동"}' > "$T/v16.json"
"$H" fill "$T/shared.hwpx" "$T/v16.json" "$T/o16.hwpx" > "$T/33b.txt" 2>&1; rc=$?
"$H" read "$T/o16.hwpx" > "$T/33c.txt" 2>&1
[ $rc -eq 0 ] && grep -q '홍길동' "$T/33c.txt" && pass fill-merged-target-single-key || bad fill-merged-target-single-key "rc=$rc $(first "$T/33b.txt")"

# 34. 값이 다른 라벨과 같은 글자여도 채우기 전에 정한 칸에 그대로 쓴다
printf '{"성명": "직위", "직위": "과장"}' > "$T/v17.json"
"$H" fill "$T/vrow.hwpx" "$T/v17.json" "$T/o17.hwpx" > "$T/34.txt" 2>&1; rc=$?
cells=$("$PY" -I -W ignore - "$T/o17.hwpx" <<'EOF' 2>&1
import sys
from hwpx import HwpxDocument
t = list(HwpxDocument.open(sys.argv[1]).tables.all)[0]
print("/".join(t.cell(r, c).text for r in range(2) for c in range(2)))
EOF
)
[ $rc -eq 0 ] && [ "$cells" = "성명/직위/직위/과장" ] && pass fill-value-equals-other-label || bad fill-value-equals-other-label "rc=$rc $(first "$T/34.txt") cells=$cells"

# 35. 1x1 표 뒤에 같은 글자의 제목이 와도 표는 제목이 되지 않고, 실제 제목은 제목으로 되읽는다
printf '| 추진 배경 |\n| --- |\n\n# 추진 배경\n\n본문\n' > "$T/box.md"
"$H" from-md "$T/box.md" "$T/box.hwpx" > /dev/null 2>&1
"$H" read "$T/box.hwpx" > "$T/35.txt" 2>&1
order=$(grep -E '추진 배경' "$T/35.txt" | grep -c '^# 추진 배경$')
last=$(grep -E '추진 배경' "$T/35.txt" | tail -1)
[ "$order" = "1" ] && [ "$last" = "# 추진 배경" ] && pass heading-after-1x1-table || bad heading-after-1x1-table "$(grep '추진 배경' "$T/35.txt" | tr '\n' '/')"

# 36. read 출력에 HTML 엔티티(&amp; &lt; 등)가 남지 않는다: 제목·본문 모두 원래 글자로
printf '# 연구 & 개발\n\nA & B 그리고 <x>\n' > "$T/amp.md"
"$H" from-md "$T/amp.md" "$T/amp.hwpx" > /dev/null 2>&1
"$H" read "$T/amp.hwpx" > "$T/36.txt" 2>&1
grep -qx '# 연구 & 개발' "$T/36.txt" && grep -qx 'A & B 그리고 <x>' "$T/36.txt" && ! grep -q '&amp;\|&lt;' "$T/36.txt" && pass read-no-html-entities || bad read-no-html-entities "$(sed -n '2,6p' "$T/36.txt" | tr '\n' '/')"

# 37. 구분선은 머리 행 바로 다음 한 줄뿐: 구분선처럼 생긴 데이터 행도 표에 남는다
printf '| 항목 | 값 |\n| --- | --- |\n| --- | --- |\n| 예산 | 100 |\n' > "$T/sepdata.md"
"$H" from-md "$T/sepdata.md" "$T/sepdata.hwpx" > "$T/37.txt" 2>&1; rc=$?
rows=$("$PY" -I -W ignore - "$T/sepdata.hwpx" <<'EOF' 2>&1
import sys
from hwpx import HwpxDocument
t = list(HwpxDocument.open(sys.argv[1]).tables.all)[0]
print("/".join(t.cell(r, 0).text for r in range(3)))
EOF
)
[ $rc -eq 0 ] && [ "$rows" = "항목/---/예산" ] && pass separator-like-data-row || bad separator-like-data-row "rc=$rc rows=$rows"

# 38. 오른쪽 칸이 없는 맨 끝 열 글자: fill 은 한국어 사유로 거부하고, 같은 이름의 누름틀은 막지 않는다
printf '{"비고": "메모"}' > "$T/v18.json"
"$H" fill "$T/edge.hwpx" "$T/v18.json" "$T/o18.hwpx" > "$T/38.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -qE '^ERROR .*비고\((라벨 없음|오른쪽 칸 없음)\)' "$T/38.txt" && ! grep -qi 'navigation' "$T/38.txt" && [ ! -e "$T/o18.hwpx" ] && pass fill-rightmost-label || bad fill-rightmost-label "rc=$rc $(first "$T/38.txt")"
"$H" fill "$T/edgeff.hwpx" "$T/v18.json" "$T/o19.hwpx" > "$T/38b.txt" 2>&1; rc=$?
"$H" fields "$T/edgeff.hwpx" > "$T/38c.txt" 2>&1
[ $rc -eq 0 ] && grep '비고' "$T/38c.txt" | grep -q '누름틀' && ! grep '비고' "$T/38c.txt" | grep -q 'fill 불가' && pass fill-form-field-beside-rightmost-label || bad fill-form-field-beside-rightmost-label "rc=$rc $(first "$T/38b.txt") / $(grep '비고' "$T/38c.txt")"

# 39~46 공통 픽스처
"$PY" -I -W ignore - "$T" <<'EOF'
import sys
from hwpx import HwpxDocument
T = sys.argv[1]
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
# 중첩 누름틀: A 안에 B, 뒤에 독립 C·D
d = HwpxDocument.new()
for n in "ABCD": d.fields.add(n)
pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
at = list(pa).index(list(pa)[0]) + 1
for off, run in enumerate(list(pb)): pa.insert(at + off, run)
pb.getparent().remove(pb); save(d, "nestf")
# 기울임 본문 + 같은 글자의 개요 1 제목
d = HwpxDocument.new(); d.add_paragraph("").add_run("동일 문구", italic=True)
q = d.add_paragraph("동일 문구")
q.element.set("styleIDRef", str([s.id for s in d.styles.values() if str(s.name).replace(" ", "") == "개요1"][0]))
save(d, "italic")
# 두 문단짜리 1x1 상자 + 글자 그대로 '가<br>나' 제목
d = HwpxDocument.new(); c = d.add_table(1, 1).cell(0, 0); c.text = "가"; c.add_paragraph("나")
d.add_heading("가<br>나", 1); save(d, "brbox")
# 단순 표 캡션이 글자 그대로 '<table> 예시'
d = HwpxDocument.new(); t = d.add_table(1, 2); t.cell(0, 0).text = "a"; t.cell(0, 1).text = "b"
t.set_caption("<table> 예시"); d.add_paragraph("A & B"); save(d, "capt")
# GFM 표 칸 사이에 중첩 표(HTML), 중첩 칸에는 '<'
d = HwpxDocument.new(); t = d.add_table(1, 3); t.set_cell_text(0, 0, "A & B")
t.cell(0, 1).add_table(1, 2).cell(0, 0).text = "x < y"; t.set_cell_text(0, 2, "C & D")
d.add_paragraph("E & F"); save(d, "nestamp")
# 표 칸 안 누름틀: 라벨 칸 자체가 누름틀(c1), 라벨 오른쪽 칸이 누름틀(c3), 오른쪽 칸에 중첩 표(dnest)
d = HwpxDocument.new(); c = d.add_table(1, 2).cell(0, 0)
d.add_form_field("성명", prompt="성명", paragraph=c.paragraphs[0]); save(d, "c1")
d = HwpxDocument.new(); t = d.add_table(1, 2); t.set_cell_text(0, 0, "성명")
d.add_form_field("이름", prompt="", paragraph=t.cell(0, 1).paragraphs[0]); save(d, "c3")
d = HwpxDocument.new(); t = d.add_table(1, 2); t.set_cell_text(0, 0, "세부 내역"); t.cell(0, 1).add_table(2, 2)
save(d, "dnest")
# 이름이 ':' 뿐인 누름틀
d = HwpxDocument.new(); d.add_paragraph("양식"); d.fields.add(":"); save(d, "colon")
EOF
fieldvals() { "$PY" -I -W ignore - "$1" <<'EOF'
import sys
from hwpx import HwpxDocument
try:
    print("/".join(f"{f.name}={f.value}" for f in HwpxDocument.open(sys.argv[1]).fields.all))
except Exception as exc:
    print("열기 실패", type(exc).__name__)
EOF
}

# 39. 제목은 그 문단의 개요 스타일로만 정한다: 1x1 표는 사라지지 않고, 번호로 시작하는 본문은 제목이 되지 않는다
printf '| 1. 추진 배경 |\n| --- |\n\n1. 목적\n\n# 1. 추진 배경\n' > "$T/num.md"
"$H" from-md "$T/num.md" "$T/num.hwpx" > /dev/null 2>&1
"$H" read "$T/num.hwpx" > "$T/39.txt" 2>&1
grep -qxF '| 1. 추진 배경 |' "$T/39.txt" && grep -qxF '1. 목적' "$T/39.txt" && grep -qxF '# 1. 추진 배경' "$T/39.txt" \
  && ! grep -q '^##' "$T/39.txt" && pass read-heading-style-only || bad read-heading-style-only "$(sed -n '2,8p' "$T/39.txt" | tr '\n' '/')"

# 40. 기울임 본문과 같은 글자의 제목: 제목은 '#' 을 잃지 않는다 / 여러 문단 1x1 상자도 표로 남는다
"$H" read "$T/italic.hwpx" > "$T/40.txt" 2>&1
grep -qxF '*동일 문구*' "$T/40.txt" && grep -qxF '# 동일 문구' "$T/40.txt" && pass read-italic-then-heading || bad read-italic-then-heading "$(sed -n '2,6p' "$T/40.txt" | tr '\n' '/')"
"$H" read "$T/brbox.hwpx" > "$T/40b.txt" 2>&1
grep -qxF '| 가<br>나 |' "$T/40b.txt" && [ "$(grep -cxF '# 가<br>나' "$T/40b.txt")" = "1" ] && pass read-multiparagraph-box || bad read-multiparagraph-box "$(sed -n '2,8p' "$T/40b.txt" | tr '\n' '/')"

# 41. 엔티티 복원은 라이브러리가 만든 HTML 표 블록 바깥만: 캡션 글자 '<table>' 이 뒤 본문 복원을 막지 않고,
#     GFM 칸 안 중첩 표 앞뒤 글자는 복원, 중첩 표 안 '&lt;' 는 그대로
"$H" read "$T/capt.hwpx" > "$T/41.txt" 2>&1
grep -qxF 'A & B' "$T/41.txt" && ! grep -q '&amp;' "$T/41.txt" && pass read-caption-table-text || bad read-caption-table-text "$(sed -n '2,9p' "$T/41.txt" | tr '\n' '/')"
"$H" read "$T/nestamp.hwpx" > "$T/41b.txt" 2>&1
grep -qxF '| A & B | <table>' "$T/41b.txt" && grep -qxF '</table> | C & D |' "$T/41b.txt" && grep -qF 'x &lt; y' "$T/41b.txt" \
  && grep -qxF 'E & F' "$T/41b.txt" && pass read-nested-table-in-gfm-row || bad read-nested-table-in-gfm-row "$(sed -n '2,12p' "$T/41b.txt" | tr '\n' '/')"

# 42. 중첩 누름틀: 바깥 누름틀을 채워 안쪽 누름틀이 사라지면 거부 / 바깥을 건드리지 않으면 뒤 누름틀은 제자리에 채운다 / 부모·자식 동시 요청은 거부
printf '{"A": "가", "C": "다"}' > "$T/v20.json"
"$H" fill "$T/nestf.hwpx" "$T/v20.json" "$T/o20.hwpx" > "$T/42.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*B' "$T/42.txt" && [ ! -e "$T/o20.hwpx" ] && pass fill-nested-field-lost || bad fill-nested-field-lost "rc=$rc $(first "$T/42.txt")"
printf '{"C": "다"}' > "$T/v20b.json"
"$H" fill "$T/nestf.hwpx" "$T/v20b.json" "$T/o20b.hwpx" > "$T/42c.txt" 2>&1; rc=$?
vals=$(fieldvals "$T/o20b.hwpx" 2>&1)
[ $rc -eq 0 ] && [ "$vals" = "A=/B=/C=다/D=" ] && pass fill-nested-field-reindex || bad fill-nested-field-reindex "rc=$rc $(first "$T/42c.txt") vals=$vals"
printf '{"A": "가", "B": "나"}' > "$T/v21.json"
"$H" fill "$T/nestf.hwpx" "$T/v21.json" "$T/o21.hwpx" > "$T/42b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/42b.txt" && [ ! -e "$T/o21.hwpx" ] && pass fill-parent-child-fields || bad fill-parent-child-fields "rc=$rc $(first "$T/42b.txt")"

# 43. 표 칸 안 누름틀: 누름틀이 든 칸은 라벨이 아니다(누름틀로 채움) / 누름틀·중첩 표가 든 오른쪽 칸은 표 라벨로 채우지 않는다
"$H" fields "$T/c1.hwpx" > "$T/43.txt" 2>&1
printf '{"성명": "홍길동"}' > "$T/v22.json"
"$H" fill "$T/c1.hwpx" "$T/v22.json" "$T/o22.hwpx" > "$T/43b.txt" 2>&1; rc=$?
vals=$(fieldvals "$T/o22.hwpx" 2>&1)
[ "$(grep -c '성명' "$T/43.txt")" = "1" ] && ! grep -q 'fill 불가' "$T/43.txt" && [ $rc -eq 0 ] && [ "$vals" = "성명=홍길동" ] \
  && pass fill-field-in-label-cell || bad fill-field-in-label-cell "rc=$rc $(first "$T/43b.txt") vals=$vals / $(tr '\n' '/' < "$T/43.txt")"
"$H" fields "$T/c3.hwpx" > "$T/43c.txt" 2>&1
printf '{"이름": "김철수", "성명": "홍길동"}' > "$T/v23.json"
"$H" fill "$T/c3.hwpx" "$T/v23.json" "$T/o23.hwpx" > "$T/43d.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*성명' "$T/43d.txt" && [ ! -e "$T/o23.hwpx" ] && grep '성명' "$T/43c.txt" | grep -q 'fill 불가' \
  && pass fill-label-target-has-field || bad fill-label-target-has-field "rc=$rc $(first "$T/43d.txt") / $(grep '성명' "$T/43c.txt")"
printf '{"이름": "김철수"}' > "$T/v24.json"
"$H" fill "$T/c3.hwpx" "$T/v24.json" "$T/o24.hwpx" > "$T/43e.txt" 2>&1; rc=$?
vals=$(fieldvals "$T/o24.hwpx" 2>&1)
[ $rc -eq 0 ] && [ "$vals" = "이름=김철수" ] && pass fill-field-beside-label || bad fill-field-beside-label "rc=$rc $(first "$T/43e.txt") vals=$vals"
"$H" fields "$T/dnest.hwpx" > "$T/43f.txt" 2>&1
printf '{"세부 내역": "X"}' > "$T/v25.json"
"$H" fill "$T/dnest.hwpx" "$T/v25.json" "$T/o25.hwpx" > "$T/43g.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*세부 내역' "$T/43g.txt" && [ ! -e "$T/o25.hwpx" ] && grep '세부 내역' "$T/43f.txt" | grep -q 'fill 불가' \
  && pass fill-label-target-has-table || bad fill-label-target-has-table "rc=$rc $(first "$T/43g.txt") / $(grep '세부 내역' "$T/43f.txt")"

# 44. 정규화하면 빈 이름인 누름틀(':' 등)은 fields 에 싣지 않는다
"$H" fields "$T/colon.hwpx" > "$T/44.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -qE '^- :?( |$)' "$T/44.txt" && pass fields-skip-empty-name || bad fields-skip-empty-name "rc=$rc $(tr '\n' '/' < "$T/44.txt")"

# 45. 쓰기 금지 폴더의 read: 전체본 저장에 실패해도 OK·종료 코드 0(내용은 그대로 보여 준다)
mkdir -p "$T/ro"
"$PY" -I -W ignore - "$T/ro/g.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new()
for i in range(50): d.add_paragraph(f"가나다라마바사 & 아자차카 {i}")
d.save_to_path(sys.argv[1])
EOF
chmod 555 "$T/ro"
"$H" read "$T/ro/g.hwpx" --max-chars 100 > "$T/45.txt" 2>&1; rc=$?
chmod 755 "$T/ro"
[ $rc -eq 0 ] && [ "$(first "$T/45.txt")" = "OK $T/ro/g.hwpx" ] && grep -q '가나다라마바사 & 아자차카 0' "$T/45.txt" && [ ! -e "$T/ro/g.hwpx.md" ] \
  && pass read-sidecar-unwritable-dir || bad read-sidecar-unwritable-dir "rc=$rc $(head -2 "$T/45.txt" | tr '\n' ' ')"

# 46~48 공통 픽스처
"$PY" -I -W ignore - "$T" <<'EOF'
import sys
from hwpx import HwpxDocument
T = sys.argv[1]
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
# 여러 문단 누름틀 A 의 시작·끝 사이에 [성명][빈칸] 표
d = HwpxDocument.new(); d.fields.add("A"); pa = d.paragraphs[1].element
d.add_table(1, 2).set_cell_text(0, 0, "성명")
end = d.add_paragraph("끝"); run = list(pa)[-1]; pa.remove(run); end.element.insert(0, run)
save(d, "spanf")
# 개요 1 스타일인 빈 문단 안의 1x1 표(캡션 있음), 뒤 본문은 바탕글
d = HwpxDocument.new(); d.add_paragraph("앞 본문")
t = d.add_table(1, 1); t.set_cell_text(0, 0, "신청 내용"); t.set_caption("작성 안내")
d.add_paragraph("뒤 본문")
host = next(p for p in d.paragraphs if p.element.find(".//{*}tbl") is not None)
host.element.set("styleIDRef", str([s.id for s in d.styles.values() if str(s.name).replace(" ", "") == "개요1"][0]))
save(d, "olbox")
# 라벨 칸 '성명' 에 하이퍼링크, 오른쪽 칸은 빈칸
d = HwpxDocument.new(); t = d.add_table(1, 2)
t.cell(0, 0).paragraphs[0].add_hyperlink("https://example.com", "성명"); save(d, "hlabel")
EOF

# 46. 누름틀을 채우면 그 범위 안 표가 지워진다: 표 키와 함께 요청하면 순서와 상관없이 거부 / 각각은 채운다
for n in 1 2; do
  [ $n = 1 ] && printf '{"성명": "홍길동", "A": "완료"}' > "$T/v26.json" || printf '{"A": "완료", "성명": "홍길동"}' > "$T/v26.json"
  "$H" fill "$T/spanf.hwpx" "$T/v26.json" "$T/o26.hwpx" > "$T/46.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR .*성명' "$T/46.txt" && [ ! -e "$T/o26.hwpx" ] && pass "fill-table-inside-field-span-$n" \
    || bad "fill-table-inside-field-span-$n" "rc=$rc $(first "$T/46.txt")"
  rm -f "$T/o26.hwpx"
done
printf '{"성명": "홍길동"}' > "$T/v27.json"
"$H" fill "$T/spanf.hwpx" "$T/v27.json" "$T/o27.hwpx" > "$T/46b.txt" 2>&1; rc=$?
"$H" read "$T/o27.hwpx" > "$T/46c.txt" 2>&1
[ $rc -eq 0 ] && grep -q '홍길동' "$T/46c.txt" && pass fill-table-inside-field-alone || bad fill-table-inside-field-alone "rc=$rc $(first "$T/46b.txt")"

# 47. 개요 스타일인 빈 문단의 1x1 표: 제목으로 바꾸지 않고 표·캡션을 그대로 보여 준다
"$H" read "$T/olbox.hwpx" > "$T/47.txt" 2>&1
grep -qF '| 신청 내용 |' "$T/47.txt" && grep -qF '작성 안내' "$T/47.txt" && ! grep -q '^#' "$T/47.txt" && grep -qxF '뒤 본문' "$T/47.txt" \
  && pass read-outline-host-keeps-box || bad read-outline-host-keeps-box "$(sed -n '2,10p' "$T/47.txt" | tr '\n' '/')"

# 48. 하이퍼링크(fieldBegin type=HYPERLINK)가 걸린 라벨 칸은 누름틀이 아니다: 표 라벨로 채운다
"$H" fields "$T/hlabel.hwpx" > "$T/48.txt" 2>&1
printf '{"성명": "홍길동"}' > "$T/v28.json"
"$H" fill "$T/hlabel.hwpx" "$T/v28.json" "$T/o28.hwpx" > "$T/48b.txt" 2>&1; rc=$?
"$H" read "$T/o28.hwpx" > "$T/48c.txt" 2>&1
grep '성명' "$T/48.txt" | grep -q '표 0' && ! grep -q 'fill 불가' "$T/48.txt" && [ $rc -eq 0 ] && grep -q '홍길동' "$T/48c.txt" \
  && pass fill-hyperlink-label || bad fill-hyperlink-label "rc=$rc $(first "$T/48b.txt") / $(tr '\n' '/' < "$T/48.txt")"


# 49~54 공통 픽스처
"$PY" -I -W ignore - "$T" <<'EOF'
import sys
from hwpx import HwpxDocument
T = sys.argv[1]
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
def h1(d): return str([s.id for s in d.styles.values() if str(s.name).replace(" ", "") == "개요1"][0])
# 라벨 '성명' 오른쪽 칸에 같은 이름의 누름틀 '성명'
d = HwpxDocument.new(); t = d.add_table(1, 2); t.set_cell_text(0, 0, "성명")
d.add_form_field("성명", prompt="", paragraph=t.cell(0, 1).paragraphs[0]); save(d, "samef")
# 개요 1 문단 '요약' 안에 1x1 표 '요약 설명'
d = HwpxDocument.new(); p = d.add_paragraph("요약"); p.add_table(1, 1).set_cell_text(0, 0, "요약 설명")
d.add_paragraph("뒤 본문"); p.element.set("styleIDRef", h1(d)); save(d, "sumbox")
# 링크 주소 속 '&copy' '&sect', 그리고 본문 글자 'A &lt; B'
d = HwpxDocument.new(); d.add_paragraph("앞").add_hyperlink("https://example.com/?a=1&copy=2&sect=3", "링크")
d.add_paragraph("A &lt; B"); save(d, "urlent")
# 개요 1 제목 안 줄바꿈
d = HwpxDocument.new(); p = d.add_paragraph("1장\n추진 배경"); d.add_paragraph("본문"); p.element.set("styleIDRef", h1(d)); save(d, "hbr")
# 라벨 '동의' 오른쪽 칸에 체크박스
d = HwpxDocument.new(); t = d.add_table(1, 2); t.set_cell_text(0, 0, "동의")
d.add_check_box("동의함", paragraph=t.cell(0, 1).paragraphs[0]); save(d, "chkbox")
# 끝 표시(fieldEnd)가 없는 누름틀 X
d = HwpxDocument.new(); d.fields.add("X")
for el in list(d.sections[0].element.iter()):
    if el.tag.endswith("}fieldEnd"):
        ctrl = el.getparent(); ctrl.getparent().remove(ctrl)
save(d, "noend")
EOF

# 49. 라벨 오른쪽 칸이 같은 이름의 누름틀이면 하나의 항목(누름틀)으로 채운다
"$H" fields "$T/samef.hwpx" > "$T/49.txt" 2>&1
printf '{"성명": "홍길동"}' > "$T/v29.json"
"$H" fill "$T/samef.hwpx" "$T/v29.json" "$T/o29.hwpx" > "$T/49b.txt" 2>&1; rc=$?
vals=$(fieldvals "$T/o29.hwpx" 2>&1)
[ "$(grep -c '성명' "$T/49.txt")" = "1" ] && ! grep -q 'fill 불가' "$T/49.txt" && [ $rc -eq 0 ] && [ "$vals" = "성명=홍길동" ] \
  && pass fill-same-name-label-field || bad fill-same-name-label-field "rc=$rc $(first "$T/49b.txt") / $(tr '\n' '/' < "$T/49.txt") / $vals"

# 50. 개요 문단의 자체 글자가 1x1 표 글자에 들어 있으면(라이브러리가 지움) 표를 제목으로 바꾸지 않는다
"$H" read "$T/sumbox.hwpx" > "$T/50.txt" 2>&1
grep -qF '| 요약 설명 |' "$T/50.txt" && ! grep -q '^#' "$T/50.txt" && grep -qxF '뒤 본문' "$T/50.txt" \
  && pass read-outline-text-inside-box || bad read-outline-text-inside-box "$(sed -n '2,8p' "$T/50.txt" | tr '\n' '/')"

# 51. 엔티티 복원은 라이브러리가 만든 &amp; &lt; &gt; 만: 링크 주소 '&copy' 는 그대로, 본문 'A &lt; B' 도 그대로
"$H" read "$T/urlent.hwpx" > "$T/51.txt" 2>&1
grep -qF '(https://example.com/?a=1&copy=2&sect=3)' "$T/51.txt" && grep -qxF 'A &lt; B' "$T/51.txt" \
  && pass read-entity-only-library-escapes || bad read-entity-only-library-escapes "$(sed -n '2,6p' "$T/51.txt" | tr '\n' '/')"

# 52. 줄바꿈이 든 개요 제목은 한 줄 제목으로
"$H" read "$T/hbr.hwpx" > "$T/52.txt" 2>&1
grep -qxF '# 1장 추진 배경' "$T/52.txt" && grep -qxF '본문' "$T/52.txt" && ! grep -qxF '추진 배경' "$T/52.txt" \
  && pass read-heading-linebreak || bad read-heading-linebreak "$(sed -n '2,6p' "$T/52.txt" | tr '\n' '/')"

# 53. 오른쪽 칸에 양식 개체(체크박스)가 있으면 fill 불가, 덮어쓰지 않는다
"$H" fields "$T/chkbox.hwpx" > "$T/53.txt" 2>&1
printf '{"동의": "예"}' > "$T/v33.json"
"$H" fill "$T/chkbox.hwpx" "$T/v33.json" "$T/o33.hwpx" > "$T/53b.txt" 2>&1; rc=$?
grep '동의' "$T/53.txt" | grep -q 'fill 불가: 오른쪽 칸에 그림·개체가 있음' && [ $rc -ne 0 ] && grep -q '^ERROR .*동의' "$T/53b.txt" && [ ! -e "$T/o33.hwpx" ] \
  && pass fill-form-control-cell || bad fill-form-control-cell "rc=$rc $(first "$T/53b.txt") / $(tr '\n' '/' < "$T/53.txt")"

# 54. 끝 표시가 없는 누름틀: fields 에 fill 불가, fill 은 한국어 ERROR(영어 라이브러리 문구 없음), 출력 없음
"$H" fields "$T/noend.hwpx" > "$T/54.txt" 2>&1
printf '{"X": "값"}' > "$T/v34.json"
"$H" fill "$T/noend.hwpx" "$T/v34.json" "$T/o34.hwpx" > "$T/54b.txt" 2>&1; rc=$?
grep -E '^- X ' "$T/54.txt" | grep -q 'fill 불가' && [ $rc -ne 0 ] && grep -q '^ERROR .*X' "$T/54b.txt" && ! grep -qi 'field\|has no' "$T/54b.txt" && [ ! -e "$T/o34.hwpx" ] \
  && pass fill-field-without-end || bad fill-field-without-end "rc=$rc $(first "$T/54b.txt") / $(tr '\n' '/' < "$T/54.txt")"

# 55~58 공통 픽스처
"$PY" -I -W ignore - "$T" <<'EOF'
import sys
from hwpx import HwpxDocument
T = sys.argv[1]
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
def h1(d): return str([s.id for s in d.styles.values() if str(s.name).replace(" ", "") == "개요1"][0])
def interleave(two_paras):
    d = HwpxDocument.new(); p = d.add_paragraph(""); p.add_form_field("A"); p.add_form_field("B")
    runs = list(p.element)                       # [빈 글자, A 시작, A 끝, B 시작, B 끝]
    p.element.remove(runs[3]); p.element.insert(2, runs[3])   # A 시작, B 시작, A 끝, B 끝
    if two_paras: p.element.remove(runs[4]); d.add_paragraph("").element.append(runs[4])
    return d
save(interleave(True), "cross2"); save(interleave(False), "cross1")
# 개요 1 문단 '요약' + 같은 글자의 사각형 '요약' + 1x1 표 '자료'(캡션 '첨부')
d = HwpxDocument.new(); p = d.add_paragraph("요약"); d.add_rectangle(paragraph=p).set_draw_text("요약")
t = p.add_table(1, 1); t.set_cell_text(0, 0, "자료"); t.set_caption("첨부")
d.add_paragraph("뒤 본문"); p.element.set("styleIDRef", h1(d)); save(d, "shpbox")
# 원문 그대로 나오는 글자: 링크 주소 '&amp;', GFM 표 캡션 'A &lt; B'. 본문 'x & y < z' 는 복원
d = HwpxDocument.new(); d.add_paragraph("앞").add_hyperlink("https://example.com/?q=&amp;", "링크")
t = d.add_table(1, 2); t.set_cell_text(0, 0, "x"); t.set_caption("A &lt; B")
d.add_paragraph("x & y < z"); save(d, "rawent")
# 굵게 + 줄바꿈인 개요 1 제목
d = HwpxDocument.new(); p = d.add_paragraph(""); p.add_run("1장\n추진 배경", bold=True)
d.add_paragraph("본문"); p.element.set("styleIDRef", h1(d)); save(d, "boldbr")
EOF

# 55. 여러 문단에 걸쳐 교차한 누름틀: 채우다 다른 누름틀의 끝 표시가 지워지면 순서와 상관없이 한국어 ERROR, 출력 없음
for n in 1 2 3; do
  case $n in 1) printf '{"A": "가", "B": "나"}' ;; 2) printf '{"B": "나", "A": "가"}' ;; 3) printf '{"B": "나"}' ;; esac > "$T/v35.json"
  "$H" fill "$T/cross2.hwpx" "$T/v35.json" "$T/o35.hwpx" > "$T/55.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR .*겹' "$T/55.txt" && ! grep -qi 'field\|has no' "$T/55.txt" && [ ! -e "$T/o35.hwpx" ] \
    && pass "fill-crossed-field-span-$n" || bad "fill-crossed-field-span-$n" "rc=$rc $(first "$T/55.txt")"
  rm -f "$T/o35.hwpx"
done
# 한 문단 안 교차는 라이브러리가 바르게 채운다: 두 값이 그대로 남으면 OK
printf '{"B": "나", "A": "가"}' > "$T/v36.json"
"$H" fill "$T/cross1.hwpx" "$T/v36.json" "$T/o36.hwpx" > "$T/55b.txt" 2>&1; rc=$?
vals=$(fieldvals "$T/o36.hwpx" 2>&1)
[ $rc -eq 0 ] && [ "$vals" = "A=가/B=나" ] && pass fill-crossed-field-one-para || bad fill-crossed-field-one-para "rc=$rc $(first "$T/55b.txt") vals=$vals"

# 56. 개요 문단 자체 글자가 도형 글자와 같아 라이브러리가 지우면 제목을 주지 않는다: 표·캡션·도형 글자가 남는다
"$H" read "$T/shpbox.hwpx" > "$T/56.txt" 2>&1
grep -qF '| 자료 |' "$T/56.txt" && grep -qF '첨부' "$T/56.txt" && grep -qxF '요약' "$T/56.txt" && ! grep -q '^#' "$T/56.txt" && grep -qxF '뒤 본문' "$T/56.txt" \
  && pass read-outline-text-in-shape || bad read-outline-text-in-shape "$(sed -n '2,10p' "$T/56.txt" | tr '\n' '/')"

# 57. 라이브러리가 이스케이프하지 않은 원문(링크 주소·GFM 표 캡션)의 엔티티는 그대로, 본문 글자 이스케이프만 복원
"$H" read "$T/rawent.hwpx" > "$T/57.txt" 2>&1
grep -qF '(https://example.com/?q=&amp;)' "$T/57.txt" && grep -qxF '**A &lt; B**' "$T/57.txt" && grep -qxF 'x & y < z' "$T/57.txt" \
  && pass read-raw-entities-kept || bad read-raw-entities-kept "$(sed -n '2,9p' "$T/57.txt" | tr '\n' '/')"

# 58. 굵은 글자에 줄바꿈이 든 개요 제목: 별표 없이 한 줄 제목
"$H" read "$T/boldbr.hwpx" > "$T/58.txt" 2>&1
grep -qxF '# 1장 추진 배경' "$T/58.txt" && ! grep -qF '**' "$T/58.txt" && grep -qxF '본문' "$T/58.txt" \
  && pass read-bold-heading-linebreak || bad read-bold-heading-linebreak "$(sed -n '2,6p' "$T/58.txt" | tr '\n' '/')"

# 59. 라이브러리가 저장하며 바꾸는 값(\r\n·\r → \n, 제어 문자 제거)도 정상 누름틀이면 OK: 요청 글자와 저장 글자를 그대로 비교하지 않는다
"$PY" -I -W ignore -c 'import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("").add_form_field("A"); d.add_paragraph("끝"); d.save_to_path(sys.argv[1])' "$T/onefield.hwpx"
for n in 1 2 3; do
  case $n in 1) printf '{"A": "가\\r\\n나"}' ;; 2) printf '{"A": "가\\r나"}' ;; 3) printf '{"A": "가\\u000b나"}' ;; esac > "$T/v59.json"
  rm -f "$T/o59.hwpx"
  "$H" fill "$T/onefield.hwpx" "$T/v59.json" "$T/o59.hwpx" > "$T/59.txt" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ -e "$T/o59.hwpx" ] && pass "fill-field-normalized-value-$n" || bad "fill-field-normalized-value-$n" "rc=$rc $(first "$T/59.txt")"
done

# 60~66 공통 픽스처
"$PY" -I -W ignore - "$T" <<'EOF'
import sys, copy, zipfile
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
def h1(d): return str([s.id for s in d.styles.values() if str(s.name).replace(" ", "") == "개요1"][0])
def body(d, text): q = d.add_paragraph(text); q.element.set("styleIDRef", "0"); return q
def textrun(like, text):
    r = copy.deepcopy(like); [r.remove(c) for c in list(r)]; etree.SubElement(r, HP + "t").text = text; return r
# 60. 한 문단 교차 + B 시작 뒤 빈 글자 run: A·B 가 같은 hp:t 를 첫 글자 칸으로 공유
d = HwpxDocument.new(); p = d.add_paragraph(""); p.add_form_field("A"); p.add_form_field("B")
runs = list(p.element)                       # [빈 글자, A 시작, A 끝, B 시작, B 끝]
p.element.remove(runs[3]); p.element.insert(2, runs[3])   # A 시작, B 시작, A 끝, B 끝
p.element.insert(3, textrun(runs[0], None)); save(d, "sharet")
# 61. B 시작·A 시작이 문단 1, 문단 2 의 한 run 에 B 끝·A 끝
d = HwpxDocument.new(); p = d.add_paragraph(""); p.add_form_field("A"); p.add_form_field("B")
a, A, b, B = list(p.element)[1:5]
for x in (a, A, b, B): p.element.remove(x)
p.element.append(b); p.element.append(a)
B.insert(1, A.find(HP + "ctrl")); d.add_paragraph("").element.append(B); save(d, "orphan")
# 62. 자체 글자 없는 개요 1 문단에 1x1 표 '자료' + 각주
d = HwpxDocument.new(); p = d.add_paragraph(""); p.element.set("styleIDRef", h1(d))
p.add_table(1, 1).set_cell_text(0, 0, "자료"); p.add_footnote("각주내용"); body(d, "뒤 본문"); save(d, "fnbox")
# 63. 원문 비문자(U+FDD0~FDD5): 본문과 병합 표 칸
d = HwpxDocument.new(); body(d, "x﷐y ﷑z﷒﷓﷔﷕")
t = d.add_table(2, 2); t.set_cell_text(0, 0, "p﷐q"); t.merge_cells(0, 1, 1, 1)
body(d, "a & b"); save(d, "nonchar")
# 64. GFM 표 캡션 글자가 '예시 <table>\n<tr>'
d = HwpxDocument.new(); t = d.add_table(1, 2); t.set_cell_text(0, 0, "x"); t.set_caption("예시")
for e in d.sections[0].element.iter(HP + "t"):
    if e.text == "예시": e.text = "예시 <table>\n<tr>"
body(d, "x & y < z"); save(d, "captag")
# 65. 병합 표 칸 링크 주소에 '</tr></table>', 다른 칸 'A < B', 뒤 본문 'C & D'
d = HwpxDocument.new(); t = d.add_table(2, 2)
t.cell(0, 0).paragraphs[0].add_hyperlink("https://x/\n</tr>\n</table>", "링크")
t.set_cell_text(1, 0, "A < B"); t.merge_cells(0, 1, 1, 1); body(d, "뒤 C & D"); save(d, "linktag")
# 66. section0 압축 자료가 깨진 파일
d = HwpxDocument.new(); body(d, "본문"); d.add_paragraph("").add_form_field("X"); save(d, "deflate")
with zipfile.ZipFile(f"{T}/deflate.hwpx") as z: info = z.getinfo("Contents/section0.xml")
with open(f"{T}/deflate.hwpx", "r+b") as f:
    f.seek(info.header_offset + 26); n, m = int.from_bytes(f.read(2), "little"), int.from_bytes(f.read(2), "little")
    f.seek(info.header_offset + 30 + n + m); f.write(b"\xff" * info.compress_size)
EOF

# 60. 한 문단 교차 누름틀이 빈 글자 칸(hp:t)을 공유: 한쪽을 채우면 다른 쪽 값도 바뀐다 → 순서와 상관없이 한국어 ERROR, 출력 없음
for n in 1 2 3; do
  case $n in 1) printf '{"A": "가", "B": "나"}' ;; 2) printf '{"B": "나", "A": "가"}' ;; 3) printf '{"B": "나"}' ;; esac > "$T/v60.json"
  rm -f "$T/o60.hwpx"
  "$H" fill "$T/sharet.hwpx" "$T/v60.json" "$T/o60.hwpx" > "$T/60.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR .*겹' "$T/60.txt" && ! grep -qi 'field\|has no' "$T/60.txt" && [ ! -e "$T/o60.hwpx" ] \
    && pass "fill-shared-text-node-$n" || bad "fill-shared-text-node-$n" "rc=$rc $(first "$T/60.txt")"
done

# 61. 끝 표시만 남기고 시작 표시가 사라지는 교차(고아 끝 표시): 순서와 상관없이 '겹' ERROR, 출력 없음
for n in 1 2 3; do
  case $n in 1) printf '{"B": "나"}' ;; 2) printf '{"B": "나", "A": "가"}' ;; 3) printf '{"A": "가", "B": "나"}' ;; esac > "$T/v61.json"
  rm -f "$T/o61.hwpx"
  "$H" fill "$T/orphan.hwpx" "$T/v61.json" "$T/o61.hwpx" > "$T/61.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR .*겹' "$T/61.txt" && ! grep -qi 'field\|has no' "$T/61.txt" && [ ! -e "$T/o61.hwpx" ] \
    && pass "fill-orphan-field-end-$n" || bad "fill-orphan-field-end-$n" "rc=$rc $(first "$T/61.txt")"
done

# 62. 글자 없이 각주만 있는 개요 문단: 제목을 주지 않는다(표·각주·뒤 본문이 남는다)
"$H" read "$T/fnbox.hwpx" > "$T/62.txt" 2>&1
grep -qxF '| 자료 |' "$T/62.txt" && grep -qxF '[^fn1]: 각주내용' "$T/62.txt" && ! grep -q '^#' "$T/62.txt" && grep -qxF '뒤 본문' "$T/62.txt" \
  && pass read-outline-footnote-only || bad read-outline-footnote-only "$(sed -n '2,10p' "$T/62.txt" | tr '\n' '/')"

# 63. 원문에 든 비문자(U+FDD0~FDD5)는 그대로: 본문·병합 표 칸 모두. 본문 'a & b' 는 복원
"$H" read "$T/nonchar.hwpx" > "$T/63.txt" 2>&1
"$PY" -I -c 'import sys
s = open(sys.argv[1], encoding="utf-8").read().splitlines()
ok = "x﷐y ﷑z﷒﷓﷔﷕" in s and "<th>p﷐q</th>" in s and "a & b" in s and s[0].startswith("OK ")
sys.exit(0 if ok else 1)' "$T/63.txt" && pass read-raw-noncharacters || bad read-raw-noncharacters "$(sed -n '2,6p' "$T/63.txt" | tr '\n' '/')"

# 64. GFM 표 캡션 글자 '<table>' 은 HTML 표 경계가 아니다: 뒤 본문 'x & y < z' 복원
"$H" read "$T/captag.hwpx" > "$T/64.txt" 2>&1
grep -qxF 'x & y < z' "$T/64.txt" && pass read-caption-table-tag-text || bad read-caption-table-tag-text "$(sed -n '2,9p' "$T/64.txt" | tr '\n' '/')"

# 65. HTML 표 칸 링크 주소의 '</table>' 은 표 끝이 아니다: 표 안 'A &lt; B' 는 엔티티, 뒤 본문 'C & D' 는 복원
"$H" read "$T/linktag.hwpx" > "$T/65.txt" 2>&1
grep -qxF '<td>A &lt; B</td>' "$T/65.txt" && grep -qxF '뒤 C & D' "$T/65.txt" \
  && pass read-link-table-tag-text || bad read-link-table-tag-text "$(sed -n '2,14p' "$T/65.txt" | tr '\n' '/')"

# 66. 압축 자료가 깨진 파일: 모든 명령이 '손상' 한국어 ERROR(내부 오류·영어 예외 없음), fill 출력 없음
printf '{"X": "값"}' > "$T/v66.json"
for c in read fields validate fill; do
  if [ $c = fill ]; then "$H" fill "$T/deflate.hwpx" "$T/v66.json" "$T/o66.hwpx" > "$T/66.txt" 2>&1; else "$H" $c "$T/deflate.hwpx" > "$T/66.txt" 2>&1; fi; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR .*손상' "$T/66.txt" && ! grep -q '내부 오류\|decompress' "$T/66.txt" && [ ! -e "$T/o66.hwpx" ] \
    && pass "corrupt-deflate-$c" || bad "corrupt-deflate-$c" "rc=$rc $(first "$T/66.txt")"
done

# 67~69 공통 픽스처
"$PY" -I -W ignore - "$T" <<'EOF'
import sys
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
def body(d, text): q = d.add_paragraph(text); q.element.set("styleIDRef", "0"); return q
# 68. 빈 누름틀 A 안에 빈 누름틀 B (다른 누름틀 없음)
d = HwpxDocument.new()
for n in "AB": d.fields.add(n)
pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
for off, run in enumerate(list(pb)): pa.insert(1 + off, run)
pb.getparent().remove(pb); save(d, "nest2")
# 69. 본문에 비문자 U+FDD0~U+FDEF 32개 전부 + GFM 표 캡션 글자 그대로 '&lt;' + 본문 글자 'a &lt; b'
d = HwpxDocument.new(); body(d, "".join(chr(c) for c in range(0xFDD0, 0xFDF0)))
t = d.add_table(1, 2); t.set_cell_text(0, 0, "칸"); t.set_caption("캡")
for e in d.sections[0].element.iter(HP + "t"):
    if e.text == "캡": e.text = "&lt;"
body(d, "a &lt; b"); save(d, "allnc")
EOF

# 67. resolve_marked 는 한 번 훑기: 무작위·경계 입력에서 이전 구현과 결과가 같고, 표식이 많은 큰 글(약 480K자)도 1초 안에 끝난다
"$PY" -I -B -W ignore - "$KIT/skills/hwpx/scripts/hwpx_tool.py" > "$T/67.txt" 2>&1 <<'EOF'
import importlib.util, random, sys, time
spec = importlib.util.spec_from_file_location("hwpx_tool_t67", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
def oracle(md, markers):   # fix8 구현(O(n²)) 그대로: 의미 기준
    outside = str.maketrans({m: ch for m, ch in zip(markers[:3], "&<>")})
    inside = str.maketrans({m: ent for m, ent in zip(markers[:3], ("&amp;", "&lt;", "&gt;"))})
    out, depth, pos = [], 0, 0
    while pos < len(md):
        hits = [(idx, which) for which, marker in enumerate(markers) if (idx := md.find(marker, pos)) != -1]
        idx, which = min(hits) if hits else (len(md), -1)
        out.append(md[pos:idx].translate(outside if depth == 0 else inside))
        depth = depth + 1 if which == 3 else max(0, depth - 1) if which == 4 else depth
        if 0 <= which < 3: out.append(markers[which].translate(outside if depth == 0 else inside))
        pos = idx + 1
    return "".join(out)
rnd, bad = random.Random(67), []
for M in (tuple(chr(0xFDD0 + i) for i in range(5)), (chr(0xFFFE), chr(0xFFFF), chr(0x1FFFE), chr(0x10FFFF), chr(0x2FFFF))):
    alpha = list(M) * 3 + ["&", "<", ">", "&amp;", "a", "가", " ", "\n", "|", "<table>", "</table>"]
    cases = ["", "".join(M), M[4] + M[3], M[4] * 3 + "x" + M[3] + M[0] + M[4] + M[1], "x" + M[0], M[3] * 3 + M[2] + M[4] * 5 + M[2]]
    cases += ["".join(rnd.choice(alpha) for _ in range(rnd.randint(0, 60))) for _ in range(2000)]
    bad += [c for c in cases if mod.resolve_marked(c, M) != oracle(c, M)]
M = tuple(chr(0xFDD0 + i) for i in range(5))
big = ("가나다라 마바" + M[0]) * 60000
t0 = time.perf_counter(); got = mod.resolve_marked(big, M); dt = time.perf_counter() - t0
print("mismatch", len(bad), repr(bad[:2]), "time %.3f" % dt)
sys.exit(0 if not bad and got == big.replace(M[0], "&") and dt < 1.0 else 1)
EOF
[ $? -eq 0 ] && pass read-resolve-marked-linear || bad read-resolve-marked-linear "$(tail -1 "$T/67.txt")"

# 사전 판정(field_nesting)을 끈 채 hwpx_tool 실행: 채운 뒤 불변식 문구 시험용. 사용: nonest fill <문서> <json> <출력>
nonest() { "$PY" -I -B -W ignore - "$KIT/skills/hwpx/scripts/hwpx_tool.py" "$@" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hwpx_tool_nn", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.field_nesting = lambda doc: {}
sys.exit(mod.run(sys.argv[2:]))
EOF
}
# 68. 다른 누름틀을 품거나 품긴 누름틀은 fields 에서 'fill 불가' (fill 도 같은 사유로 거부). 요청 안 한 누름틀 손상은 '채우지 못한 키' 로 적지 않는다
"$H" fields "$T/nest2.hwpx" > "$T/68a.txt" 2>&1
grep -qxF -- '- A (누름틀 필드) (fill 불가: 다른 누름틀 B 를 품고 있음)' "$T/68a.txt" && grep -qxF -- '- B (누름틀 필드) (fill 불가: 다른 누름틀 A 안에 있음)' "$T/68a.txt" \
  && pass fields-nested-field-marked || bad fields-nested-field-marked "$(sed -n '2,4p' "$T/68a.txt" | tr '\n' '/')"
"$H" fields "$T/nestf.hwpx" > "$T/68b.txt" 2>&1
grep '^- A ' "$T/68b.txt" | grep -q 'fill 불가: 다른 누름틀 B 를 품고 있음' && grep '^- B ' "$T/68b.txt" | grep -q 'fill 불가: 다른 누름틀 A 안에 있음' \
  && ! grep '^- [CD] ' "$T/68b.txt" | grep -q 'fill 불가' && pass fields-nested-field-siblings || bad fields-nested-field-siblings "$(sed -n '2,6p' "$T/68b.txt" | tr '\n' '/')"
printf '{"B": "나"}' > "$T/v68.json"; rm -f "$T/o68.hwpx"
"$H" fill "$T/nest2.hwpx" "$T/v68.json" "$T/o68.hwpx" > "$T/68c.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(first "$T/68c.txt")" = "ERROR 채우지 못한 키: B(다른 누름틀 A 안에 있음)" ] && [ ! -e "$T/o68.hwpx" ] \
  && pass fill-nested-inner-reason || bad fill-nested-inner-reason "rc=$rc $(first "$T/68c.txt")"
rm -f "$T/o68.hwpx"
"$H" fill "$T/sharet.hwpx" "$T/v68.json" "$T/o68.hwpx" > "$T/68d.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(first "$T/68d.txt")" = "ERROR 채우지 못한 키: B(다른 누름틀 A 와 구간이 겹침)" ] && [ ! -e "$T/o68.hwpx" ] \
  && pass fill-unrequested-damage-prejudged || bad fill-unrequested-damage-prejudged "rc=$rc $(first "$T/68d.txt")"
# 사전 판정을 끄면 채운 뒤 불변식이 요청 안 한 A 의 손상을 '요청한 키를 채우면 다른 누름틀이 바뀜' 으로 적는다
rm -f "$T/o68.hwpx"
nonest fill "$T/sharet.hwpx" "$T/v68.json" "$T/o68.hwpx" > "$T/68e.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR 요청한 키(B)를 채우면 다른 누름틀이 바뀜: A(.*겹' "$T/68e.txt" && ! grep -q '채우지 못한 키: A' "$T/68e.txt" && [ ! -e "$T/o68.hwpx" ] \
  && pass fill-unrequested-damage-wording || bad fill-unrequested-damage-wording "rc=$rc $(first "$T/68e.txt")"

# 69. 비문자 U+FDD0~U+FDEF 32개를 모두 쓴 문서도 표식 방식으로 읽는다: 캡션 글자 '&lt;' 그대로, 본문 비문자 그대로, 본문 'a &lt; b' 그대로
"$H" read "$T/allnc.hwpx" > "$T/69.txt" 2>&1
"$PY" -I -c 'import sys
s = open(sys.argv[1], encoding="utf-8").read().splitlines()
ok = s[0].startswith("OK ") and "**&lt;**" in s and "a &lt; b" in s and "".join(chr(c) for c in range(0xFDD0, 0xFDF0)) in s
sys.exit(0 if ok else 1)' "$T/69.txt" && pass read-all-fdd-noncharacters || bad read-all-fdd-noncharacters "$(sed -n '3,4p' "$T/69.txt" | tr '\n' '/')"


# 70~73 공통 픽스처 (v10 리뷰 재현)
"$PY" -I -W ignore - "$T" <<'EOF'
import sys, copy
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
def first(el, tag): return next(el.iter(HP + tag))
def begins(d): return list(d.sections[0].element.iter(HP + "fieldBegin"))
def ends(d): return list(d.sections[0].element.iter(HP + "fieldEnd"))
def textrun(like, text):
    r = copy.deepcopy(like); [r.remove(c) for c in list(r)]; etree.SubElement(r, HP + "t").text = text; return r
# h1 / h1u: 문단1=[A 시작], 문단2=[B 시작, 끝 없음], 문단3=[A 끝]. h1u 는 B 이름 없음
for name, bname in (("h1", "B"), ("h1u", "")):
    d = HwpxDocument.new()
    for n in ("A", bname or "Z"): d.fields.add(n)
    pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
    if not bname: first(pb, "fieldBegin").set("name", "")
    pb.remove(list(pb)[1])
    endA = list(pa)[1]; pa.remove(endA)
    d.add_paragraph("").element.append(endA); save(d, name)
# dupid: A·B·C 각자 끝 있음, C 의 id/beginIDRef = A 의 id
d = HwpxDocument.new()
for n in "ABC": d.fields.add(n)
ps = [d.paragraphs[i].element for i in (1, 2, 3)]
aid = first(ps[0], "fieldBegin").get("id")
first(ps[2], "fieldBegin").set("id", aid); first(ps[2], "fieldEnd").set("beginIDRef", aid); save(d, "dupid")
# strayend: 맨 앞 문단에 A 의 id 를 가리키는 떠도는 fieldEnd, 그 뒤 독립 누름틀 S, A
d = HwpxDocument.new()
p0 = d.add_paragraph("앞")
for n in ("S", "A"): d.add_paragraph("").add_form_field(n)
aid = begins(d)[1].get("id")
endrun = [r for r in d.paragraphs[2].element if r.find(f"{HP}ctrl/{HP}fieldEnd") is not None][0]
stray = copy.deepcopy(endrun); [stray.remove(c) for c in list(stray) if c.tag != HP + "ctrl"]
stray.find(f"{HP}ctrl/{HP}fieldEnd").set("beginIDRef", aid); p0.element.append(stray); save(d, "strayend")
# samename: A₁ 따로, 그 뒤 한 문단 [B 시작, A₂ 시작, 빈 t, B 끝, A₂ 끝]
d = HwpxDocument.new(); d.fields.add("A")
p = d.add_paragraph(""); p.add_form_field("B"); p.add_form_field("A")
runs = list(p.element)
p.element.remove(runs[3]); p.element.insert(2, runs[3]); p.element.insert(3, textrun(runs[0], None)); save(d, "samename")
# nlnest: 이름 있는 A 안에 이름 없는 누름틀
d = HwpxDocument.new()
for n in ("A", "Z"): d.fields.add(n)
pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
for off, run in enumerate(list(pb)): pa.insert(1 + off, run)
pb.getparent().remove(pb)
begins(d)[1].set("name", ""); save(d, "nlnest")
EOF

# 70. 누름틀 시작·끝 짝은 라이브러리처럼 '시작 뒤 처음 나오는 같은 id 의 끝'. 중복 id·시작보다 앞의 떠도는 끝이 거짓 중첩을 만들지 않는다
"$H" fields "$T/dupid.hwpx" > "$T/70a.txt" 2>&1
printf '{"A": "가", "B": "나", "C": "다"}' > "$T/v70a.json"; rm -f "$T/o70a.hwpx"
"$H" fill "$T/dupid.hwpx" "$T/v70a.json" "$T/o70a.hwpx" > "$T/70b.txt" 2>&1; rc=$?
vals=$(fieldvals "$T/o70a.hwpx" 2>&1)
grep -q '^OK ' "$T/70a.txt" && ! grep -q 'fill 불가' "$T/70a.txt" && [ $rc -eq 0 ] && [ "$vals" = "A=가/B=나/C=다" ] \
  && pass fill-duplicate-field-id || bad fill-duplicate-field-id "rc=$rc $(first "$T/70b.txt") / $(sed 1d "$T/70a.txt" | tr '\n' '/') / $vals"
"$H" fields "$T/strayend.hwpx" > "$T/70c.txt" 2>&1
printf '{"A": "가", "S": "나"}' > "$T/v70b.json"; rm -f "$T/o70b.hwpx"
"$H" fill "$T/strayend.hwpx" "$T/v70b.json" "$T/o70b.hwpx" > "$T/70d.txt" 2>&1; rc=$?
vals=$(fieldvals "$T/o70b.hwpx" 2>&1)
grep -q '^OK ' "$T/70c.txt" && ! grep -q 'fill 불가' "$T/70c.txt" && [ $rc -eq 0 ] && [ "$vals" = "S=나/A=가" ] \
  && pass fill-stray-field-end-before || bad fill-stray-field-end-before "rc=$rc $(first "$T/70d.txt") / $(sed 1d "$T/70c.txt" | tr '\n' '/') / $vals"

# 71. 끝 표시가 있는 누름틀 A 의 구간 안에 끝 없는 누름틀 B 의 시작이 있으면 A 도 fill 불가(채우면 B 시작이 지워진다)
"$H" fields "$T/h1.hwpx" > "$T/71a.txt" 2>&1
printf '{"A": "값"}' > "$T/v71.json"; rm -f "$T/o71.hwpx"
"$H" fill "$T/h1.hwpx" "$T/v71.json" "$T/o71.hwpx" > "$T/71b.txt" 2>&1; rc=$?
grep -qxF -- '- A (누름틀 필드) (fill 불가: 다른 누름틀 B 를 품고 있음)' "$T/71a.txt" && grep -qxF -- '- B (누름틀 필드) (fill 불가: 누름틀 끝 표시가 없음)' "$T/71a.txt" \
  && [ $rc -ne 0 ] && [ "$(first "$T/71b.txt")" = "ERROR 채우지 못한 키: A(다른 누름틀 B 를 품고 있음)" ] && [ ! -e "$T/o71.hwpx" ] \
  && pass fill-field-holds-unended || bad fill-field-holds-unended "rc=$rc $(first "$T/71b.txt") / $(sed 1d "$T/71a.txt" | tr '\n' '/')"
"$H" fields "$T/h1u.hwpx" > "$T/71c.txt" 2>&1
grep -qxF -- '- A (누름틀 필드) (fill 불가: 다른 누름틀 (이름 없음) 를 품고 있음)' "$T/71c.txt" \
  && pass fields-holds-unended-nameless || bad fields-holds-unended-nameless "$(sed 1d "$T/71c.txt" | tr '\n' '/')"
# 사전 표시를 꺼도(field_nesting 이 빈 결과) 채우기 전후 불변식이 끝 없는 누름틀 시작의 사라짐을 ERROR 로 막는다
rm -f "$T/o71b.hwpx"
"$PY" -I -B -W ignore - "$KIT/skills/hwpx/scripts/hwpx_tool.py" "$T/h1.hwpx" "$T/v71.json" "$T/o71b.hwpx" > "$T/71d.txt" 2>&1 <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hwpx_tool_t71", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.field_nesting = lambda doc: {}
sys.exit(mod.run(["fill", *sys.argv[2:5]]))
EOF
rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR 요청한 키(A)를 채우면 다른 누름틀이 바뀜: B(' "$T/71d.txt" && [ ! -e "$T/o71b.hwpx" ] \
  && pass fill-unended-begin-invariant || bad fill-unended-begin-invariant "rc=$rc $(first "$T/71d.txt")"

# 72. 같은 이름의 다른 누름틀이 손상되면 요청 키 자신의 사유를 덮지 않고 '요청한 키를 채우면 다른 누름틀이 바뀜' 묶음으로
printf '{"A": "가", "B": "나"}' > "$T/v72.json"; rm -f "$T/o72.hwpx"
"$H" fill "$T/samename.hwpx" "$T/v72.json" "$T/o72.hwpx" > "$T/72.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(first "$T/72.txt")" = "ERROR 채우지 못한 키: A(같은 이름의 누름틀이 여러 개), B(다른 누름틀 A 와 구간이 겹침)" ] && [ ! -e "$T/o72.hwpx" ] \
  && pass fill-same-name-prejudged || bad fill-same-name-prejudged "rc=$rc $(first "$T/72.txt")"
rm -f "$T/o72.hwpx"
nonest fill "$T/samename.hwpx" "$T/v72.json" "$T/o72.hwpx" > "$T/72b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(first "$T/72b.txt")" = "ERROR 채우지 못한 키: A(같은 이름의 누름틀이 여러 개); 요청한 키(B)를 채우면 다른 누름틀이 바뀜: A(다른 누름틀과 구간이 겹쳐 채울 수 없음)" ] && [ ! -e "$T/o72.hwpx" ] \
  && pass fill-same-name-damage-wording || bad fill-same-name-damage-wording "rc=$rc $(first "$T/72b.txt")"

# 73. 이름 없는 누름틀은 사유에 '(이름 없음)'
"$H" fields "$T/nlnest.hwpx" > "$T/73a.txt" 2>&1
printf '{"A": "가"}' > "$T/v73.json"; rm -f "$T/o73.hwpx"
"$H" fill "$T/nlnest.hwpx" "$T/v73.json" "$T/o73.hwpx" > "$T/73b.txt" 2>&1; rc=$?
grep -qxF -- '- A (누름틀 필드) (fill 불가: 다른 누름틀 (이름 없음) 를 품고 있음)' "$T/73a.txt" \
  && [ $rc -ne 0 ] && [ "$(first "$T/73b.txt")" = "ERROR 채우지 못한 키: A(다른 누름틀 (이름 없음) 를 품고 있음)" ] && [ ! -e "$T/o73.hwpx" ] \
  && pass fields-nameless-field-reason || bad fields-nameless-field-reason "rc=$rc $(first "$T/73b.txt") / $(sed 1d "$T/73a.txt" | tr '\n' '/')"
# 74~79 공통 픽스처 (v11 리뷰 재현)
"$PY" -I -W ignore - "$T" <<'EOF'
import sys, copy
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
def first(el, tag): return next(el.iter(HP + tag))
def ctrl_of(p, tag): return next(c for c in p.iter(HP + "ctrl") if c.find(HP + tag) is not None)
def ctrl_run(p, tag, nth=0): return [r for r in p if r.find(f"{HP}ctrl/{HP}{tag}") is not None][nth]
def add_t(run, text): etree.SubElement(run, HP + "t").text = text
def tnode(text): e = etree.Element(HP + "t"); e.text = text; return e
def two(a, b):
    d = HwpxDocument.new(); p = d.add_paragraph(""); p.add_form_field(a); p.add_form_field(b)
    return d, p.element
def runs4(p): return [ctrl_run(p, t, n) for n in (0, 1) for t in ("fieldBegin", "fieldEnd")]
# cellend: 문단1=[A 시작], 표(칸 안에 A id 끝 사본), 문단3=[B 시작, 끝 없음], 문단4=[A 끝]
d = HwpxDocument.new(); d.fields.add("A")
pa = d.paragraphs[1].element; endA = list(pa)[1]; pa.remove(endA)
t = d.add_table(1, 1); t.set_cell_text(0, 0, "칸")
next(t.element.iter(HP + "tc")).find(f".//{HP}p").append(copy.deepcopy(endA))
d.fields.add("B"); pb = d.paragraphs[-1].element; pb.remove(list(pb)[1])
d.add_paragraph("").element.append(endA); save(d, "cellend")
# onerun: 한 문단 한 run 에 [A 시작, B 시작(끝 없음), A 끝], 글자 없음
d = HwpxDocument.new(); d.fields.add("A"); d.fields.add("B")
pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
ea, bb = ctrl_of(pa, "fieldEnd"), ctrl_of(pb, "fieldBegin"); run0 = list(pa)[0]
for r in list(pa)[1:]: pa.remove(r)
run0.append(bb); run0.append(ea); pb.getparent().remove(pb); save(d, "onerun")
# sepruns: [A 시작][빈 t][B 시작(끝 없음)][빈 t][A 끝] 을 각자 run 으로
d = HwpxDocument.new(); d.fields.add("A"); d.fields.add("B")
pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
ba, ea, bb = ctrl_of(pa, "fieldBegin"), ctrl_of(pa, "fieldEnd"), ctrl_of(pb, "fieldBegin")
runs = list(pa); like = runs[0]
for r in runs: pa.remove(r)
for kids in ([ba], [tnode(None)], [bb], [tnode(None)], [ea]):
    r = copy.deepcopy(like); [r.remove(c) for c in list(r)]; [r.append(k) for k in kids]; pa.append(r)
pb.getparent().remove(pb); save(d, "sepruns")
# f1in: 한 문단 [A 시작][t][B 시작(끝 없음)][t][A 끝]
d, p = two("A", "B"); rA, rAe, rB, rBe = runs4(p)
rBe.remove(rBe.find(f"{HP}ctrl")); add_t(rA, ""); p.remove(rB); p.insert(p.index(rAe), rB); add_t(rB, ""); save(d, "f1in")
# f2dup: 한 문단 [X 시작 #k][t][Y 시작 #k][t][끝 #k] (끝 하나를 두 시작이 공유)
d, p = two("X", "Y"); rX, rXe, rY, rYe = runs4(p)
k = first(rX, "fieldBegin").get("id"); first(rY, "fieldBegin").set("id", k); first(rYe, "fieldEnd").set("beginIDRef", k)
rXe.remove(rXe.find(f"{HP}ctrl")); add_t(rX, ""); add_t(rY, ""); save(d, "f2dup")
# f3cross: 한 문단 [A 시작][t][B 시작][t][A 끝][B 끝] — 엇갈림
d, p = two("A", "B"); rA, rAe, rB, rBe = runs4(p)
add_t(rA, ""); p.remove(rB); p.insert(p.index(rAe), rB); add_t(rB, ""); save(d, "f3cross")
# f5vcross: f3cross 와 같되 A 에 기존 값 '기존'
d, p = two("A", "B"); rA, rAe, rB, rBe = runs4(p)
add_t(rA, "기존"); p.remove(rB); p.insert(p.index(rAe), rB); add_t(rB, ""); save(d, "f5vcross")
# samedmg: 문단1=A₁(y) 시작, 문단2=B(x) 시작, 문단3=A₂(x) 시작, 문단4=y 끝, 문단5=x 끝
d = HwpxDocument.new()
for n in ("A", "B", "A"): d.fields.add(n)
ps = [d.paragraphs[i].element for i in (1, 2, 3)]; ends = []
for p in ps: r = list(p)[1]; p.remove(r); ends.append(r)
first(ps[2], "fieldBegin").set("id", first(ps[1], "fieldBegin").get("id"))
d.add_paragraph("").element.append(ends[0]); d.add_paragraph("").element.append(ends[1]); save(d, "samedmg")
# plain11: 정상 A 하나 / tbl11: 1x2 표 '이름' | 빈 칸
d = HwpxDocument.new(); d.fields.add("A"); save(d, "plain11")
d = HwpxDocument.new(); t = d.add_table(1, 2); t.set_cell_text(0, 0, "이름"); save(d, "tbl11")
# cap26: O01⊃I01 … O26⊃I26 (시범 대상 52개) 뒤에 평범한 Z
d = HwpxDocument.new()
for n in range(1, 27):
    d.fields.add(f"O{n:02d}"); d.fields.add(f"I{n:02d}")
    pa, pb = d.paragraphs[-2].element, d.paragraphs[-1].element
    for off, run in enumerate(list(pb)): pa.insert(1 + off, run)
    pb.getparent().remove(pb)
d.fields.add("Z"); save(d, "cap26")
EOF
# fill 한 번: $1=문서 $2=JSON 글자 $3=태그. rc, $T/$3.txt, 출력 $T/o$3.hwpx
fill11() { printf '%s' "$2" > "$T/v$3.json"; rm -f "$T/o$3.hwpx"; "$H" fill "$T/$1.hwpx" "$T/v$3.json" "$T/o$3.hwpx" > "$T/$3.txt" 2>&1; }
nfill11() { printf '%s' "$2" > "$T/v$3.json"; rm -f "$T/o$3.hwpx"; nonest fill "$T/$1.hwpx" "$T/v$3.json" "$T/o$3.hwpx" > "$T/$3.txt" 2>&1; }
# 실패 확인: $1=태그 $2=기대 첫 줄 $3=시험 이름
want_err() { [ $rc -ne 0 ] && [ "$(first "$T/$1.txt")" = "$2" ] && [ ! -e "$T/o$1.hwpx" ] && ! grep -q Traceback "$T/$1.txt" \
  && pass "$3" || bad "$3" "rc=$rc $(first "$T/$1.txt")"; }
# 성공 확인: $1=태그 $2=기대 fieldvals $3=시험 이름
want_ok() { local v; v=$(fieldvals "$T/o$1.hwpx" 2>&1)
  [ $rc -eq 0 ] && grep -q '^OK ' "$T/$1.txt" && [ "$v" = "$2" ] && pass "$3" || bad "$3" "rc=$rc $(first "$T/$1.txt") / $v"; }

# 74. 시범 채우기 사전 판정: 끝 있는 누름틀 구간이 다른 표시를 품는 경우 사본에 채워 보고 실제로 망가지는 것만 fill 불가
"$H" fields "$T/cellend.hwpx" > "$T/74a.txt" 2>&1
fill11 cellend '{"A": "값"}' 74b; rc=$?
grep -qxF -- '- A (누름틀 필드) (fill 불가: 다른 누름틀 B 를 품고 있음)' "$T/74a.txt" && pass trial-cellend-fields || bad trial-cellend-fields "$(sed 1d "$T/74a.txt" | tr '\n' '/')"
want_err 74b "ERROR 채우지 못한 키: A(다른 누름틀 B 를 품고 있음)" trial-cellend-fill
for f in onerun sepruns f1in; do
  "$H" fields "$T/$f.hwpx" > "$T/74c-$f.txt" 2>&1
  grep -qxF -- '- A (누름틀 필드)' "$T/74c-$f.txt" && pass "trial-$f-fields" || bad "trial-$f-fields" "$(sed 1d "$T/74c-$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "값"}' "74d$f"; rc=$?; want_ok "74d$f" "A=값/B=" "trial-$f-fill"
done
"$H" fields "$T/f3cross.hwpx" > "$T/74e.txt" 2>&1
grep -qxF -- '- A (누름틀 필드)' "$T/74e.txt" && grep -qxF -- '- B (누름틀 필드) (fill 불가: 다른 누름틀 A 와 구간이 겹침)' "$T/74e.txt" \
  && pass trial-cross-fields || bad trial-cross-fields "$(sed 1d "$T/74e.txt" | tr '\n' '/')"
fill11 f3cross '{"A": "가"}' 74f; rc=$?; want_ok 74f "A=가/B=" trial-cross-fill-a
fill11 f3cross '{"B": "나"}' 74g; rc=$?; want_err 74g "ERROR 채우지 못한 키: B(다른 누름틀 A 와 구간이 겹침)" trial-cross-fill-b
"$H" fields "$T/f2dup.hwpx" > "$T/74h.txt" 2>&1
grep -qxF -- '- X (누름틀 필드)' "$T/74h.txt" && grep -qxF -- '- Y (누름틀 필드) (fill 불가: 다른 누름틀 X 안에 있음)' "$T/74h.txt" \
  && pass trial-shared-end-fields || bad trial-shared-end-fields "$(sed 1d "$T/74h.txt" | tr '\n' '/')"
# 시범 상한 50개: 51·52번째(O26·I26)만 '구조가 복잡해 미리 판정 못 함', 앞은 실제 사유, 뒤의 평범한 Z 는 영향 없음
"$H" fields "$T/cap26.hwpx" > "$T/74i.txt" 2>&1
fill11 cap26 '{"Z": "끝"}' 74j; rc=$?
cx=$(grep -c '(fill 불가: 구조가 복잡해 미리 판정 못 함)$' "$T/74i.txt")
grep -qxF -- '- O01 (누름틀 필드) (fill 불가: 다른 누름틀 I01 를 품고 있음)' "$T/74i.txt" \
  && grep -qxF -- '- I25 (누름틀 필드) (fill 불가: 다른 누름틀 O25 안에 있음)' "$T/74i.txt" \
  && grep -qxF -- '- O26 (누름틀 필드) (fill 불가: 구조가 복잡해 미리 판정 못 함)' "$T/74i.txt" \
  && grep -qxF -- '- I26 (누름틀 필드) (fill 불가: 구조가 복잡해 미리 판정 못 함)' "$T/74i.txt" \
  && grep -qxF -- '- Z (누름틀 필드)' "$T/74i.txt" && [ "$cx" = 2 ] && pass trial-cap-fields || bad trial-cap-fields "cx=$cx $(grep -E '^- (O01|I25|O26|I26|Z) ' "$T/74i.txt" | tr '\n' '/')"
[ $rc -eq 0 ] && grep -q '^OK ' "$T/74j.txt" && pass trial-cap-plain-fill || bad trial-cap-plain-fill "rc=$rc $(first "$T/74j.txt")"
fill11 cap26 '{"O26": "가"}' 74k; rc=$?; want_err 74k "ERROR 채우지 못한 키: O26(구조가 복잡해 미리 판정 못 함)" trial-cap-fill-blocked

# 75. 채운 뒤 손상 묶음은 같은 이름이라도 누름틀마다 한 항목(문서 순서, 같은 이름·사유 중복만 한 번)
nfill11 samedmg '{"B": "나"}' 75a; rc=$?
want_err 75a "ERROR 요청한 키(B)를 채우면 다른 누름틀이 바뀜: A(다른 누름틀과 구간이 겹쳐 채울 수 없음), A(다른 누름틀 안에 있어 함께 채울 수 없음)" damage-per-element
"$H" fields "$T/samedmg.hwpx" > "$T/75b.txt" 2>&1
fill11 samedmg '{"B": "나"}' 75c; rc=$?
grep -qxF -- '- B (누름틀 필드) (fill 불가: 다른 누름틀 A 와 구간이 겹침)' "$T/75b.txt" && pass damage-per-element-fields || bad damage-per-element-fields "$(sed 1d "$T/75b.txt" | tr '\n' '/')"
want_err 75c "ERROR 채우지 못한 키: B(다른 누름틀 A 와 구간이 겹침)" damage-per-element-prejudged

# 76. 값에 XML 에 쓸 수 없는 제어 문자·서로게이트·U+FFFE/FFFF 가 있으면 한국어 ERROR(JSON 순서 첫 키), 출력 없음. 탭·줄바꿈·DEL 은 허용
for n in 1 2 3; do
  case $n in 1) j='{"A": "가\u0001나"}' ;; 2) j='{"A": "\ud800"}' ;; 3) j='{"A": "x￿"}' ;; esac
  fill11 plain11 "$j" "76$n"; rc=$?; want_err "76$n" "ERROR 값에 쓸 수 없는 제어 문자가 있음: A" "fill-control-char-$n"
done
fill11 plain11 '{"A": "ok", "B": "\u0002", "C": "\u0003"}' 764; rc=$?; want_err 764 "ERROR 값에 쓸 수 없는 제어 문자가 있음: B" fill-control-char-first-key
fill11 plain11 '{"A\u0001": "\u0001"}' 765; rc=$?; want_err 765 'ERROR 값에 쓸 수 없는 제어 문자가 있음: A\x01' fill-control-char-key-shown
fill11 plain11 '{"A\ud800": "\u0001"}' 766; rc=$?; want_err 766 'ERROR 값에 쓸 수 없는 제어 문자가 있음: A\ud800' fill-control-char-surrogate-key
fill11 plain11 '{"A\udfff": "x"}' 767; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/767.txt" && ! grep -qi 'traceback\|codec\|surrogate' "$T/767.txt" && [ ! -e "$T/o767.hwpx" ] \
  && pass fill-surrogate-key-error-prints || bad fill-surrogate-key-error-prints "rc=$rc $(first "$T/767.txt")"
fill11 tbl11 '{"이름": "x\u000by"}' 768; rc=$?; want_err 768 "ERROR 값에 쓸 수 없는 제어 문자가 있음: 이름" fill-control-char-table
fill11 plain11 '{"A": "a\tb\nc\u007f"}' 769; rc=$?
[ $rc -eq 0 ] && grep -q '^OK ' "$T/769.txt" && pass fill-tab-newline-allowed || bad fill-tab-newline-allowed "rc=$rc $(first "$T/769.txt")"

# 77. lib/hwpx_fields.py 가 없거나 깨졌거나 버전이 안 맞으면 Traceback 없이 한국어 ERROR
for n in 1 2 3 4; do
  rm -rf "$T/kc$n"; mkdir -p "$T/kc$n"; cp -R "$KIT/skills/hwpx" "$T/kc$n/hwpx"; L="$T/kc$n/hwpx/lib/hwpx_fields.py"
  case $n in
    1) rm -rf "$T/kc$n/hwpx/lib"; want="ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_fields.py 없음)" ;;
    2) printf '\ndef broken(:\n' >> "$L"; want="ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_fields.py 손상 또는 버전 불일치)" ;;
    3) sed -i.bak 's/^def field_damage(/def field_damage_old(/' "$L"; want="ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_fields.py 손상 또는 버전 불일치)" ;;
    4) printf "\nraise RuntimeError('x')\n" >> "$L"; want="ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_fields.py 손상 또는 버전 불일치)" ;;
  esac
  "$T/kc$n/hwpx/scripts/hwpx" fields "$T/plain11.hwpx" > "$T/77$n.txt" 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(first "$T/77$n.txt")" = "$want" ] && ! grep -q Traceback "$T/77$n.txt" \
    && pass "lib-broken-$n" || bad "lib-broken-$n" "rc=$rc $(first "$T/77$n.txt")"
done

# 78. 실패한 요청 키의 누름틀이 다른 키 채우기로 바뀌면 손상으로 보고한다(사전 판정을 꺼도)
nfill11 f5vcross '{"A": "새", "B": "나"}' 78a; rc=$?
want_err 78a "ERROR 채우지 못한 키: A(이미 값이 있음); 요청한 키(B)를 채우면 다른 누름틀이 바뀜: A(다른 누름틀과 구간이 겹쳐 채울 수 없음)" damage-failed-requested-field
fill11 f5vcross '{"A": "새", "B": "나"}' 78b; rc=$?
want_err 78b "ERROR 채우지 못한 키: A(이미 값이 있음), B(다른 누름틀 A 와 구간이 겹침)" damage-failed-requested-prejudged

# 79. wrapper 를 심볼릭 링크로 불러도(절대·상대·연쇄·공백 경로) 실제 위치의 hwpx_tool.py 를 찾는다
rm -rf "$T/lnk" "$T/ln2" "$T/sp ace"; mkdir -p "$T/lnk" "$T/ln2" "$T/sp ace"
ln -s "$KIT/skills/hwpx/scripts/hwpx" "$T/lnk/hwpx"; (cd "$T/lnk" && ln -s hwpx h2)
(cd "$T/ln2" && ln -s ../lnk/h2 h3); ln -s "$T/lnk/hwpx" "$T/sp ace/h 4"
for w in "$T/lnk/hwpx" "$T/lnk/h2" "$T/ln2/h3" "$T/sp ace/h 4"; do
  "$w" fields "$T/plain11.hwpx" > "$T/79.txt" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(first "$T/79.txt")" = "OK $T/plain11.hwpx" ] && pass "wrapper-symlink-$(basename "$w" | tr ' ' _)" \
    || bad "wrapper-symlink-$(basename "$w" | tr ' ' _)" "rc=$rc $(first "$T/79.txt")"
done


# 80~83 공통 픽스처 (v12 리뷰 재현)
"$PY" -I -W ignore - "$T" <<'EOF'
import sys, copy
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def save(d, name): d.save_to_path(f"{T}/{name}.hwpx")
def ctrl_run(p, tag): return next(r for r in p if r.find(f"{HP}ctrl/{HP}{tag}") is not None)
def ctrl_of(p, tag): return next(c for c in p.iter(HP + "ctrl") if c.find(HP + tag) is not None)
def tnode(text): e = etree.Element(HP + "t"); e.text = text; return e
def hl_para(d, text="링크"):
    p = d.add_paragraph(""); p.add_hyperlink("https://example.com/", text); return p.element
def a_open(d):
    """누름틀 A 를 넣고 끝 run 을 떼어 돌려준다(뒤 문단에 붙여 여러 문단 구간을 만든다)."""
    d.fields.add("A"); pa = d.paragraphs[-1].element; ea = ctrl_run(pa, "fieldEnd"); pa.remove(ea); return ea
def link_open(d, text="링크"):
    ph = hl_para(d, text or "링크"); he = ctrl_run(ph, "fieldEnd"); ph.remove(he)
    if text is None:
        for t in ph.iter(HP + "t"): t.text = None
    return he
def tail(d, run): d.add_paragraph("").element.append(run)
# hl12x2: p1=[링크 시작][링크] p2=[A 시작] p3=[링크 끝] p4=[A 끝] — A 가 링크 끝만 품음
d = HwpxDocument.new(); he = link_open(d); ea = a_open(d); tail(d, he); tail(d, ea); save(d, "hl12x2")
# hl12x1e: p1=[A 시작] p2=[링크 시작][빈 글자] p3=[A 끝] p4=[링크 끝] — A 가 링크 시작만 품음(A 값은 빈 문자열)
d = HwpxDocument.new(); ea = a_open(d); he = link_open(d, None); tail(d, ea); tail(d, he); save(d, "hl12x1e")
# hl12nest: p1=[A 시작] p2=[링크 시작][빈 글자][링크 끝] p3=[A 끝] — A 가 빈 링크를 통째로 품음
d = HwpxDocument.new(); ea = a_open(d); ph = hl_para(d, "링크")
for t in ph.iter(HP + "t"): t.text = None
tail(d, ea); save(d, "hl12nest")
# hl12out (대조군): 평범한 A 다음 문단에 링크 — A 를 채워도 링크는 그대로
d = HwpxDocument.new(); d.fields.add("A"); hl_para(d, "링크"); save(d, "hl12out")
# C1: 한 문단 run 배치 [(charPr, [표시...])]
def build(name, layout):
    d = HwpxDocument.new(); d.fields.add("A"); d.fields.add("B")
    pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
    m = {"bA": ctrl_of(pa, "fieldBegin"), "eA": ctrl_of(pa, "fieldEnd"),
         "bB": ctrl_of(pb, "fieldBegin"), "eB": ctrl_of(pb, "fieldEnd")}
    like = list(pa)[0]
    for r in list(pa): pa.remove(r)
    for cp, kids in layout:
        r = copy.deepcopy(like); [r.remove(c) for c in list(r)]; r.set("charPrIDRef", str(cp))
        for k in kids: r.append(tnode(k[1]) if isinstance(k, tuple) else m[k])
        pa.append(r)
    pb.getparent().remove(pb); save(d, name)
# c12style: run0[A 시작] run1[빈 t][A 끝][B 시작][t 기존][B 끝] — A 를 채우면 B 값 '기존' 서식이 1→0
build("c12style", [(0, ["bA"]), (1, [("t", None), "eA", "bB", ("t", "기존"), "eB"])])
# c12out: run0[A 시작] run1[빈 t][A 끝][t 밖글자] — A 를 채우면 구간 밖 '밖글자' 서식이 1→0
build("c12out", [(0, ["bA"]), (1, [("t", None), "eA", ("t", "밖글자")])])
# c12in (대조군): run0[A 시작] run1[빈 t][A 끝] run2(1)[t 밖] — 바뀌는 서식은 구간 안뿐
build("c12in", [(0, ["bA"]), (1, [("t", None), "eA"]), (1, [("t", "밖")])])
EOF
# 링크 짝 수: 'links=시작 수 paired=끝 짝 있는 시작 수'
hlpairs() { "$PY" -I -W ignore - "$1" <<'EOF'
import sys
from hwpx import HwpxDocument
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
try:
    root = [s.element for s in HwpxDocument.open(sys.argv[1]).sections]
    begins = [b.get("id") for r in root for b in r.iter(HP + "fieldBegin") if b.get("type") == "HYPERLINK"]
    ends = {e.get("beginIDRef") for r in root for e in r.iter(HP + "fieldEnd")}
    print(f"links={len(begins)} paired={sum(1 for b in begins if b in ends)}")
except Exception as exc:
    print("열기 실패", type(exc).__name__)
EOF
}
# 글자 '$2' 를 담은 run 의 charPrIDRef
tcharpr() { "$PY" -I -W ignore - "$1" "$2" <<'EOF'
import sys
from hwpx import HwpxDocument
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
for s in HwpxDocument.open(sys.argv[1]).sections:
    for t in s.element.iter(HP + "t"):
        if t.text == sys.argv[2]: print(t.getparent().get("charPrIDRef")); sys.exit(0)
print("없음")
EOF
}
# 느슨한 실패 확인(채운 뒤 검사 경로): $1=태그 $2=첫 줄에 있어야 할 낱말 $3=시험 이름
want_err_has() { local f; f=$(first "$T/$1.txt")
  [ $rc -ne 0 ] && case "$f" in "ERROR "*"$2"*) true ;; *) false ;; esac && [ "${f#ERROR 내부 오류}" = "$f" ] \
    && [ ! -e "$T/o$1.hwpx" ] && ! grep -q Traceback "$T/$1.txt" && pass "$3" || bad "$3" "rc=$rc $f"; }

# 80. 누름틀 아닌 필드(하이퍼링크 등)를 망가뜨리는 채우기: 끝이나 시작만 품으면 '겹침', 통째로 품었다 지우면 '품고 있음'.
#     fields 는 fill 불가로, fill 은 그 사유로 거부(출력 없음). 사전 판정을 꺼도 채운 뒤 검사가 한국어 ERROR 로 거부
X80='하이퍼링크 등 다른 필드와 구간이 겹침'; N80='하이퍼링크 등 다른 필드를 품고 있음'
for c in "hl12x2:$X80" "hl12x1e:$X80" "hl12nest:$N80"; do
  f=${c%%:*}; why=${c#*:}
  "$H" fields "$T/$f.hwpx" > "$T/80a-$f.txt" 2>&1
  grep -qxF -- "- A (누름틀 필드) (fill 불가: $why)" "$T/80a-$f.txt" && pass "other-field-$f-fields" \
    || bad "other-field-$f-fields" "$(sed 1d "$T/80a-$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "가"}' "80b$f"; rc=$?; want_err "80b$f" "ERROR 채우지 못한 키: A($why)" "other-field-$f-fill"
  nfill11 $f '{"A": "가"}' "80c$f"; rc=$?; want_err_has "80c$f" "하이퍼링크" "other-field-$f-after-fill"
done
"$H" fields "$T/hl12out.hwpx" > "$T/80d.txt" 2>&1
grep -qxF -- '- A (누름틀 필드)' "$T/80d.txt" && pass other-field-outside-fields || bad other-field-outside-fields "$(sed 1d "$T/80d.txt" | tr '\n' '/')"
fill11 hl12out '{"A": "가"}' 80e; rc=$?; want_ok 80e "A=가" other-field-outside-fill
lp=$(hlpairs "$T/o80e.hwpx"); [ "$lp" = "links=1 paired=1" ] && pass other-field-outside-link-kept || bad other-field-outside-link-kept "$lp"

# 81. 채우면 누름틀 구간 밖 글자(다른 누름틀 값 포함)의 서식(charPrIDRef)이 바뀌는 경우 fill 불가. 구간 안 서식만 바뀌면 그대로 채운다
C81='채우면 구간 밖 글자 서식이 바뀜'
for f in c12out c12style; do
  "$H" fields "$T/$f.hwpx" > "$T/81a-$f.txt" 2>&1
  grep -qxF -- "- A (누름틀 필드) (fill 불가: $C81)" "$T/81a-$f.txt" && pass "style-$f-fields" || bad "style-$f-fields" "$(sed 1d "$T/81a-$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "가"}' "81b$f"; rc=$?; want_err "81b$f" "ERROR 채우지 못한 키: A($C81)" "style-$f-fill"
  nfill11 $f '{"A": "가"}' "81c$f"; rc=$?; want_err_has "81c$f" "서식" "style-$f-after-fill"
done
grep -qxF -- '- B (누름틀 필드) (fill 불가: 이미 값이 있음)' "$T/81a-c12style.txt" && pass style-c12style-b-unchanged \
  || bad style-c12style-b-unchanged "$(sed 1d "$T/81a-c12style.txt" | tr '\n' '/')"
"$H" fields "$T/c12in.hwpx" > "$T/81d.txt" 2>&1
grep -qxF -- '- A (누름틀 필드)' "$T/81d.txt" && pass style-inside-fields || bad style-inside-fields "$(sed 1d "$T/81d.txt" | tr '\n' '/')"
fill11 c12in '{"A": "가"}' 81e; rc=$?; want_ok 81e "A=가" style-inside-fill
cp81=$(tcharpr "$T/o81e.hwpx" "밖" 2>&1); [ "$cp81" = 1 ] && pass style-inside-outer-kept || bad style-inside-outer-kept "charPr=$cp81"

# 82. JSON 값은 문자열 또는 정수만(정수는 십진 표기 그대로). bool·실수·null·목록·객체는 JSON 순서 첫 키로 거부(형식 검사가 다른 값 검사보다 먼저)
fill11 plain11 '{"A": 12}' 82a; rc=$?; want_ok 82a "A=12" value-int-ok
fill11 plain11 '{"A": -7}' 82b; rc=$?; want_ok 82b "A=-7" value-negative-int-ok
fill11 tbl11 '{"이름": 300}' 82c; rc=$?
"$H" read "$T/o82c.hwpx" > "$T/82c2.txt" 2>&1
[ $rc -eq 0 ] && grep -q '^OK ' "$T/82c.txt" && grep -q '| 이름 | 300 |' "$T/82c2.txt" && pass value-int-table-ok \
  || bad value-int-table-ok "rc=$rc $(first "$T/82c.txt") / $(sed -n 2,4p "$T/82c2.txt" | tr '\n' '/')"
n=0
for v in '["홍길동"]' true false 1.5 1e400 '{"성": "홍"}' null; do
  n=$((n + 1)); fill11 plain11 "{\"A\": $v}" "82d$n"; rc=$?
  want_err "82d$n" "ERROR 값은 문자열(또는 정수)이어야 합니다: A" "value-type-reject-$n"
done
fill11 tbl11 '{"이름": [1]}' 82e; rc=$?; want_err 82e "ERROR 값은 문자열(또는 정수)이어야 합니다: 이름" value-type-reject-table
fill11 plain11 '{"A": "가", "없는키": [1]}' 82f; rc=$?; want_err 82f "ERROR 값은 문자열(또는 정수)이어야 합니다: 없는키" value-type-first-bad-key
fill11 plain11 '{"A": "\u0001", "B": 1.5}' 82g; rc=$?; want_err 82g "ERROR 값은 문자열(또는 정수)이어야 합니다: B" value-type-before-control-char
fill11 plain11 "{\"A\": $(printf '9%.0s' $(seq 5000))}" 82h; rc=$?
case "$(first "$T/82h.txt")" in "ERROR JSON 파싱 실패: "*) ok82=1 ;; *) ok82=0 ;; esac
[ $rc -ne 0 ] && [ $ok82 = 1 ] && [ ! -e "$T/o82h.hwpx" ] && ! grep -q Traceback "$T/82h.txt" && pass value-huge-int-json \
  || bad value-huge-int-json "rc=$rc $(first "$T/82h.txt" | cut -c1-80)"
grep -q '문자열(정수 가능)' "$KIT/skills/hwpx/SKILL.md" && pass skill-md-value-type || bad skill-md-value-type "SKILL.md 에 '문자열(정수 가능)' 없음"

# 83. wrapper 가 제 폴더로 못 가거나(폴더 이름 끝이 줄바꿈) 옆에 hwpx_tool.py 가 없으면 stdout 에 ERROR 한 줄, rc=2
rm -rf "${T:?}/cpw" "${T:?}/lfdir"*; mkdir -p "$T/cpw"; cp "$KIT/skills/hwpx/scripts/hwpx" "$T/cpw/hwpx"
"$T/cpw/hwpx" fields "$T/plain11.hwpx" > "$T/83a.txt" 2> "$T/83a.err"; rc=$?
[ $rc -eq 2 ] && [ "$(wc -l < "$T/83a.txt" | tr -d ' ')" = 1 ] && [ "$(cat "$T/83a.txt")" = "ERROR hwpx skill 설치가 불완전합니다(scripts/hwpx_tool.py 없음)" ] \
  && pass wrapper-tool-missing || bad wrapper-tool-missing "rc=$rc $(tr '\n' '/' < "$T/83a.txt")"
LFD="$T/lfdir"$'\n'; mkdir -p "$LFD"; cp "$KIT/skills/hwpx/scripts/hwpx" "$KIT/skills/hwpx/scripts/hwpx_tool.py" "$LFD/"
"$LFD/hwpx" fields "$T/plain11.hwpx" > "$T/83b.txt" 2> "$T/83b.err"; rc=$?
[ $rc -eq 2 ] && [ "$(wc -l < "$T/83b.txt" | tr -d ' ')" = 1 ] && [ "$(cat "$T/83b.txt")" = "ERROR hwpx skill 폴더로 이동하지 못했습니다" ] \
  && pass wrapper-cd-fail || bad wrapper-cd-fail "rc=$rc $(tr '\n' '/' < "$T/83b.txt")"
rm -rf "${T:?}/cpw" "${T:?}/lfdir"*


# 84~89 공통 픽스처 (v13 리뷰 재현)
"$PY" -I -W ignore - "$T" <<'EOF'
import sys, copy
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def ctrl_of(p, tag): return next(c for c in p.iter(HP + "ctrl") if c.find(HP + tag) is not None)
def tnode(text=None, child=None):
    e = etree.Element(HP + "t"); e.text = text
    if child: etree.SubElement(e, HP + child)
    return e
def marks():
    """새 문서와 누름틀 A·B, 하이퍼링크 H 의 ctrl(문단에서 떼어 냄). A 문단을 비워 돌려준다."""
    d = HwpxDocument.new(); d.fields.add("A"); d.fields.add("B")
    ph = d.add_paragraph(""); ph.add_hyperlink("https://example.com/", "링크")
    pa, pb, phe = d.paragraphs[1].element, d.paragraphs[2].element, d.paragraphs[3].element
    m = {"bA": ctrl_of(pa, "fieldBegin"), "eA": ctrl_of(pa, "fieldEnd"), "bB": ctrl_of(pb, "fieldBegin"),
         "eB": ctrl_of(pb, "fieldEnd"), "bH": ctrl_of(phe, "fieldBegin"), "eH": ctrl_of(phe, "fieldEnd")}
    for c in m.values(): c.getparent().remove(c)
    like = list(pa)[0]
    for p in (pb, phe): p.getparent().remove(p)
    for r in list(pa): pa.remove(r)
    return d, pa, m, like
def kid(k, m):
    if isinstance(k, etree._Element): return k
    if isinstance(k, tuple): return tnode(*k[1:])
    return m[k]
def fill_para(p, layout, m, like):
    for cp, kids in layout:
        r = copy.deepcopy(like); [r.remove(c) for c in list(r)]; r.set("charPrIDRef", str(cp))
        for k in kids: r.append(kid(k, m))
        p.append(r)
def build(name, layout, extra=None, promptA=None):
    d, pa, m, like = marks()
    if promptA is not None: m["bA"].find(HP + "fieldBegin").set("prompt", promptA)
    fill_para(pa, layout, m, like)
    if extra: extra(pa, m, like)
    d.save_to_path(f"{T}/{name}.hwpx")
# F1 한 문단 안 링크·누름틀 엇갈림
# hlx1: [A 시작] [t 앞][H 시작] (7)[t 링크1] [A 끝] (7)[t 링크2] [H 끝] — 링크 글자 '링크1' 이 A 안
build("hlx1", [(0, ["bA"]), (0, [("t", "앞"), "bH"]), (7, [("t", "링크1")]), (0, ["eA"]),
               (7, [("t", "링크2")]), (0, ["eH"])], promptA="앞링크1")
# hlx2: [H 시작] (7)[t 링크1] [A 시작] (7)[t 링크2] [H 끝] (0)[t ""] [A 끝] — 링크 끝이 A 안
build("hlx2", [(0, ["bH"]), (7, [("t", "링크1")]), (0, ["bA"]), (7, [("t", "링크2")]), (0, ["eH"]),
               (0, [("t", "")]), (0, ["eA"])], promptA="링크2")
# hlx3: [H 시작](7)[t 링크] [A 시작] [H 끝] [A 끝] — 빈 A 의 값이 링크 구간 안에 들어감
build("hlx3", [(0, ["bH"]), (7, [("t", "링크")]), (0, ["bA"]), (0, ["eH"]), (0, ["eA"])])
# hlwrap (대조군): [H 시작][A 시작][빈 t][A 끝][H 끝] — 링크가 A 를 통째로 품음. A 를 채우면 링크 글자가 값이 된다
build("hlwrap", [(0, ["bH", "bA", ("t",), "eA", "eH"])])
# F4 같은 id 비누름틀
# duph: 문단1 [H1 시작](7)[t 링크][H1 끝] ; 문단2 [A 시작](7)[H2 시작][빈 t][H2 끝][A 끝] — H2 는 H1 과 같은 id
def dup(pa, m, like, new_id=None):
    p2 = copy.deepcopy(pa); [p2.remove(r) for r in list(p2)]
    bh, eh = copy.deepcopy(m["bH"]), copy.deepcopy(m["eH"])
    if new_id:
        bh.find(HP + "fieldBegin").set("id", new_id); eh.find(HP + "fieldEnd").set("beginIDRef", new_id)
    fill_para(p2, [(0, ["bA"]), (7, [bh, ("t",), eh]), (0, ["eA"])], m, like)
    pa.addnext(p2)
build("duph", [(0, ["bH"]), (7, [("t", "링크")]), (0, ["eH"])], extra=dup)
# nesth (대조군): duph 와 같되 H2 가 고유 id
build("nesth", [(0, ["bH"]), (7, [("t", "링크")]), (0, ["eH"])], extra=lambda pa, m, like: dup(pa, m, like, "999111"))
# x3dup: 문단1 [A 시작] 문단2 [빈 링크 L] 문단3 [A 끝] 문단4 [링크 L' '바깥'] — L' 은 L 과 같은 id
d = HwpxDocument.new(); d.fields.add("A"); pa = d.paragraphs[-1].element
ea = next(r for r in pa if r.find(f"{HP}ctrl/{HP}fieldEnd") is not None); pa.remove(ea)
pi = d.add_paragraph(""); pi.add_hyperlink("https://example.com/", "링크"); inner = pi.element
for t in inner.iter(HP + "t"): t.text = None
d.add_paragraph("").element.append(ea)
po = d.add_paragraph(""); po.add_hyperlink("https://example.com/", "바깥"); outer = po.element
k = next(inner.iter(HP + "fieldBegin")).get("id")
next(outer.iter(HP + "fieldBegin")).set("id", k); next(outer.iter(HP + "fieldEnd")).set("beginIDRef", k)
d.save_to_path(f"{T}/x3dup.hwpx")
# F2 글자 요소만 든 구간 밖 hp:t
build("x2nb", [(0, ["bA"]), (1, [("t",), "eA", ("t", None, "nbSpace")])])
build("x2tab", [(0, ["bA"]), (1, [("t",), "eA", ("t", None, "tab")])])
build("x2fw", [(0, ["bA"]), (1, [("t",), "eA", ("t", None, "fwSpace")])])
build("x2lb", [(0, ["bA"]), (1, [("t",), "eA", ("t", None, "lineBreak")])])
# tabsep (대조군): 탭은 다른 run(같은 charPr 1) — 바뀌는 서식은 구간 안뿐
build("tabsep", [(0, ["bA"]), (1, [("t",), "eA"]), (1, [("t", None, "tab")])])
# F3 같은 run 의 다른 누름틀 시작
# x1: run0[A 시작] run1[빈 t][A 끝][B 시작][빈 t][B 끝]
build("x1", [(0, ["bA"]), (1, [("t",), "eA", "bB", ("t",), "eB"])])
# adjempty: run0[A 시작] run1(7)[빈 t][A 끝][B 시작] run2(7)[B 끝]
build("adjempty", [(0, ["bA"]), (7, [("t",), "eA", "bB"]), (7, ["eB"])])
# x1same (대조군): x1 과 같되 run0 도 charPr 1 — 서식이 바뀌지 않음
build("x1same", [(1, ["bA"]), (1, [("t",), "eA", "bB", ("t",), "eB"])])
# x1sep (대조군): B 는 따로 run2(1)
build("x1sep", [(0, ["bA"]), (1, [("t",), "eA"]), (1, ["bB", ("t",), "eB"])])
# hlwrap0 (대조군): [H 시작][A 시작][A 끝][H 끝] — t 없음. 라이브러리가 A 시작 뒤에 새 hp:t 를 넣어 값이 링크 안에 들어감(정상)
build("hlwrap0", [(0, ["bH", "bA", "eA", "eH"])])
# tbllink (대조군): 문단1 [링크 시작][t 앞] / 표 '이름' | 빈 칸 / 문단3 [링크 끝] — 링크 구간 안 표 칸을 라벨로 채움
d = HwpxDocument.new(); pl = d.add_paragraph(""); pl.add_hyperlink("https://example.com/", "앞")
tb = d.add_table(1, 2); tb.set_cell_text(0, 0, "이름")
eh = next(pl.element.iter(HP + "fieldEnd")).getparent()
eh.getparent().remove(eh); next(d.add_paragraph("").element.iter(HP + "run")).append(eh)
d.save_to_path(f"{T}/tbllink.hwpx")
EOF

# 84. 한 문단 안에서 누름틀과 하이퍼링크 등 다른 필드가 엇갈리거나(링크 글자가 지워지거나 값이 링크 안에 들어감) 같은 id 의 다른 링크가
#     있어도 요소 기준으로 손상을 본다: 시작·끝 중 하나만 사라지거나 사이 글자가 바뀌면 '겹침', 둘 다 사라지면 '품고 있음'.
#     링크가 누름틀을 통째로 품으면(hlwrap) 그대로 채운다
for c in "hlx1:$X80" "hlx2:$X80" "hlx3:$X80" "duph:$N80" "x3dup:$N80" "nesth:$N80"; do
  f=${c%%:*}; why=${c#*:}
  "$H" fields "$T/$f.hwpx" > "$T/84a-$f.txt" 2>&1
  grep -qxF -- "- A (누름틀 필드) (fill 불가: $why)" "$T/84a-$f.txt" && pass "nonform-elem-$f-fields" \
    || bad "nonform-elem-$f-fields" "$(sed 1d "$T/84a-$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "가"}' "84b$f"; rc=$?; want_err "84b$f" "ERROR 채우지 못한 키: A($why)" "nonform-elem-$f-fill"
  nfill11 $f '{"A": "가"}' "84c$f"; rc=$?; want_err_has "84c$f" "하이퍼링크" "nonform-elem-$f-after-fill"
done
"$H" fields "$T/hlwrap.hwpx" > "$T/84d.txt" 2>&1
grep -qxF -- '- A (누름틀 필드)' "$T/84d.txt" && pass nonform-wrap-fields || bad nonform-wrap-fields "$(sed 1d "$T/84d.txt" | tr '\n' '/')"
fill11 hlwrap '{"A": "가"}' 84e; rc=$?; want_ok 84e "A=가" nonform-wrap-fill
lp=$(hlpairs "$T/o84e.hwpx"); [ "$lp" = "links=1 paired=1" ] && pass nonform-wrap-link-kept || bad nonform-wrap-link-kept "$lp"

# 85. 구간 밖 hp:t 가 글자 없이 탭·nbSpace·fwSpace·lineBreak 같은 자식 요소만 품어도 '내용 있음'(정적·채운 뒤 규칙 모두)
for f in x2nb x2tab x2fw x2lb; do
  "$H" fields "$T/$f.hwpx" > "$T/85a-$f.txt" 2>&1
  grep -qxF -- "- A (누름틀 필드) (fill 불가: $C81)" "$T/85a-$f.txt" && pass "style-child-$f-fields" || bad "style-child-$f-fields" "$(sed 1d "$T/85a-$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "가"}' "85b$f"; rc=$?; want_err "85b$f" "ERROR 채우지 못한 키: A($C81)" "style-child-$f-fill"
  nfill11 $f '{"A": "가"}' "85c$f"; rc=$?; want_err "85c$f" "ERROR 요청한 키(A)를 $C81" "style-child-$f-after-fill"
done
fill11 tabsep '{"A": "가"}' 85d; rc=$?; want_ok 85d "A=가" style-child-sep-fill

# 86. 채울 누름틀의 primary run 에 다른 누름틀의 시작이 있으면(서식이 다를 때) 그 누름틀 시작 run 서식이 바뀌므로 fill 불가.
#     정적 규칙과 채운 뒤 규칙(모든 누름틀 시작 run 의 charPrIDRef 비교) 모두. 서식이 같거나 다른 run 이면 그대로 채운다
for f in x1 adjempty; do
  "$H" fields "$T/$f.hwpx" > "$T/86a-$f.txt" 2>&1
  grep -qxF -- "- A (누름틀 필드) (fill 불가: $C81)" "$T/86a-$f.txt" && grep -qxF -- "- B (누름틀 필드)" "$T/86a-$f.txt" \
    && pass "style-begin-$f-fields" || bad "style-begin-$f-fields" "$(sed 1d "$T/86a-$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "가"}' "86b$f"; rc=$?; want_err "86b$f" "ERROR 채우지 못한 키: A($C81)" "style-begin-$f-fill"
  nfill11 $f '{"A": "가"}' "86c$f"; rc=$?; want_err "86c$f" "ERROR 요청한 키(A)를 $C81" "style-begin-$f-after-fill"
  fill11 $f '{"B": "나"}' "86d$f"; rc=$?; want_ok "86d$f" "A=/B=나" "style-begin-$f-b-fill"
done
fill11 x1 '{"A": "가", "B": "나"}' 86e; rc=$?; want_err 86e "ERROR 채우지 못한 키: A($C81)" style-begin-x1-both
cp86=$(tcharpr "$T/o86dx1.hwpx" "나" 2>&1); [ "$cp86" = 1 ] && pass style-begin-b-charpr || bad style-begin-b-charpr "charPr=$cp86"
fill11 x1same '{"A": "가", "B": "나"}' 86f; rc=$?; want_ok 86f "A=가/B=나" style-begin-same-charpr
fill11 x1sep '{"A": "가", "B": "나"}' 86g; rc=$?; want_ok 86g "A=가/B=나" style-begin-sep-run
cp86=$(tcharpr "$T/o86g.hwpx" "나" 2>&1); [ "$cp86" = 1 ] && pass style-begin-sep-b-charpr || bad style-begin-sep-b-charpr "charPr=$cp86"

# 87. wrapper: hwpx_tool.py 가 있지만 읽을 수 없거나(권한 000·폴더) CLAUDE_LMS_PY 가 폴더면 stdout 에 ERROR 한 줄, rc=2
R87='ERROR hwpx skill 설치가 불완전합니다(scripts/hwpx_tool.py 를 읽을 수 없음)'
rm -rf "${T:?}/cpr" "${T:?}/cpd" "${T:?}/pydir"; mkdir -p "$T/cpr" "$T/cpd/hwpx_tool.py" "$T/pydir"
cp "$KIT/skills/hwpx/scripts/hwpx" "$KIT/skills/hwpx/scripts/hwpx_tool.py" "$T/cpr/"; cp "$KIT/skills/hwpx/scripts/hwpx" "$T/cpd/"
chmod 000 "$T/cpr/hwpx_tool.py"
for w in cpr cpd; do
  "$T/$w/hwpx" fields "$T/plain11.hwpx" > "$T/87$w.txt" 2> "$T/87$w.err"; rc=$?
  [ $rc -eq 2 ] && [ "$(wc -l < "$T/87$w.txt" | tr -d ' ')" = 1 ] && [ "$(cat "$T/87$w.txt")" = "$R87" ] \
    && pass "wrapper-tool-unreadable-$w" || bad "wrapper-tool-unreadable-$w" "rc=$rc $(tr '\n' '/' < "$T/87$w.txt")"
done
CLAUDE_LMS_PY="$T/pydir" "$H" fields "$T/plain11.hwpx" > "$T/87py.txt" 2> "$T/87py.err"; rc=$?
[ $rc -eq 2 ] && [ "$(wc -l < "$T/87py.txt" | tr -d ' ')" = 1 ] && [ "$(cat "$T/87py.txt")" = "ERROR 파이썬 없음: $T/pydir (guardian 번들 설치 필요)" ] \
  && pass wrapper-python-dir || bad wrapper-python-dir "rc=$rc $(tr '\n' '/' < "$T/87py.txt")"
chmod 600 "$T/cpr/hwpx_tool.py"; rm -rf "${T:?}/cpr" "${T:?}/cpd" "${T:?}/pydir"

# 88. 너무 깊게 중첩된 JSON 은 내부 오류가 아니라 'JSON 파싱 실패: <경로> (너무 깊음)'
for n in a o; do
  "$PY" -I - "$T/v88$n.json" "$n" <<'PYEOF'
import sys
p, n = sys.argv[1:3]
body = "[" * 100000 + "]" * 100000 if n == "a" else '{"a": ' * 100000 + "1" + "}" * 100000
open(p, "w").write('{"A": ' + body + "}")
PYEOF
  rm -f "${T:?}/o88$n.hwpx"; "$H" fill "$T/plain11.hwpx" "$T/v88$n.json" "$T/o88$n.hwpx" > "$T/88$n.txt" 2>&1; rc=$?
  want_err "88$n" "ERROR JSON 파싱 실패: $T/v88$n.json (너무 깊음)" "json-too-deep-$n"
done

# 89. 채운 뒤 손상은 요청 키가 둘 이상이면 '요청한 키(A, B) 중 하나 이상을 채우면 …' (어느 키 탓인지 특정하지 않음). 하나면 그대로
nfill11 x1 '{"A": "가", "B": "나"}' 89a; rc=$?; want_err 89a "ERROR 요청한 키(A, B) 중 하나 이상을 $C81" damage-msg-multi-keys

# 90. v13 대조군 — 링크 안 t 없는 누름틀(값이 링크 안에 들어가는 것은 정상), 링크 구간 안 표 칸 라벨 채우기
"$H" fields "$T/hlwrap0.hwpx" > "$T/90f.txt" 2>&1
grep -qxF -- '- A (누름틀 필드)' "$T/90f.txt" && pass hlwrap0-fields || bad hlwrap0-fields "$(sed 1d "$T/90f.txt" | tr '\n' '/')"
fill11 hlwrap0 '{"A": "가"}' 90a; rc=$?; want_ok 90a "A=가" hlwrap0-fill
[ "$(hlpairs "$T/o90a.hwpx" 2>&1)" = "links=1 paired=1" ] && pass hlwrap0-link || bad hlwrap0-link "$(hlpairs "$T/o90a.hwpx" 2>&1)"
nfill11 hlwrap0 '{"A": "가"}' 90b; rc=$?; want_ok 90b "A=가" hlwrap0-nonest
fill11 tbllink '{"이름": "홍"}' 90c; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/90c.txt")" = "OK $T/o90c.hwpx" ] && "$H" read "$T/o90c.hwpx" 2>&1 | grep -qF '| 이름 | 홍 |' && pass tbllink-fill || bad tbllink-fill "rc=$rc $(first "$T/90c.txt")"
[ "$(hlpairs "$T/o90c.hwpx" 2>&1)" = "links=1 paired=1" ] && pass tbllink-link || bad tbllink-link "$(hlpairs "$T/o90c.hwpx" 2>&1)"

# 91~94 픽스처(fix14): run 직속 글자 ctrl·덧말, 글자 없는 표시, 끝 없는 누름틀, 한/글이 열지 않는 입력(zip 직접 수정)
"$PY" -I -W ignore - "$T" <<'EOF'
import sys, copy, zipfile
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def ctrl_of(p, tag): return next(c for c in p.iter(HP + "ctrl") if c.find(HP + tag) is not None)
def el(tag, attrs=None, text=None, tail=None, kids=()):
    e = etree.Element(HP + tag, attrs or {}); e.text = text; e.tail = tail
    for k in kids: e.append(k)
    return e
def marks():
    d = HwpxDocument.new(); d.fields.add("A"); d.fields.add("B")
    pa, pb = d.paragraphs[1].element, d.paragraphs[2].element
    m = {"bA": ctrl_of(pa, "fieldBegin"), "eA": ctrl_of(pa, "fieldEnd"), "bB": ctrl_of(pb, "fieldBegin"), "eB": ctrl_of(pb, "fieldEnd")}
    for c in m.values(): c.getparent().remove(c)
    like = list(pa)[0]; pb.getparent().remove(pb)
    for r in list(pa): pa.remove(r)
    return d, pa, m, like
def build(name, layout):
    d, pa, m, like = marks()
    for cp, kids in layout:
        r = copy.deepcopy(like); [r.remove(c) for c in list(r)]; r.set("charPrIDRef", str(cp))
        for k in kids: r.append(m[k] if isinstance(k, str) else k)
        pa.append(r)
    d.save_to_path(f"{T}/{name}.hwpx")
def T0(): return el("t")
def dutmal(): return el("dutmal", {"posType": "TOP", "szRatio": "0", "option": "0", "styleIDRef": "0", "align": "CENTER"},
                        kids=[el("mainText", text="본"), el("subText", text="덧")])
def autonum(): return el("ctrl", kids=[el("autoNum", {"num": "1", "numType": "PAGE"}, kids=[el("autoNumFormat",
    {"type": "DIGIT", "userChar": "", "prefixChar": "", "suffixChar": "", "supscript": "0"})])])
def mpb(tail=None): return el("markpenBegin", {"color": "#FFFF00"}, tail=tail)
# F1 반드시 거부: 구간 밖에 그려지는 것(덧말·자동 번호 ctrl·형광펜 시작 뒤 글자)
build("dut14", [(0, ["bA"]), (7, [T0(), "eA", dutmal()])])
build("auto14", [(0, ["bA"]), (7, [T0(), "eA", autonum()])])
build("mpbtail14", [(0, ["bA"]), (7, [T0(), "eA", el("t", kids=[mpb("글")])])])
# F1 그대로 채움: 글자 없는 표시만
build("mpe14", [(0, ["bA"]), (7, [T0(), "eA", el("t", kids=[el("markpenEnd")])])])
build("title14", [(0, ["bA"]), (7, [T0(), "eA", el("t", kids=[el("titleMark", {"ignore": "0"})])])])
build("mpb14", [(0, ["bA"]), (7, [T0(), "eA", el("t", kids=[mpb(), el("markpenEnd")])])])
build("auto14same", [(7, ["bA"]), (7, [T0(), "eA", autonum()])])
# F2 끝 없는 누름틀 B 가 A 의 primary run 에
build("unend14", [(0, ["bA"]), (7, [T0(), "eA", "bB"])])
# F4 한/글이 열지 않는 입력: zip 을 직접 고쳐 만든다(라이브러리 저장은 거부하므로)
def zedit(src, dst, pairs):
    with zipfile.ZipFile(f"{T}/{src}.hwpx") as zi, zipfile.ZipFile(f"{T}/{dst}.hwpx", "w") as zo:
        for info in zi.infolist():
            data = zi.read(info)
            if info.filename == "Contents/section0.xml":
                for a, b in pairs:
                    assert a in data, a; data = data.replace(a, b)
            zo.writestr(info, data)
def c1base():
    d = HwpxDocument.new(); d.fields.add("A"); pa = d.paragraphs[-1].element
    ea = next(r for r in pa if r.find(f"{HP}ctrl/{HP}fieldEnd") is not None); pa.remove(ea)
    p = d.add_paragraph(""); p.add_hyperlink("https://example.com/", "링크")
    for t in p.element.iter(HP + "t"): t.text = None
    next(p.element.iter(HP + "fieldBegin")).set("id", "NOIDMARK"); next(p.element.iter(HP + "fieldEnd")).set("beginIDRef", "NOIDMARK")
    d.add_paragraph("").element.append(ea); d.save_to_path(f"{T}/c1base14.hwpx")
c1base()
zedit("c1base14", "c1noid14", [(b' id="NOIDMARK"', b"")])
zedit("c1base14", "c1noref14", [(b' id="NOIDMARK"', b""), (b' beginIDRef="NOIDMARK"', b"")])
d = HwpxDocument.new(); d.fields.add("A"); d.add_paragraph("STRAYSPOT"); d.save_to_path(f"{T}/stray14.hwpx")
END = b'<hp:ctrl><hp:fieldEnd beginIDRef="987654" fieldid="0"/></hp:ctrl>'
zedit("stray14", "orphan14", [(b"<hp:t>STRAYSPOT</hp:t>", END)])
zedit("stray14", "orphan14ok", [(b"<hp:t>STRAYSPOT</hp:t>", b"<hp:t/>" + END)])
EOF
F4M='한/글이 열지 못하는 문서입니다(필드 표시 id 가 빠졌거나 짝이 없음)'

# 91. 구간 밖 서식 판정은 '이 run 서식으로 그려지는 것' 하나로: 덧말·자동 번호 ctrl·형광펜 뒤 글자는 내용(거부),
#     형광펜 시작·끝·제목 표시만 든 hp:t 는 내용 아님(채움). 사전(fields·fill)과 사후(nonest) 판정이 같아야 한다
for f in dut14 auto14 mpbtail14; do
  "$H" fields "$T/$f.hwpx" > "$T/91$f.txt" 2>&1
  grep -qxF -- "- A (누름틀 필드) (fill 불가: $C81)" "$T/91$f.txt" && pass "visible-$f-fields" || bad "visible-$f-fields" "$(sed 1d "$T/91$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "가"}' "91f$f"; rc=$?; want_err "91f$f" "ERROR 채우지 못한 키: A($C81)" "visible-$f-fill"
  nfill11 $f '{"A": "가"}' "91n$f"; rc=$?; want_err "91n$f" "ERROR 요청한 키(A)를 $C81" "visible-$f-post"
done
for f in mpe14 title14 mpb14 auto14same; do
  "$H" fields "$T/$f.hwpx" > "$T/91$f.txt" 2>&1
  grep -qxF -- '- A (누름틀 필드)' "$T/91$f.txt" && pass "invisible-$f-fields" || bad "invisible-$f-fields" "$(sed 1d "$T/91$f.txt" | tr '\n' '/')"
  fill11 $f '{"A": "가"}' "91f$f"; rc=$?; want_ok "91f$f" "A=가" "invisible-$f-fill"
  nfill11 $f '{"A": "가"}' "91n$f"; rc=$?; want_ok "91n$f" "A=가" "invisible-$f-post"
done

# 92. 끝 표시가 없는 누름틀 B(어차피 채울 수 없음)가 A 의 끝 run 에 있어도 A 는 막지 않는다(사전·사후 모두)
"$H" fields "$T/unend14.hwpx" > "$T/92.txt" 2>&1
grep -qxF -- '- A (누름틀 필드)' "$T/92.txt" && grep -qxF -- '- B (누름틀 필드) (fill 불가: 누름틀 끝 표시가 없음)' "$T/92.txt" \
  && pass unended-neighbor-fields || bad unended-neighbor-fields "$(sed 1d "$T/92.txt" | tr '\n' '/')"
fill11 unend14 '{"A": "가"}' 92f; rc=$?; want_ok 92f "A=가/B=" unended-neighbor-fill
nfill11 unend14 '{"A": "가"}' 92n; rc=$?; want_ok 92n "A=가/B=" unended-neighbor-post

# 93. wrapper: CLAUDE_LMS_PY 가 파이썬으로 실행되지 않으면(실행 권한 없음·셸·true·해석기 없음·이진) exec 전에
#     stdout 에 ERROR 한 줄, rc=2, stderr 비어 있음. 없는 경로는 '파이썬 없음' 그대로. 파이썬을 부르는 셸 shim 은 통과
rm -rf "${T:?}/py93"; mkdir -p "$T/py93"
printf '#!/nonexistent/interp\n' > "$T/py93/badpy"; printf '\177ELF\001\002garbage\000\000' > "$T/py93/binpy"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$PY" > "$T/py93/okpy"; cp "$T/py93/okpy" "$T/py93/noxpy"
chmod 755 "$T/py93/badpy" "$T/py93/binpy" "$T/py93/okpy"; chmod 644 "$T/py93/noxpy"
for p in /usr/bin/true /bin/sh "$T/py93/badpy" "$T/py93/binpy" "$T/py93/noxpy"; do
  CLAUDE_LMS_PY="$p" "$H" fields "$T/plain11.hwpx" > "$T/93.txt" 2> "$T/93.err"; rc=$?
  [ $rc -eq 2 ] && [ "$(wc -l < "$T/93.txt" | tr -d ' ')" = 1 ] && [ ! -s "$T/93.err" ] \
    && [ "$(cat "$T/93.txt")" = "ERROR 파이썬을 실행할 수 없음: $p (guardian 번들 설치 필요)" ] \
    && pass "wrapper-python-unusable-${p##*/}" || bad "wrapper-python-unusable-${p##*/}" "rc=$rc $(tr '\n' '/' < "$T/93.txt") err=$(head -c 80 "$T/93.err")"
done
CLAUDE_LMS_PY="$T/py93/nope" "$H" fields "$T/plain11.hwpx" > "$T/93m.txt" 2>&1; rc=$?
[ $rc -eq 2 ] && [ "$(cat "$T/93m.txt")" = "ERROR 파이썬 없음: $T/py93/nope (guardian 번들 설치 필요)" ] \
  && pass wrapper-python-missing || bad wrapper-python-missing "rc=$rc $(tr '\n' '/' < "$T/93m.txt")"
CLAUDE_LMS_PY="$T/py93/okpy" "$H" fields "$T/plain11.hwpx" > "$T/93s.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -qxF -- '- A (누름틀 필드)' "$T/93s.txt" && pass wrapper-python-shim || bad wrapper-python-shim "rc=$rc $(tr '\n' '/' < "$T/93s.txt")"
rm -rf "${T:?}/py93"

# 94. 한/글이 열지 않는 입력(id 없는 fieldBegin, beginIDRef 없는 fieldEnd, run 첫머리의 짝 없는 fieldEnd)은
#     fields·fill 이 열자마자 한 줄로 거부. read 는 그대로 읽는다. run 첫머리가 아닌 짝 없는 끝은 거부하지 않는다
for f in c1noid14 c1noref14 orphan14; do
  "$H" fields "$T/$f.hwpx" > "$T/94$f.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(cat "$T/94$f.txt")" = "ERROR $F4M: $T/$f.hwpx" ] && pass "unopenable-$f-fields" || bad "unopenable-$f-fields" "rc=$rc $(tr '\n' '/' < "$T/94$f.txt")"
  fill11 $f '{"A": "가"}' "94f$f"; rc=$?; want_err "94f$f" "ERROR $F4M: $T/$f.hwpx" "unopenable-$f-fill"
done
"$H" read "$T/c1noid14.hwpx" > "$T/94r.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -q '^ERROR' "$T/94r.txt" && pass unopenable-read-still-works || bad unopenable-read-still-works "rc=$rc $(first "$T/94r.txt")"
"$H" fields "$T/orphan14ok.hwpx" > "$T/94k.txt" 2>&1
grep -qxF -- '- A (누름틀 필드)' "$T/94k.txt" && pass orphan-midrun-fields || bad orphan-midrun-fields "$(tr '\n' '/' < "$T/94k.txt")"
fill11 orphan14ok '{"A": "가"}' 94o; rc=$?; want_ok 94o "A=가" orphan-midrun-fill
"$H" fields "$T/c1base14.hwpx" > "$T/94b.txt" 2>&1
grep -qxF -- "- A (누름틀 필드) (fill 불가: $N80)" "$T/94b.txt" && pass link-with-id-still-nested || bad link-with-id-still-nested "$(sed 1d "$T/94b.txt" | tr '\n' '/')"

# 95~99 픽스처(fix15): 글자 없는 ctrl 허용 목록, ctrl 자식 단위 경계, 빈 id, 구간 안 글자 아닌 내용
"$PY" -I -W ignore - "$T" <<'EOF'
import sys, copy, zipfile
from hwpx import HwpxDocument
from lxml import etree
T = sys.argv[1]
HP = "{http://www.hancom.co.kr/hwpml/2011/paragraph}"
def ctrl_of(p, tag): return next(c for c in p.iter(HP + "ctrl") if c.find(HP + tag) is not None)
def el(tag, attrs=None, text=None, tail=None, kids=()):
    e = etree.Element(HP + tag, attrs or {}); e.text = text; e.tail = tail
    for k in kids: e.append(k)
    return e
def T0(): return el("t")
def tx(s): return el("t", text=s)
def ctrl(*kids): return el("ctrl", kids=kids)
def table_el(cell_text):
    tb = HwpxDocument.new().add_paragraph("").add_table(1, 1)
    t = next(tb.element.iter(HP + "t"), None)
    if t is not None: t.text = cell_text
    return copy.deepcopy(tb.element)
def sublist(text):
    p = el("p", {"id": "0", "paraPrIDRef": "0", "styleIDRef": "0", "pageBreak": "0", "columnBreak": "0", "merged": "0"},
           kids=[el("run", {"charPrIDRef": "0"}, kids=[tx(text)])])
    return el("subList", {"id": "", "textDirection": "HORIZONTAL", "lineWrap": "BREAK", "vertAlign": "TOP"}, kids=[p])
def bm(): return el("bookmark", {"name": "bm"})
def hc(): return el("hiddenComment", kids=[sublist("숨은")])
def autonum(): return el("autoNum", {"num": "1", "numType": "PAGE"}, kids=[el("autoNumFormat",
    {"type": "DIGIT", "userChar": "", "prefixChar": "", "suffixChar": "", "supscript": "0"})])
def dutmal(): return el("dutmal", {"posType": "TOP", "szRatio": "0", "option": "0", "styleIDRef": "0", "align": "CENTER"},
                        kids=[el("mainText", text="덧말본"), el("subText", text="덧")])
NOTEXT = {"bookmark": bm, "hiddenComment": hc,
          "colPr": lambda: el("colPr", {"id": "", "type": "NEWSPAPER", "colCount": "1"}),
          "pageHiding": lambda: el("pageHiding", {"hideHeader": "1"}),
          "pageNumCtrl": lambda: el("pageNumCtrl", {"pageStartsOn": "BOTH"}),
          "newNum": lambda: el("newNum", {"num": "1", "numType": "PAGE"})}
SHOWN = {"pageNum": lambda: el("pageNum", {"pos": "BOTTOM_CENTER", "formatType": "DIGIT", "sideChar": "-"}),
         "footNote": lambda: el("footNote", {"number": "1", "instId": "1"}, kids=[sublist("주")]),
         "endNote": lambda: el("endNote", {"number": "1", "instId": "2"}, kids=[sublist("미주")])}
def END(ref): return ctrl(el("fieldEnd", {"beginIDRef": ref, "fieldid": "0"}))
# paras: [[(charPr, [kids]), ...], ...]. 문자열 kid 는 bA/eA ctrl, ("eA", 요소, "after"|"before") 는 eA ctrl 안에 자식을 더함
def build(name, *paras):
    d = HwpxDocument.new(); d.fields.add("A"); pa = d.paragraphs[-1].element
    m = {"bA": ctrl_of(pa, "fieldBegin"), "eA": ctrl_of(pa, "fieldEnd")}
    like = list(pa)[0]
    for r in list(pa): pa.remove(r)
    for i, layout in enumerate(paras):
        p = pa if i == 0 else d.add_paragraph("").element
        if i: [p.remove(r) for r in list(p)]
        for cp, kids in layout:
            r = copy.deepcopy(like); [r.remove(c) for c in list(r)]; r.set("charPrIDRef", str(cp))
            for k in kids:
                if isinstance(k, tuple):
                    c = m[k[0]]; c.insert(0 if k[2] == "before" else len(c), k[1]); r.append(c)
                else: r.append(m[k] if isinstance(k, str) else k)
            p.append(r)
    d.save_to_path(f"{T}/{name}.hwpx")
def zedit(src, dst, pairs):
    with zipfile.ZipFile(f"{T}/{src}.hwpx") as zi, zipfile.ZipFile(f"{T}/{dst}.hwpx", "w") as zo:
        for info in zi.infolist():
            data = zi.read(info)
            if info.filename == "Contents/section0.xml":
                for a, b in pairs:
                    assert a in data, a; data = data.replace(a, b)
            zo.writestr(info, data)
# 95 G1 끝 run 의 eA 뒤 글자 없는 ctrl(허용 목록) → 채움 / 그 뒤에 글자가 있으면 거부
for k, mk in NOTEXT.items(): build(f"nt15{k}", [(0, ["bA"]), (7, [T0(), "eA", ctrl(mk())])])
build("nt15bmtxt", [(0, ["bA"]), (7, [T0(), "eA", ctrl(bm()), tx("밖")])])
# 95b eA 뒤 보이는 ctrl(번호·주석·모르는 것) → 거부
for k, mk in SHOWN.items(): build(f"sh15{k}", [(0, ["bA"]), (7, [T0(), "eA", ctrl(mk())])])
build("unk15src", [(0, ["bA"]), (7, [T0(), "eA", ctrl(el("bookmark", {"name": "ZZMARK"}))])])
zedit("unk15src", "sh15unknown", [(b'<hp:bookmark name="ZZMARK"/>', b'<hp:zzUnknown/>')])
# 96 G1 한 ctrl 안에 fieldEnd 와 다른 자식(자식 단위 경계)
build("mix15auto", [(0, ["bA"]), (7, [T0(), ("eA", autonum(), "after")])])
build("mix15bm", [(0, ["bA"]), (7, [T0(), ("eA", bm(), "after")])])
build("mix15autoin", [(0, ["bA"]), (7, [T0(), ("eA", autonum(), "before")])])
# 97 G2 빈 문자열 id·beginIDRef 는 '없음'
build("emp15end", [(0, ["bA"]), (7, [T0(), END(""), tx("OUTSIDE")]), (3, ["eA"])])
build("emp15only", [(0, ["bA"]), (7, [T0(), END(""), tx("OUTSIDE")])])
build("emp15multi", [(0, ["bA"]), (7, [T0()])], [(5, [T0(), END(""), tx("OUTSIDE")]), (3, ["eA"])])
zedit("c1base14", "emp15id", [(b' id="NOIDMARK"', b' id=""')])
zedit("c1base14", "emp15ref", [(b' beginIDRef="NOIDMARK"', b' beginIDRef=""')])
# 98 G3 구간 안 글자 아닌 보이는 내용 → 거부 / 허용 목록 ctrl 은 구간 안에 있어도 채움
build("in15dutmal", [(0, ["bA"]), (0, [dutmal()]), (0, ["eA"])])
build("in15auto", [(0, ["bA"]), (7, [T0(), ctrl(autonum())]), (7, ["eA"])])
build("in15tbl", [(0, ["bA"]), (0, [table_el("기존")]), (0, ["eA"])])
build("in15tblout", [(0, ["bA"]), (0, [table_el("")]), (7, [T0(), "eA", tx("밖")])])
build("in15bm", [(0, ["bA", ctrl(bm())]), (0, [T0(), "eA"])])
build("in15hcok", [(0, ["bA"]), (0, [ctrl(hc())]), (0, [T0(), "eA"])])
# G4 구간 안 숨은 설명의 글자는 primary 가 아님(run 직속 hp:t 만)
build("in15hcout", [(0, ["bA"]), (0, [ctrl(hc())]), (7, [T0(), "eA", tx("밖")])])
EOF
[ $? -eq 0 ] && pass fixtures15 || bad fixtures15 "픽스처 생성 실패"
G3M='구간 안에 글자가 아닌 내용이 있음'
SAVEM='한/글이 열지 못하는 문서가 되어 저장하지 않았습니다'
# 사용: f15 <파일> <기대 fields 줄 꼬리(빈 값=fill 가능)> <시험 이름>
f15() { "$H" fields "$T/$1.hwpx" > "$T/f15$1.txt" 2>&1
  grep -qxF -- "- A (누름틀 필드)$2" "$T/f15$1.txt" && pass "$3" || bad "$3" "$(sed 1d "$T/f15$1.txt" | tr '\n' '/')"; }

# 95. 끝 run 의 eA 뒤 글자 없는 ctrl(책갈피·숨은 설명·단 정의·쪽 감추기·쪽 번호 제어·새 번호)은 '안 보임':
#     fields·fill·사후 검사 모두 채운다(끝 run 서식이 시작 run 으로 바뀌는 것은 안 보이므로 허용). 숨은 설명 안 글자는 그대로
for k in bookmark hiddenComment colPr pageHiding pageNumCtrl newNum; do
  f15 "nt15$k" "" "notext-$k-fields"
  fill11 "nt15$k" '{"A": "가"}' "95f$k"; rc=$?; want_ok "95f$k" "A=가" "notext-$k-fill"
  nfill11 "nt15$k" '{"A": "가"}' "95n$k"; rc=$?; want_ok "95n$k" "A=가" "notext-$k-post"
done
v=$([ -e "$T/o95fhiddenComment.hwpx" ] && tcharpr "$T/o95fhiddenComment.hwpx" 숨은 || echo 출력없음); [ "$v" = 0 ] && pass notext-hiddenComment-inner-kept || bad notext-hiddenComment-inner-kept "$v"
f15 nt15bmtxt " (fill 불가: $C81)" notext-then-text-fields
fill11 nt15bmtxt '{"A": "가"}' 95g; rc=$?; want_err 95g "ERROR 채우지 못한 키: A($C81)" notext-then-text-fill
nfill11 nt15bmtxt '{"A": "가"}' 95h; rc=$?; want_err 95h "ERROR 요청한 키(A)를 $C81" notext-then-text-post
# 95b. 보이는 ctrl(쪽 번호·각주·미주)과 처음 보는 ctrl 자식은 계속 '보임'(거부 목록 방식 금지)
for k in pageNum footNote endNote unknown; do
  f15 "sh15$k" " (fill 불가: $C81)" "shown-$k-fields"
  fill11 "sh15$k" '{"A": "가"}' "95s$k"; rc=$?; want_err "95s$k" "ERROR 채우지 못한 키: A($C81)" "shown-$k-fill"
  nfill11 "sh15$k" '{"A": "가"}' "95t$k"; rc=$?; want_err "95t$k" "ERROR 요청한 키(A)를 $C81" "shown-$k-post"
done

# 96. 한 hp:ctrl 안의 경계는 자식 단위: fieldEnd 뒤 자동 번호는 '구간 밖 보이는 것'(거부, 사후 검사도),
#     fieldEnd 뒤 책갈피는 안 보임(채움), fieldEnd 앞 자동 번호는 구간 안 글자 아닌 내용(G3)
f15 mix15auto " (fill 불가: $C81)" mixed-ctrl-auto-fields
fill11 mix15auto '{"A": "가"}' 96a; rc=$?; want_err 96a "ERROR 채우지 못한 키: A($C81)" mixed-ctrl-auto-fill
nfill11 mix15auto '{"A": "가"}' 96b; rc=$?; want_err 96b "ERROR 요청한 키(A)를 $C81" mixed-ctrl-auto-post
f15 mix15bm "" mixed-ctrl-bookmark-fields
fill11 mix15bm '{"A": "가"}' 96c; rc=$?; want_ok 96c "A=가" mixed-ctrl-bookmark-fill
nfill11 mix15bm '{"A": "가"}' 96d; rc=$?; want_ok 96d "A=가" mixed-ctrl-bookmark-post
f15 mix15autoin " (fill 불가: $G3M)" mixed-ctrl-auto-inside-fields
fill11 mix15autoin '{"A": "가"}' 96e; rc=$?; want_err 96e "ERROR 채우지 못한 키: A($G3M)" mixed-ctrl-auto-inside-fill

# 97. 빈 문자열 id·beginIDRef 는 '없음'과 같다: fields·fill 이 열자마자 F4 문구로 거부
for f in emp15end emp15only emp15multi emp15id emp15ref; do
  "$H" fields "$T/$f.hwpx" > "$T/97$f.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(cat "$T/97$f.txt")" = "ERROR $F4M: $T/$f.hwpx" ] && pass "empty-id-$f-fields" || bad "empty-id-$f-fields" "rc=$rc $(tr '\n' '/' < "$T/97$f.txt")"
  fill11 $f '{"A": "가"}' "97f$f"; rc=$?; want_err "97f$f" "ERROR $F4M: $T/$f.hwpx" "empty-id-$f-fill"
done
# 97b. 라이브러리 저장 검증 실패(HwpxPackageError)는 고정 한국어 한 줄, 영문 원문·출력 파일 없음(fill·from-md)
savefail() { "$PY" -I -B -W ignore - "$KIT/skills/hwpx/scripts/hwpx_tool.py" "$@" <<'EOF'
import importlib.util, sys, hwpx
from hwpx.opc.package import HwpxPackageError
def boom(self, *a, **k): raise HwpxPackageError("Generated HWPX package failed open-safety validation: injected")
hwpx.HwpxDocument.save_to_path = boom
spec = importlib.util.spec_from_file_location("hwpx_tool_sf", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
sys.exit(mod.run(sys.argv[2:]))
EOF
}
printf '{"A": "가"}' > "$T/v97s.json"; rm -f "$T/o97s.hwpx"
savefail fill "$T/plain11.hwpx" "$T/v97s.json" "$T/o97s.hwpx" > "$T/97s.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(first "$T/97s.txt")" = "ERROR $SAVEM: $T/o97s.hwpx" ] && [ ! -e "$T/o97s.hwpx" ] \
  && ! grep -q 'HwpxPackageError\|open-safety\|Traceback' "$T/97s.txt" && pass save-check-korean-fill || bad save-check-korean-fill "rc=$rc $(tr '\n' '/' < "$T/97s.txt")"
printf '# 제목\n' > "$T/97m.md"; rm -f "$T/o97m.hwpx"
savefail from-md "$T/97m.md" "$T/o97m.hwpx" > "$T/97m.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(first "$T/97m.txt")" = "ERROR $SAVEM: $T/o97m.hwpx" ] && [ ! -e "$T/o97m.hwpx" ] \
  && ! grep -q 'HwpxPackageError\|open-safety\|Traceback' "$T/97m.txt" && pass save-check-korean-from-md || bad save-check-korean-from-md "rc=$rc $(tr '\n' '/' < "$T/97m.txt")"
[ -z "$(find "$T" -maxdepth 1 -name '.hwpx-*.tmp' 2>/dev/null)" ] && pass save-check-no-tmp-left || bad save-check-no-tmp-left "임시 파일 남음"

# 98. 구간 안에 글자가 아닌 보이는 내용(덧말·자동 번호·표)이 있으면 fill 불가(값이 기존 내용 옆에 붙으므로).
#     이 사유가 서식 사유보다 먼저. 허용 목록 ctrl(책갈피·숨은 설명)은 구간 안에 있어도 채운다
for f in in15dutmal in15auto in15tbl in15tblout; do
  f15 $f " (fill 불가: $G3M)" "inside-nontext-$f-fields"
  fill11 $f '{"A": "가"}' "98$f"; rc=$?; want_err "98$f" "ERROR 채우지 못한 키: A($G3M)" "inside-nontext-$f-fill"
done
for f in in15bm in15hcok; do
  f15 $f "" "inside-notext-$f-fields"
  fill11 $f '{"A": "가"}' "98$f"; rc=$?; want_ok "98$f" "A=가" "inside-notext-$f-fill"
done
# G4. 구간 안 숨은 설명의 글자는 값이 들어갈 자리가 아니다: 정적 판정도 끝 run(7)을 기준으로 서식 사유를 낸다
f15 in15hcout " (fill 불가: $C81)" primary-run-direct-fields
fill11 in15hcout '{"A": "가"}' 98g; rc=$?; want_err 98g "ERROR 채우지 못한 키: A($C81)" primary-run-direct-fill

# 99. wrapper: 끝나지 않는 파이썬이면 사전 점검이 몇 초 안에 끊고 '실행할 수 없음' 한 줄(rc=2, stderr 비어 있음).
#     바깥 alarm 20초는 시험이 멈추지 않게 하는 안전판(걸리면 rc 142 로 실패)
rm -rf "${T:?}/py99"; mkdir -p "$T/py99"
printf '#!/bin/sh\nexec /bin/sleep 30\n' > "$T/py99/hangpy"; chmod 755 "$T/py99/hangpy"
SECONDS=0
CLAUDE_LMS_PY="$T/py99/hangpy" /usr/bin/perl -e 'alarm 20; exec @ARGV' "$H" fields "$T/plain11.hwpx" > "$T/99.txt" 2> "$T/99.err"; rc=$?
el=$SECONDS
[ $rc -eq 2 ] && [ "$(cat "$T/99.txt")" = "ERROR 파이썬을 실행할 수 없음: $T/py99/hangpy (guardian 번들 설치 필요)" ] && [ ! -s "$T/99.err" ] && [ $el -le 12 ] \
  && pass wrapper-python-hang-timeout || bad wrapper-python-hang-timeout "rc=$rc ${el}s $(tr '\n' '/' < "$T/99.txt") err=$(head -c 80 "$T/99.err")"
rm -rf "${T:?}/py99"

# 100. 위치 키(실제 양식의 같은 라벨 여러 칸): fields 가 보여 준 '라벨 (표 N, 행 M[, 열 C])' 를 그대로 JSON 키로 쓰면 그 칸을 채운다.
#      같은 라벨 줄에는 왼쪽 칸 글자(묶음 이름)를 ' ← ' 뒤에 덧붙이고, fill 은 ' ← ' 부터 끝까지를 무시한다.
#      맨 이름(위치 없음)이 여러 칸이면 계속 거부하되 쓸 수 있는 위치 키를 알려 준다. 숫자·기호뿐인 라벨은 fields 에서 생략.
#      겹친 병합 표: read 는 그 표만 단순하게 보여 주고 계속, fields 는 그 표를 건너뛴다고 알린다.
"$PY" -I -W ignore - "$T/pos.hwpx" "$T/noise.hwpx" "$T/broken.hwpx" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("제안서")
t = d.add_table(4, 3)
t.cell(0, 0).text = "사업 책임자"; t.cell(2, 0).text = "행정 실무자"
for r, l in ((0, "성명"), (1, "전화"), (2, "성명"), (3, "전화")): t.cell(r, 1).text = l
t.merge_cells(0, 0, 1, 0); t.merge_cells(2, 0, 3, 0)
u = d.add_table(1, 4); u.cell(0, 0).text = "성명"; u.cell(0, 2).text = "성명:"
d.save_to_path(sys.argv[1])
n = HwpxDocument.new(); n.add_paragraph("견적")
v = n.add_table(3, 2); v.cell(0, 0).text = "1"; v.cell(1, 0).text = "0,000,000"; v.cell(2, 0).text = "담당자"
n.save_to_path(sys.argv[2])
b = HwpxDocument.new(); b.add_paragraph("앞 문단")
ok = b.add_table(1, 2); ok.cell(0, 0).text = "기관명"
x = b.add_table(2, 2)
x.cell(0, 0).text = "알파셀"; x.cell(0, 1).text = "베타셀"; x.cell(1, 0).text = "감마셀"; x.cell(1, 1).text = "델타셀"
for s in x.cell(0, 0).element.iter():
    if s.tag.endswith("cellSpan"): s.set("colSpan", "2")
b.add_paragraph("뒤 문단")
b.save_to_path(sys.argv[3])
EOF
cells100() { "$PY" -I -W ignore - "$1" <<'EOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.open(sys.argv[1])
for n, t in enumerate(d.tables.all):
    for p in t.iter_grid():
        if p.is_anchor and (s := t.cell(*p.anchor).text.strip()): print(f"{n},{p.row},{p.column}={s}")
EOF
}
json100() { "$PY" -I -c 'import json,sys; it=iter(sys.argv[1:]); print(json.dumps(dict(zip(it, it)), ensure_ascii=False))' "$@"; }
"$H" fields "$T/pos.hwpx" > "$T/100f.txt" 2>&1
# 100a. 같은 라벨 칸마다 위치가 보이고, 위치 키로는 채울 수 있으므로 'fill 불가' 가 아니다
grep -q '^- 성명 (표 0, 행 0)' "$T/100f.txt" && grep -q '^- 성명 (표 0, 행 2)' "$T/100f.txt" && grep -q '^- 전화 (표 0, 행 3)' "$T/100f.txt" \
  && ! grep -q 'fill 불가' "$T/100f.txt" && pass poskey-fields-listed || bad poskey-fields-listed "$(tr '\n' '/' < "$T/100f.txt")"
# 100b. 같은 라벨 줄에는 왼쪽 칸(세로 병합 포함)의 묶음 이름이 ' ← ' 뒤에 붙는다
grep '^- 성명 (표 0, 행 0)' "$T/100f.txt" | grep -q ' ← .*사업 책임자' && grep '^- 전화 (표 0, 행 1)' "$T/100f.txt" | grep -q ' ← .*사업 책임자' \
  && grep '^- 성명 (표 0, 행 2)' "$T/100f.txt" | grep -q ' ← .*행정 실무자' && ! grep '^- 성명 (표 0, 행 2)' "$T/100f.txt" | grep -q '사업 책임자' \
  && pass poskey-fields-group-context || bad poskey-fields-group-context "$(tr '\n' '/' < "$T/100f.txt")"
# 100c. 한 행에 같은 라벨(정규화 후)이 둘이면 열 번호까지 보인다
grep -q '^- 성명 (표 1, 행 0, 열 0)' "$T/100f.txt" && grep -q '^- 성명: (표 1, 행 0, 열 2)' "$T/100f.txt" \
  && pass poskey-fields-column || bad poskey-fields-column "$(tr '\n' '/' < "$T/100f.txt")"
# 100d. 위치 키로 채우면 정확히 그 칸에 들어간다(다른 칸은 그대로)
json100 '성명 (표 0, 행 0)' 홍길동 '성명 (표 0, 행 2)' 김철수 '전화 (표 0, 행 1)' 010-1 '성명 (표 1, 행 0, 열 0)' 가 '성명: (표 1, 행 0, 열 2)' 나 > "$T/v100d.json"
"$H" fill "$T/pos.hwpx" "$T/v100d.json" "$T/o100d.hwpx" > "$T/100d.txt" 2>&1; rc=$?
c100="$(cells100 "$T/o100d.hwpx" 2>&1 | tr '\n' '/')"
[ $rc -eq 0 ] && [ "$(first "$T/100d.txt")" = "OK $T/o100d.hwpx" ] \
  && [ "$c100" = "0,0,0=사업 책임자/0,0,1=성명/0,0,2=홍길동/0,1,1=전화/0,1,2=010-1/0,2,0=행정 실무자/0,2,1=성명/0,2,2=김철수/0,3,1=전화/1,0,0=성명/1,0,1=가/1,0,2=성명:/1,0,3=나/" ] \
  && pass poskey-fill-exact-cells || bad poskey-fill-exact-cells "rc=$rc $(first "$T/100d.txt") cells=$c100"
# 100e. fields 줄을 '- ' 만 떼고 통째로(' ← 묶음' 포함) 키로 써도 같은 칸을 채운다
line100="$(grep '^- 성명 (표 0, 행 2)' "$T/100f.txt" | head -1)"; line100="${line100#- }"
json100 "$line100" 김철수 > "$T/v100e.json"
"$H" fill "$T/pos.hwpx" "$T/v100e.json" "$T/o100e.hwpx" > "$T/100e.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && cells100 "$T/o100e.hwpx" | grep -qx '0,2,2=김철수' && ! cells100 "$T/o100e.hwpx" | grep -q '^0,0,2=' \
  && pass poskey-fill-whole-line || bad poskey-fill-whole-line "rc=$rc key=[$line100] $(first "$T/100e.txt")"
# 100f. 맨 이름이 여러 칸이면 거부하되 ERROR 에 쓸 수 있는 위치 키를 보여 준다(출력 없음)
json100 전화 010 > "$T/v100f.json"
"$H" fill "$T/pos.hwpx" "$T/v100f.json" "$T/o100f.hwpx" > "$T/100fl.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*전화' "$T/100fl.txt" && grep -qF '전화 (표 0, 행 1)' "$T/100fl.txt" && grep -qF '전화 (표 0, 행 3)' "$T/100fl.txt" \
  && [ ! -e "$T/o100f.hwpx" ] && [ "$(wc -l < "$T/100fl.txt" | tr -d ' ')" = "1" ] && pass poskey-bare-duplicate-hint || bad poskey-bare-duplicate-hint "rc=$rc $(tr '\n' '/' < "$T/100fl.txt")"
# 100g. 한 행에 같은 라벨이 둘인데 열 없이 쓰면 거부(열을 쓰라고 안내), 출력 없음
json100 '성명 (표 1, 행 0)' 가 > "$T/v100g.json"
"$H" fill "$T/pos.hwpx" "$T/v100g.json" "$T/o100g.hwpx" > "$T/100g.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR .*열' "$T/100g.txt" && [ ! -e "$T/o100g.hwpx" ] && pass poskey-row-needs-column || bad poskey-row-needs-column "rc=$rc $(first "$T/100g.txt")"
# 100h. 그 위치에 그 라벨이 없으면 거부(라벨 글자가 다르거나 행이 틀림), 출력 없음
json100 '전화 (표 0, 행 0)' 010 > "$T/v100h.json"
"$H" fill "$T/pos.hwpx" "$T/v100h.json" "$T/o100h.hwpx" > "$T/100h.txt" 2>&1; rc=$?
json100 '성명 (표 7, 행 0)' 가 > "$T/v100h2.json"
"$H" fill "$T/pos.hwpx" "$T/v100h2.json" "$T/o100h2.hwpx" > "$T/100h2.txt" 2>&1; rc2=$?
[ $rc -ne 0 ] && grep -qF 'ERROR ' "$T/100h.txt" && grep -qF '전화 (표 0, 행 0)' "$T/100h.txt" && [ ! -e "$T/o100h.hwpx" ] \
  && [ $rc2 -ne 0 ] && grep -q '^ERROR ' "$T/100h2.txt" && [ ! -e "$T/o100h2.hwpx" ] && pass poskey-wrong-position || bad poskey-wrong-position "rc=$rc/$rc2 $(first "$T/100h.txt") / $(first "$T/100h2.txt")"
# 100i. 두 키가 같은 칸이면(위치 키와 ' ← ' 붙은 같은 키) 조용히 덮어쓰지 않고 거부
json100 '성명 (표 0, 행 2)' 가 "$line100" 나 > "$T/v100i.json"
"$H" fill "$T/pos.hwpx" "$T/v100i.json" "$T/o100i.hwpx" > "$T/100i.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/100i.txt" && [ ! -e "$T/o100i.hwpx" ] && pass poskey-same-target || bad poskey-same-target "rc=$rc $(first "$T/100i.txt")"
# 100j. 위치 키도 이미 값이 있는 칸은 덮어쓰지 않는다 / 값이 없는 쪽은 채운다(form2: 표 1 의 성명=김철수)
json100 '성명 (표 1, 행 0)' 박영희 > "$T/v100j.json"
"$H" fill "$T/form2.hwpx" "$T/v100j.json" "$T/o100j.hwpx" > "$T/100j.txt" 2>&1; rc=$?
json100 '성명 (표 0, 행 0)' 박영희 > "$T/v100j2.json"
"$H" fill "$T/form2.hwpx" "$T/v100j2.json" "$T/o100j2.hwpx" > "$T/100j2.txt" 2>&1; rc2=$?
[ $rc -ne 0 ] && grep -q '이미 값' "$T/100j.txt" && [ ! -e "$T/o100j.hwpx" ] \
  && [ $rc2 -eq 0 ] && cells100 "$T/o100j2.hwpx" | grep -qx '0,0,1=박영희' && cells100 "$T/o100j2.hwpx" | grep -qx '1,0,1=김철수' \
  && pass poskey-no-overwrite || bad poskey-no-overwrite "rc=$rc/$rc2 $(first "$T/100j.txt") / $(first "$T/100j2.txt")"
# 100k. 숫자·기호뿐인 라벨('1', '0,000,000')은 fields 목록에서 빼고, 뺀 개수를 '- ' 로 시작하지 않는 한 줄로 알린다
"$H" fields "$T/noise.hwpx" > "$T/100k.txt" 2>&1
grep -q '^- 담당자 (표 0, 행 2)' "$T/100k.txt" && ! grep -q '^- 1 (' "$T/100k.txt" && ! grep -q '^- 0,000,000' "$T/100k.txt" \
  && grep -v '^- ' "$T/100k.txt" | grep -v '^OK ' | grep -q '2' && pass fields-skip-symbol-labels || bad fields-skip-symbol-labels "$(tr '\n' '/' < "$T/100k.txt")"
# 100l. 겹친 병합 표: read 는 OK(rc 0) 로 계속하고 그 표의 글자와 앞뒤 본문·다른 표를 모두 보여 주며 그 표가 단순 표시임을 알린다
"$H" read "$T/broken.hwpx" > "$T/100l.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/100l.txt")" = "OK $T/broken.hwpx" ] && ! grep -q '내부 오류' "$T/100l.txt" \
  && grep -q '앞 문단' "$T/100l.txt" && grep -q '뒤 문단' "$T/100l.txt" && grep -q '기관명' "$T/100l.txt" \
  && grep -q '알파셀' "$T/100l.txt" && grep -q '베타셀' "$T/100l.txt" && grep -q '감마셀' "$T/100l.txt" && grep -q '델타셀' "$T/100l.txt" \
  && grep -q '겹' "$T/100l.txt" && pass read-overlapping-table-fallback || bad read-overlapping-table-fallback "rc=$rc $(head -c 300 "$T/100l.txt" | tr '\n' '/')"
# 100m. fields 는 겹친 병합 표를 건너뛴다고 '- ' 로 시작하지 않는 줄로 알리고, 다른 표의 라벨은 그대로 보이고 채워진다
"$H" fields "$T/broken.hwpx" > "$T/100m.txt" 2>&1; rc=$?
json100 기관명 가나기관 > "$T/v100m.json"
"$H" fill "$T/broken.hwpx" "$T/v100m.json" "$T/o100m.hwpx" > "$T/100m2.txt" 2>&1; rc2=$?
[ $rc -eq 0 ] && grep -q '^- 기관명 (표 0, 행 0)' "$T/100m.txt" && grep -v '^- ' "$T/100m.txt" | grep -q '표 1.*겹' \
  && [ $rc2 -eq 0 ] && cells100 "$T/o100m.hwpx" 2>/dev/null | grep -qx '0,0,1=가나기관' \
  && pass fields-notes-overlapping-table || bad fields-notes-overlapping-table "rc=$rc/$rc2 $(tr '\n' '/' < "$T/100m.txt") / $(first "$T/100m2.txt")"
# 100n. 다른 표의 같은 라벨: 표 바로 앞 본문 문단(표 밖, 최대 2개)을 ' ← ' 뒤에 붙여 어느 표인지 구분한다
"$PY" -I -W ignore - "$T/pos2.hwpx" <<'PYEOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new(); d.add_paragraph("가. 총괄책임자"); d.add_paragraph("1) 인적사항")
a = d.add_table(1, 2); a.cell(0, 0).text = "성명"
d.add_paragraph("나. 실무 담당자"); d.add_paragraph("1) 인적사항")
b = d.add_table(1, 2); b.cell(0, 0).text = "성명"
d.save_to_path(sys.argv[1])
PYEOF
"$H" fields "$T/pos2.hwpx" > "$T/100n.txt" 2>&1
grep '^- 성명 (표 0, 행 0)' "$T/100n.txt" | grep -q ' ← .*총괄책임자' && grep '^- 성명 (표 1, 행 0)' "$T/100n.txt" | grep -q ' ← .*실무 담당자' \
  && ! grep '^- 성명 (표 1, 행 0)' "$T/100n.txt" | grep -q '총괄책임자' && ! grep -q 'fill 불가' "$T/100n.txt" \
  && pass poskey-fields-paragraph-context || bad poskey-fields-paragraph-context "$(tr '\n' '/' < "$T/100n.txt")"

# 101. 실제 양식에서 gemma 가 사용자 말투로 키를 지어내면(예: '사업책임자(PM) 성명') fill 은 그대로 거부하되
#      ERROR 같은 줄에 '; 다시 시도할 키: <키> → <위치 키>[ 또는 <위치 키>…]' 를 붙여 고칠 키를 알려 준다(자동으로 채우지 않음).
#      후보: 라벨(공백 제거)이 키(공백 제거)에 들어 있는 자리. 키의 나머지가 그 자리 문맥(← 뒤)과 맞는 자리만 남기고,
#      맞는 자리가 없으면 후보 전부. 후보가 없으면 '→ 없음(fields …)'. 위치 키 라벨의 줄바꿈은 공백 한 칸으로,
#      문맥이 빈 줄에는 ' ← ' 를 붙이지 않는다. SKILL.md 는 키를 지어내지 말고 '다시 시도할 키' 로 고쳐 다시 fill 하라고 쓴다.
seg101() { tr ';' '\n' < "$1" | sed 's/^ *//' | grep -F "다시 시도할 키: $2 → "; }
# 101a. 문맥과 맞는 위치 키 하나만 알려 주고, 원래 사유 '(라벨 없음)' 은 그대로, 결과 파일은 만들지 않는다
json100 '사업책임자(PM) 성명' 홍길동 > "$T/v101a.json"
"$H" fill "$T/pos.hwpx" "$T/v101a.json" "$T/o101a.hwpx" > "$T/101a.txt" 2>&1; rc=$?
s=$(seg101 "$T/101a.txt" '사업책임자(PM) 성명')
[ $rc -ne 0 ] && [ "$(wc -l < "$T/101a.txt" | tr -d ' ')" = "1" ] && grep -q '^ERROR .*사업책임자(PM) 성명(라벨 없음)' "$T/101a.txt" \
  && [ "$s" = "다시 시도할 키: 사업책임자(PM) 성명 → 성명 (표 0, 행 0)" ] && [ ! -e "$T/o101a.hwpx" ] \
  && pass fill-unknown-key-hint || bad fill-unknown-key-hint "rc=$rc $(first "$T/101a.txt")"
# 101b. 다른 묶음(행정 실무자)은 그 자리를, 키 두 개가 모두 틀리면 키마다 한 조각씩
json100 '행정실무자 성명' 김철수 '사업 책임자 전화' 010 > "$T/v101b.json"
"$H" fill "$T/pos.hwpx" "$T/v101b.json" "$T/o101b.hwpx" > "$T/101b.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(seg101 "$T/101b.txt" '행정실무자 성명')" = "다시 시도할 키: 행정실무자 성명 → 성명 (표 0, 행 2)" ] \
  && [ "$(seg101 "$T/101b.txt" '사업 책임자 전화')" = "다시 시도할 키: 사업 책임자 전화 → 전화 (표 0, 행 1)" ] && [ ! -e "$T/o101b.hwpx" ] \
  && pass fill-unknown-key-hint-group || bad fill-unknown-key-hint-group "rc=$rc $(first "$T/101b.txt")"
# 101c. 문맥이 어느 자리와도 안 맞으면 그 라벨의 후보를 모두(' 또는 '), 후보가 없으면 fields 를 보라고 한다
json100 '담당 성명' 가 '주소' 나 > "$T/v101c.json"
"$H" fill "$T/pos.hwpx" "$T/v101c.json" "$T/o101c.hwpx" > "$T/101c.txt" 2>&1; rc=$?
s=$(seg101 "$T/101c.txt" '담당 성명'); s2=$(seg101 "$T/101c.txt" '주소')
[ $rc -ne 0 ] && printf '%s' "$s" | grep -qF '성명 (표 0, 행 0) 또는 ' && printf '%s' "$s" | grep -qF '성명 (표 0, 행 2)' \
  && printf '%s' "$s" | grep -qF '성명 (표 1, 행 0, 열 0)' && printf '%s' "$s2" | grep -qF '주소 → 없음' && printf '%s' "$s2" | grep -qF 'fields' \
  && [ ! -e "$T/o101c.hwpx" ] && pass fill-unknown-key-hint-all || bad fill-unknown-key-hint-all "rc=$rc $(first "$T/101c.txt")"
# 101d. 맞는 키는 힌트 없이 그대로 채워진다(기존 동작 유지)
json100 '성명 (표 0, 행 2)' 김철수 > "$T/v101d.json"
"$H" fill "$T/pos.hwpx" "$T/v101d.json" "$T/o101d.hwpx" > "$T/101d.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -q '다시 시도할 키' "$T/101d.txt" && cells100 "$T/o101d.hwpx" | grep -qx '0,2,2=김철수' \
  && pass fill-good-key-no-hint || bad fill-good-key-no-hint "rc=$rc $(first "$T/101d.txt")"
# 101e. 문맥이 없는 위치 키 줄은 ' ← ' 없이 끝나고, 줄바꿈이 든 라벨은 위치 키에서 공백 한 칸으로 보이며 그 키로 채워진다
"$PY" -I -W ignore - "$T/nl101.hwpx" <<'PYEOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new()
t = d.add_table(4, 2)
for r, l in ((0, "성명"), (1, "성명"), (2, "주요\n내용"), (3, "주요\n내용")): t.cell(r, 0).text = l
d.save_to_path(sys.argv[1])
PYEOF
"$H" fields "$T/nl101.hwpx" > "$T/101e.txt" 2>&1; rc=$?
json100 '주요 내용 (표 0, 행 3)' 요약 > "$T/v101e.json"
"$H" fill "$T/nl101.hwpx" "$T/v101e.json" "$T/o101e.hwpx" > "$T/101e2.txt" 2>&1; rc2=$?
[ $rc -eq 0 ] && grep -qx -- '- 성명 (표 0, 행 0)' "$T/101e.txt" && grep -qx -- '- 주요 내용 (표 0, 행 2)' "$T/101e.txt" \
  && ! grep -qE '←[[:space:]]*$' "$T/101e.txt" && ! grep -qF '주요\n내용 (표' "$T/101e.txt" \
  && [ $rc2 -eq 0 ] && cells100 "$T/o101e.hwpx" | grep -qx '0,3,1=요약' \
  && pass fields-poskey-clean-line || bad fields-poskey-clean-line "rc=$rc/$rc2 $(tr '\n' '/' < "$T/101e.txt") / $(first "$T/101e2.txt")"
# 101f. 실제 양식 fields 에서도 빈 문맥 꼬리가 없다(문맥 있는 줄은 그대로: 100n)
"$H" fields "$T/pos.hwpx" > "$T/101f.txt" 2>&1
! grep -qE '←[[:space:]]*$' "$T/101f.txt" && grep '^- 성명 (표 0, 행 0)' "$T/101f.txt" | grep -q ' ← .*사업 책임자' \
  && pass fields-no-empty-context || bad fields-no-empty-context "$(tr '\n' '/' < "$T/101f.txt")"
# 101h. 바깥 묶음 칸(책임자)이 두 묶음을 다 덮는 실제 양식 모양: 문맥 일치가 여럿이면 가장 길게 맞은 자리만 남긴다
#       (키 나머지 전체가 문맥에 들어 있으면 그 길이, 아니면 키 나머지에 든 가장 긴 문맥 조각 길이). 같으면 모두.
"$PY" -I -W ignore - "$T/nest101.hwpx" <<'PYEOF'
import sys
from hwpx import HwpxDocument
d = HwpxDocument.new()
t = d.add_table(4, 4)
t.cell(0, 0).text = "책임자"; t.cell(0, 1).text = "사업 책임자 (PM)"; t.cell(2, 1).text = "행정 실무자"
for r, l in ((0, "성명"), (1, "전화"), (2, "성명"), (3, "전화")): t.cell(r, 2).text = l
t.merge_cells(0, 0, 3, 0); t.merge_cells(0, 1, 1, 1); t.merge_cells(2, 1, 3, 1)
d.save_to_path(sys.argv[1])
PYEOF
json100 '사업책임자(PM) 성명' 홍 '행정실무자 성명' 김 '책임자 성명' 이 > "$T/v101h.json"
"$H" fill "$T/nest101.hwpx" "$T/v101h.json" "$T/o101h.hwpx" > "$T/101h.txt" 2>&1; rc=$?
"$H" fields "$T/nest101.hwpx" > "$T/101h2.txt" 2>&1
s=$(seg101 "$T/101h.txt" '책임자 성명')
grep '^- 성명 (표 0, 행 0)' "$T/101h2.txt" | grep -q '사업 책임자 (PM)' && [ $rc -ne 0 ] && [ ! -e "$T/o101h.hwpx" ] \
  && [ "$(seg101 "$T/101h.txt" '사업책임자(PM) 성명')" = "다시 시도할 키: 사업책임자(PM) 성명 → 성명 (표 0, 행 0)" ] \
  && [ "$(seg101 "$T/101h.txt" '행정실무자 성명')" = "다시 시도할 키: 행정실무자 성명 → 성명 (표 0, 행 2)" ] \
  && printf '%s' "$s" | grep -qF '성명 (표 0, 행 0)' && printf '%s' "$s" | grep -qF '성명 (표 0, 행 2)' \
  && pass fill-unknown-key-hint-longest || bad fill-unknown-key-hint-longest "rc=$rc $(first "$T/101h.txt") / $(tr '\n' '/' < "$T/101h2.txt")"
# 101g. SKILL.md: 사용자 말로 키를 지어내지 말고 fields 줄을 복사, ERROR 의 '다시 시도할 키' 로 JSON 을 고쳐 fill 을 다시 실행
SK="$KIT/skills/hwpx/SKILL.md"
grep -qF '키를 지어내지' "$SK" && grep -qF '다시 시도할 키' "$SK" && ! grep -qF '사유를 그대로 전한다' "$SK" \
  && grep -qF 'fields' "$SK" && [ "$(wc -c < "$SK" | tr -d ' ')" -le 3000 ] \
  && pass skill-md-retry-rule || bad skill-md-retry-rule "$(grep -n 'ERROR\|지어내\|다시 시도' "$SK" | tr '\n' '/')"

# 102. 실제 양식에서 gemma 가 값.json 의 바깥 중괄호를 빼먹는다('"키": "값",' 줄만, f1-a). 뜻이 하나뿐이므로
#      맨 앞이 '{' 가 아니고 빈 파일이 아니면 '{' + 글 + '}' 로 한 번 더 읽어 객체면 그대로 쓴다(같은 키·값 형식 검사는 그대로).
#      그래도 못 읽으면 기존 'JSON 파싱 실패: <경로> (…)' 뒤에 고치는 법 한 조각을 붙인다. 다른 오류 문구는 그대로.
HINT102='; JSON 은 { 로 시작해 } 로 끝나야 하고 마지막 값 뒤에는 쉼표를 쓰지 않습니다'
fill102() { printf "$2" > "$T/v$3.json"; rm -f "$T/o$3.hwpx"; "$H" fill "$T/$1.hwpx" "$T/v$3.json" "$T/o$3.hwpx" > "$T/$3.txt" 2>&1; }
# 102a. 중괄호 없는 '"키": "값",' 줄(마지막 줄 쉼표 없음, 끝 줄바꿈)도 채우고 검증 통과
fill102 pos '"성명 (표 0, 행 0)": "홍길동",\n"전화 (표 0, 행 1)": "010"\n' 102a; rc=$?
[ $rc -eq 0 ] && case "$(first "$T/102a.txt")" in "OK "*) true ;; *) false ;; esac && grep -qF '검증 통과' "$T/102a.txt" \
  && cells100 "$T/o102a.hwpx" | grep -qx '0,0,2=홍길동' && cells100 "$T/o102a.hwpx" | grep -qx '0,1,2=010' \
  && pass json-missing-braces-ok || bad json-missing-braces-ok "rc=$rc $(tr '\n' '/' < "$T/102a.txt")"
# 102b. 중괄호도 없고 마지막 쉼표까지 있으면 거부: 기존 문구로 시작하고 고치는 법이 붙는다(출력 없음)
fill102 pos '"성명 (표 0, 행 0)": "홍길동",\n' 102b; rc=$?
l=$(first "$T/102b.txt")
[ $rc -ne 0 ] && [ ! -e "$T/o102b.hwpx" ] && ! grep -q Traceback "$T/102b.txt" \
  && case "$l" in "ERROR JSON 파싱 실패: $T/v102b.json ("*"$HINT102") true ;; *) false ;; esac \
  && pass json-parse-fix-hint || bad json-parse-fix-hint "rc=$rc $l"
# 102c. 중괄호가 있어도 문법이 틀리면 같은 고치는 법이 붙는다
fill102 pos '{"성명 (표 0, 행 0)": "홍길동",}' 102c; rc=$?
l=$(first "$T/102c.txt")
[ $rc -ne 0 ] && [ ! -e "$T/o102c.hwpx" ] && case "$l" in "ERROR JSON 파싱 실패: $T/v102c.json ("*"$HINT102") true ;; *) false ;; esac \
  && pass json-parse-fix-hint-braced || bad json-parse-fix-hint-braced "rc=$rc $l"
# 102d. 중괄호를 보탠 뒤에도 같은 키 두 번·값 형식 검사는 그대로
fill102 pos '"성명 (표 0, 행 0)": "가",\n"성명 (표 0, 행 0)": "나"\n' 102d; rc=$?
want_err 102d "ERROR JSON 에 같은 키가 여러 번 있습니다: 성명 (표 0, 행 0)" json-missing-braces-dup-key
fill102 pos '"성명 (표 0, 행 0)": [1]\n' 102e; rc=$?
want_err 102e "ERROR 값은 문자열(또는 정수)이어야 합니다: 성명 (표 0, 행 0)" json-missing-braces-value-type
# 102f. 객체가 아닌 JSON(배열)은 지금 문구 그대로, 빈 파일은 '{}' 로 바꾸지 않고 파싱 실패
fill102 pos '[1]' 102f; rc=$?
want_err 102f 'ERROR JSON 은 {"키": "값"} 객체여야 합니다' json-array-still-rejected
fill102 pos '  \n' 102g; rc=$?
l=$(first "$T/102g.txt")
[ $rc -ne 0 ] && [ ! -e "$T/o102g.hwpx" ] && case "$l" in "ERROR JSON 파싱 실패: $T/v102g.json ("*) true ;; *) false ;; esac \
  && pass json-empty-file-rejected || bad json-empty-file-rejected "rc=$rc $l"

# 103(4차). from-md 출력 경로는 생략 가능: md 하나면 같은 폴더·같은 이름의 .hwpx, 기본 출력이 있으면 거부, 인자 0개·3개는 rc 2
cp "$T/in.md" "$T/보고_11월.md"
"$H" from-md "$T/보고_11월.md" > "$T/103.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/103.txt")" = "OK $T/보고_11월.hwpx" ] && [ -s "$T/보고_11월.hwpx" ] && pass from-md-default-output || bad from-md-default-output "rc=$rc $(first "$T/103.txt")"
cp "$T/in.md" "$T/one2.md"
( cd "$T" && "$H" from-md ./one2.md ) > "$T/103b.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(first "$T/103b.txt")" = "OK $T/one2.hwpx" ] && pass from-md-default-output-relative || bad from-md-default-output-relative "rc=$rc $(first "$T/103b.txt")"
s0=$(shasum "$T/보고_11월.hwpx")
"$H" from-md "$T/보고_11월.md" > "$T/103c.txt" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '^ERROR ' "$T/103c.txt" && [ "$(shasum "$T/보고_11월.hwpx")" = "$s0" ] && pass from-md-default-no-clobber || bad from-md-default-no-clobber "rc=$rc $(first "$T/103c.txt")"
"$H" from-md > "$T/103d.txt" 2>&1; rc=$?
"$H" from-md "$T/in.md" "$T/three.hwpx" "$T/extra.hwpx" > "$T/103e.txt" 2>&1; rc2=$?
[ $rc -eq 2 ] && grep -q '^ERROR ' "$T/103d.txt" && [ $rc2 -eq 2 ] && grep -q '^ERROR ' "$T/103e.txt" && [ ! -e "$T/three.hwpx" ] \
  && pass from-md-arg-count || bad from-md-arg-count "rc=$rc/$rc2 $(first "$T/103d.txt") / $(first "$T/103e.txt")"

[ $fail -eq 0 ] && echo "ACCEPT PASS" || { echo "ACCEPT FAIL"; exit 1; }
