#!/bin/bash
# docx·xlsx·pptx 스킬 공통 인수 시험. accept_<name>.sh 가 NAME, EXT 를 정한 뒤 source 한다.
# - CLAUDE_LMS_PY: python-docx·openpyxl·python-pptx 를 import 할 수 있는 파이썬
#   (배포 시 ~/.guardian-llm/venv/bin/python).
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$KIT/skills/$NAME/scripts/$NAME"
PY="${CLAUDE_LMS_PY:-$HOME/.guardian-llm/venv/bin/python}"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-$NAME.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
first() { head -1 "$1"; }
lines() { wc -l < "$1" | tr -d ' '; }
finish() { if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi; }

[ -x "$W" ] || { echo "FAIL wrapper missing or not executable: $W"; exit 1; }

# 다른 형식의 진짜 파일(형식 오인 시험용): x.docx, x.xlsx, x.pptx
"$PY" -I -W ignore - "$T" <<'EOF'
import sys
import docx, openpyxl, pptx
T = sys.argv[1]
d = docx.Document(); d.add_paragraph("워드 본문"); d.save(f"{T}/x.docx")
wb = openpyxl.Workbook(); wb.active["A1"] = "엑셀 칸"; wb.save(f"{T}/x.xlsx")
p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[0]); s.shapes.title.text = "발표 제목"; p.save(f"{T}/x.pptx")
EOF

# common_cases <기본 md> <read 에 보여야 할 글자>...
common_cases() {
  local md="$1"; shift
  local out="$T/out.$EXT"

  # C1. from-md: 첫 줄이 정확히 'OK <절대경로>', 파일 생성, read 로 되읽기
  "$W" from-md "$md" "$out" > "$T/c1.txt" 2>&1; rc=$?
  if [ $rc -eq 0 ] && [ "$(first "$T/c1.txt")" = "OK $out" ] && [ -s "$out" ]; then pass from-md; else bad from-md "rc=$rc $(first "$T/c1.txt")"; fi
  "$W" read "$out" > "$T/c1r.txt" 2>&1; rc=$?
  local ok=1 s
  [ $rc -eq 0 ] && [ "$(first "$T/c1r.txt")" = "OK $out" ] || ok=0
  for s in "$@"; do grep -qF -- "$s" "$T/c1r.txt" || { ok=0; echo "  (read 에 '$s' 없음)"; }; done
  [ $ok -eq 1 ] && pass read || bad read "rc=$rc $(head -3 "$T/c1r.txt" | tr '\n' ' ')"
  # 상대 경로로 실행해도 OK 줄은 절대 경로
  ( cd "$T" && "$W" from-md "./$(basename "$md")" "./rel.$EXT" ) > "$T/c1b.txt" 2>&1
  [ "$(first "$T/c1b.txt")" = "OK $T/rel.$EXT" ] && pass ok-line-absolute || bad ok-line-absolute "$(first "$T/c1b.txt")"

  # C2. 덮어쓰기 금지: 출력 = 입력, 이미 있는 파일, 끊어진 심볼릭 링크
  local s0 m0; s0=$(shasum "$md"); m0=$(stat -f %m "$md")
  "$W" from-md "$md" "$md" > "$T/c2.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR ' "$T/c2.txt" && [ "$(shasum "$md")" = "$s0" ] && [ "$(stat -f %m "$md")" = "$m0" ] && pass no-overwrite-input || bad no-overwrite-input "rc=$rc $(first "$T/c2.txt")"
  cp "$out" "$T/exists.$EXT"; s0=$(shasum "$T/exists.$EXT")
  "$W" from-md "$md" "$T/exists.$EXT" > "$T/c2b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR ' "$T/c2b.txt" && [ "$(shasum "$T/exists.$EXT")" = "$s0" ] && pass no-clobber-existing || bad no-clobber-existing "rc=$rc $(first "$T/c2b.txt")"
  ln -s "$T/link-target.$EXT" "$T/dangling.$EXT"
  "$W" from-md "$md" "$T/dangling.$EXT" > "$T/c2c.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR ' "$T/c2c.txt" && [ ! -e "$T/link-target.$EXT" ] && pass no-follow-dangling-symlink || bad no-follow-dangling-symlink "rc=$rc $(first "$T/c2c.txt")"

  # C3. 출력 확장자는 .$EXT 만, 없는 출력 폴더는 거부(파일 안 만듦)
  "$W" from-md "$md" "$T/wrong.hwpx" > "$T/c3.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c3.txt")" = "1" ] && grep -q "^ERROR .*\.$EXT" "$T/c3.txt" && [ ! -e "$T/wrong.hwpx" ] && pass output-extension || bad output-extension "rc=$rc $(first "$T/c3.txt")"
  "$W" from-md "$md" "$T/nodir/out.$EXT" > "$T/c3b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c3b.txt")" = "1" ] && grep -q '^ERROR ' "$T/c3b.txt" && ! grep -q '내부 오류' "$T/c3b.txt" && pass output-dir-missing || bad output-dir-missing "rc=$rc $(first "$T/c3b.txt")"

  # C4. 옛 형식·암호 걸린 파일(OLE 컨테이너): 트레이스백 없이 ERROR + .$EXT 로 다시 저장 안내
  printf '\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1garbage' > "$T/fake.$EXT"
  cp "$T/fake.$EXT" "$T/legacy.${EXT%x}"
  "$W" read "$T/fake.$EXT" > "$T/c4.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c4.txt")" = "1" ] && grep -q "^ERROR .*\.$EXT" "$T/c4.txt" && ! grep -q Traceback "$T/c4.txt" && pass ole-container || bad ole-container "rc=$rc $(first "$T/c4.txt")"
  "$W" read "$T/legacy.${EXT%x}" > "$T/c4b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c4b.txt")" = "1" ] && grep -q "^ERROR .*\.$EXT" "$T/c4b.txt" && pass legacy-format || bad legacy-format "rc=$rc $(first "$T/c4b.txt")"

  # C5. 다른 오피스 형식은 알맞은 스킬 이름으로 안내, OOXML 이 아닌 zip 은 '내부 오류' 가 아닌 한 줄 ERROR
  local o
  for o in docx xlsx pptx; do
    [ "$o" = "$EXT" ] && continue
    "$W" read "$T/x.$o" > "$T/c5-$o.txt" 2>&1; rc=$?
    [ $rc -ne 0 ] && [ "$(lines "$T/c5-$o.txt")" = "1" ] && grep -q "^ERROR .*$o" "$T/c5-$o.txt" && pass "wrong-type-$o" || bad "wrong-type-$o" "rc=$rc $(first "$T/c5-$o.txt")"
  done
  "$PY" -I - "$T/notooxml.$EXT" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("hello.txt", "x")
EOF
  "$W" read "$T/notooxml.$EXT" > "$T/c5b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c5b.txt")" = "1" ] && grep -q '^ERROR ' "$T/c5b.txt" && ! grep -q '내부 오류' "$T/c5b.txt" && pass not-ooxml-zip || bad not-ooxml-zip "rc=$rc $(first "$T/c5b.txt")"
  printf 'plain text' > "$T/text.$EXT"
  "$W" read "$T/text.$EXT" > "$T/c5c.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c5c.txt")" = "1" ] && grep -q '^ERROR ' "$T/c5c.txt" && ! grep -q '내부 오류' "$T/c5c.txt" && pass not-zip || bad not-zip "rc=$rc $(first "$T/c5c.txt")"

  # C6. 없는 파일 / 잘못된 명령 / 인자 부족(rc 2) / 파이썬 없음(한 줄)
  "$W" read "$T/nope.$EXT" > "$T/c6.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR ' "$T/c6.txt" && ! grep -q Traceback "$T/c6.txt" && pass missing-file || bad missing-file "rc=$rc $(first "$T/c6.txt")"
  "$W" bogus > "$T/c6b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR ' "$T/c6b.txt" && pass bad-command || bad bad-command "rc=$rc $(first "$T/c6b.txt")"
  # C6c(4차). from-md 출력 경로는 생략 가능: md 하나면 같은 폴더·같은 이름의 .$EXT(상대 경로도), 기본 출력이 이미 있으면 거부,
  #   인자 0개·3개는 사용법 오류(rc 2)
  cp "$md" "$T/회의록_11월.md"
  "$W" from-md "$T/회의록_11월.md" > "$T/c6c.txt" 2>&1; rc=$?
  if [ $rc -eq 0 ] && [ "$(first "$T/c6c.txt")" = "OK $T/회의록_11월.$EXT" ] && [ "$(head -c 4 "$T/회의록_11월.$EXT" | od -An -c | tr -d ' ')" = 'PK003004' ]; then
    pass from-md-default-output; else bad from-md-default-output "rc=$rc $(first "$T/c6c.txt")"; fi
  cp "$md" "$T/one2.md"
  ( cd "$T" && "$W" from-md ./one2.md ) > "$T/c6c2.txt" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(first "$T/c6c2.txt")" = "OK $T/one2.$EXT" ] && [ -s "$T/one2.$EXT" ] && pass from-md-default-output-relative || bad from-md-default-output-relative "rc=$rc $(first "$T/c6c2.txt")"
  s0=$(shasum "$T/회의록_11월.$EXT")
  "$W" from-md "$T/회의록_11월.md" > "$T/c6c3.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR ' "$T/c6c3.txt" && [ "$(shasum "$T/회의록_11월.$EXT")" = "$s0" ] && pass from-md-default-no-clobber || bad from-md-default-no-clobber "rc=$rc $(first "$T/c6c3.txt")"
  "$W" from-md > "$T/c6c4.txt" 2>&1; rc=$?
  "$W" from-md "$md" "$T/three.$EXT" "$T/extra.$EXT" > "$T/c6c5.txt" 2>&1; rc2=$?
  [ $rc -eq 2 ] && grep -q '^ERROR ' "$T/c6c4.txt" && [ $rc2 -eq 2 ] && grep -q '^ERROR ' "$T/c6c5.txt" && [ ! -e "$T/three.$EXT" ] \
    && pass from-md-arg-count || bad from-md-arg-count "rc=$rc/$rc2 $(first "$T/c6c4.txt") / $(first "$T/c6c5.txt")"
  CLAUDE_LMS_PY="$T/no-python" "$W" read "$out" > "$T/c6d.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c6d.txt")" = "1" ] && grep -q '^ERROR ' "$T/c6d.txt" && pass no-python || bad no-python "rc=$rc $(first "$T/c6d.txt")"
  CLAUDE_LMS_PY="$T/no
python" "$W" --help > "$T/c6e.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c6e.txt")" = "1" ] && grep -q '^ERROR ' "$T/c6e.txt" && pass wrapper-error-one-line || bad wrapper-error-one-line "rc=$rc lines=$(lines "$T/c6e.txt")"

  # C7. --help 에 두 명령이 보인다
  "$W" --help > "$T/c7.txt" 2>&1 && grep -q 'from-md' "$T/c7.txt" && grep -q 'read' "$T/c7.txt" && pass help || bad help "$(first "$T/c7.txt")"

  # C8. read 전체본: <파일>.$EXT.md 로만 쓰고, 기존 <stem>.md 와 심볼릭 링크 대상은 건드리지 않는다
  cp "$out" "$T/big.$EXT"; echo "원본 메모" > "$T/big.md"; local s_md; s_md=$(shasum "$T/big.md")
  "$W" read "$T/big.$EXT" --max-chars 5 > "$T/c8.txt" 2>&1; rc=$?
  if [ $rc -eq 0 ] && [ "$(first "$T/c8.txt")" = "OK $T/big.$EXT" ] && [ "$(shasum "$T/big.md")" = "$s_md" ] \
     && grep -qF -- "$1" "$T/big.$EXT.md" 2>/dev/null && grep -qF "$T/big.$EXT.md" "$T/c8.txt"; then pass read-sidecar; else bad read-sidecar "rc=$rc $(head -3 "$T/c8.txt" | tr '\n' ' ')"; fi
  cp "$out" "$T/big2.$EXT"; echo "피해자" > "$T/victim.txt"; local s_v; s_v=$(shasum "$T/victim.txt")
  ln -s "$T/victim.txt" "$T/big2.$EXT.md"
  "$W" read "$T/big2.$EXT" --max-chars 5 > "$T/c8b.txt" 2>&1; rc=$?
  [ $rc -eq 0 ] && grep -q '^OK ' "$T/c8b.txt" && [ "$(shasum "$T/victim.txt")" = "$s_v" ] && [ -L "$T/big2.$EXT.md" ] && pass read-sidecar-no-clobber || bad read-sidecar-no-clobber "rc=$rc $(head -3 "$T/c8b.txt" | tr '\n' ' ')"
  "$W" read "$out" --max-chars 0 > "$T/c8c.txt" 2>&1; rc=$?
  [ $rc -eq 2 ] && grep -q '^ERROR ' "$T/c8c.txt" && pass max-chars-min || bad max-chars-min "rc=$rc $(first "$T/c8c.txt")"

  # C9. 한 줄 규약: 줄바꿈이 든 경로는 정확히 한 줄 ERROR, 파일도 만들지 않는다
  local NL="$T/new
line.$EXT"
  "$W" from-md "$md" "$NL" > "$T/c9.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c9.txt")" = "1" ] && grep -q '^ERROR ' "$T/c9.txt" && [ ! -e "$NL" ] && pass newline-path || bad newline-path "rc=$rc lines=$(lines "$T/c9.txt")"
  "$W" read "$T/no
such.$EXT" > "$T/c9b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c9b.txt")" = "1" ] && grep -q '^ERROR ' "$T/c9b.txt" && pass newline-in-error || bad newline-in-error "rc=$rc lines=$(lines "$T/c9b.txt")"

  # C10. 크기 제한: 파일 50MB 초과, 압축 해제 합계 200MB 초과면 열기 전에 거부
  printf 'PK\003\004' > "$T/huge.$EXT"; dd if=/dev/zero of="$T/huge.$EXT" bs=1 count=0 seek=60m 2>/dev/null
  "$W" read "$T/huge.$EXT" > "$T/c10.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR .*너무 큽니다' "$T/c10.txt" && ! grep -q Traceback "$T/c10.txt" && pass size-limit || bad size-limit "rc=$rc $(first "$T/c10.txt")"
  "$PY" -I - "$out" "$T/bomb.$EXT" <<'EOF'
import shutil, sys, zipfile
shutil.copy(sys.argv[1], sys.argv[2])
with zipfile.ZipFile(sys.argv[2], "a", zipfile.ZIP_DEFLATED) as z, z.open("customXml/pad.bin", "w", force_zip64=True) as f:
    chunk = b"\0" * (1 << 20)
    for _ in range(300):
        f.write(chunk)
EOF
  "$W" read "$T/bomb.$EXT" > "$T/c10b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && grep -q '^ERROR .*너무 큽니다' "$T/c10b.txt" && ! grep -q Traceback "$T/c10b.txt" && pass zip-bomb-limit || bad zip-bomb-limit "rc=$rc $(first "$T/c10b.txt")"

  # C11. 입력 md: UTF-8 아님 / 내용 없음 → 한 줄 ERROR, 출력 없음
  printf '\xff\xfe\x00bad' > "$T/bad.md"
  "$W" from-md "$T/bad.md" "$T/bad.$EXT" > "$T/c11.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c11.txt")" = "1" ] && grep -q '^ERROR ' "$T/c11.txt" && [ ! -e "$T/bad.$EXT" ] && pass input-not-utf8 || bad input-not-utf8 "rc=$rc $(first "$T/c11.txt")"
  printf '\n   \n\n' > "$T/empty.md"
  "$W" from-md "$T/empty.md" "$T/empty.$EXT" > "$T/c11b.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c11b.txt")" = "1" ] && grep -q '^ERROR ' "$T/c11b.txt" && [ ! -e "$T/empty.$EXT" ] && pass input-empty || bad input-empty "rc=$rc $(first "$T/c11b.txt")"

  # C12. 출력 권한은 umask 를 따른다(022 → 644)
  ( umask 022; "$W" from-md "$md" "$T/perm.$EXT" > "$T/c12.txt" 2>&1 )
  [ "$(stat -f %Lp "$T/perm.$EXT" 2>/dev/null)" = "644" ] && pass output-mode-umask || bad output-mode-umask "mode=$(stat -f %Lp "$T/perm.$EXT" 2>/dev/null)"

  # C13. 래퍼: CDPATH 무시, 작업 폴더에 심어 둔 같은 이름 모듈을 import 하지 않음(-I)
  mkdir -p "$T/decoy/skills/$NAME/scripts"
  ( cd "$KIT" && CDPATH="$T/decoy" "skills/$NAME/scripts/$NAME" --help ) > "$T/c13.txt" 2>&1
  grep -q 'from-md' "$T/c13.txt" && pass wrapper-cdpath || bad wrapper-cdpath "$(first "$T/c13.txt")"
  mkdir -p "$T/work"; local mod
  for mod in docx openpyxl pptx lxml zipfile; do echo 'print("PWNED"); raise SystemExit(9)' > "$T/work/$mod.py"; done
  ( cd "$T/work" && "$W" read "$out" ) > "$T/c13b.txt" 2>&1; rc=$?
  [ $rc -eq 0 ] && ! grep -q PWNED "$T/c13b.txt" && pass no-cwd-import || bad no-cwd-import "rc=$rc $(first "$T/c13b.txt")"

  # C14. 입력 md 가 5MB 를 넘으면 읽기 전에 한 줄 ERROR(너무 큽니다), 출력 없음
  "$PY" -I -c 'import sys; open(sys.argv[1], "w").write("# 큰 글\n" + ("가" * 99 + "\n") * 20000)' "$T/bigin.md"
  limited 60 "$W" from-md "$T/bigin.md" "$T/bigin.$EXT" > "$T/c14.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c14.txt")" = "1" ] && grep -q '^ERROR .*너무 큽니다' "$T/c14.txt" && [ ! -e "$T/bigin.$EXT" ] && pass md-size-limit || bad md-size-limit "rc=$rc $(first "$T/c14.txt")"

  # C15. 파이썬에 라이브러리(python-docx/openpyxl/python-pptx)가 없으면 트레이스백 없이 한 줄 ERROR
  printf '#!/bin/sh\nexec "%s" -S "$@"\n' "$PY" > "$T/nosite-python"; chmod 755 "$T/nosite-python"
  CLAUDE_LMS_PY="$T/nosite-python" "$W" read "$out" > "$T/c15.txt" 2>&1; rc=$?
  [ $rc -ne 0 ] && [ "$(lines "$T/c15.txt")" = "1" ] && grep -q '^ERROR ' "$T/c15.txt" && ! grep -q Traceback "$T/c15.txt" && pass library-missing || bad library-missing "rc=$rc lines=$(lines "$T/c15.txt") $(first "$T/c15.txt")"

  # C16. 다른 오피스 파일을 품은 문서(차트의 내장 xlsx, 붙여 넣은 docx·pptx)도 제 형식으로 알아보고 읽는다
  "$PY" -I - "$out" "$T/embeds.$EXT" <<'EOF'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
pkg = "application/vnd.openxmlformats-officedocument."
extra = "".join(f'<Default Extension="{e}" ContentType="{pkg}{t}"/>' for e, t in
                (("xlsx", "spreadsheetml.sheet"), ("docx", "wordprocessingml.document"), ("pptx", "presentationml.presentation")))
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zo:
    for item in zi.infolist():
        data = zi.read(item.filename)
        if item.filename == "[Content_Types].xml":
            s = data.decode("utf-8")
            i = s.index("<Default ")
            data = (s[:i] + extra + s[i:]).encode("utf-8")
        zo.writestr(item, data)
    for e in ("xlsx", "docx", "pptx"):
        zo.writestr(f"embeddings/Embedded1.{e}", b"PK\x05\x06" + b"\0" * 18)
EOF
  "$W" read "$T/embeds.$EXT" > "$T/c16.txt" 2>&1; rc=$?
  [ $rc -eq 0 ] && [ "$(first "$T/c16.txt")" = "OK $T/embeds.$EXT" ] && pass embedded-office-parts || bad embedded-office-parts "rc=$rc $(first "$T/c16.txt")"

  # C17. PDF 에서 붙여 넣은 XML 금지 제어 문자(\x07 \x0b \x1f 등)는 조용히 지우고 만든다(내부 오류 아님)
  printf '# 제\x07목\n\n## 표\n\n본\x0b문\x1f글\n\n| 가\x01 | 나 |\n| --- | --- |\n| 1 | 2\x0c |\n' > "$T/ctrl.md"
  "$W" from-md "$T/ctrl.md" "$T/ctrl.$EXT" > "$T/c17.txt" 2>&1; rc=$?
  "$W" read "$T/ctrl.$EXT" > "$T/c17r.txt" 2>&1
  [ $rc -eq 0 ] && [ "$(first "$T/c17.txt")" = "OK $T/ctrl.$EXT" ] && ! LC_ALL=C grep -q $'[\x01\x07\x0b\x0c\x1f]' "$T/c17r.txt" && pass control-chars-dropped || bad control-chars-dropped "rc=$rc $(first "$T/c17.txt")"

  # C18. 압축이 깨진 zip 항목: 내부 오류가 아닌 한 줄 ERROR
  "$PY" -I - "$out" "$T/corrupt.$EXT" <<'EOF'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zo:
    for item in zi.infolist():
        zo.writestr(item.filename, zi.read(item.filename), zipfile.ZIP_DEFLATED)
buf = bytearray(open(dst, "rb").read())
with zipfile.ZipFile(dst) as z:
    for name in ("[Content_Types].xml", "_rels/.rels"):
        info = z.getinfo(name)
        off = info.header_offset
        n, m = int.from_bytes(buf[off + 26:off + 28], "little"), int.from_bytes(buf[off + 28:off + 30], "little")
        start = off + 30 + n + m
        buf[start:start + 4] = b"\xff\xff\xff\xff"   # deflate 블록 종류 11(예약) -> zlib.error
open(dst, "wb").write(bytes(buf))
EOF
  "$W" read "$T/corrupt.$EXT" > "$T/c18.txt" 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(lines "$T/c18.txt")" = "1" ] && grep -q '^ERROR ' "$T/c18.txt" && ! grep -q '내부 오류' "$T/c18.txt" && pass corrupt-zip-entry || bad corrupt-zip-entry "rc=$rc $(first "$T/c18.txt")"

  # C19. 읽을 권한이 없는 입력(md, 문서): 내부 오류가 아닌 한 줄 ERROR
  cp "$md" "$T/noperm.md"; chmod 000 "$T/noperm.md"
  "$W" from-md "$T/noperm.md" "$T/noperm.$EXT" > "$T/c19.txt" 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(lines "$T/c19.txt")" = "1" ] && grep -q '^ERROR ' "$T/c19.txt" && ! grep -q '내부 오류' "$T/c19.txt" && [ ! -e "$T/noperm.$EXT" ] && pass unreadable-md || bad unreadable-md "rc=$rc $(first "$T/c19.txt")"
  cp "$out" "$T/noperm.$EXT"; chmod 000 "$T/noperm.$EXT"
  "$W" read "$T/noperm.$EXT" > "$T/c19b.txt" 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(lines "$T/c19b.txt")" = "1" ] && grep -q '^ERROR ' "$T/c19b.txt" && ! grep -q '내부 오류' "$T/c19b.txt" && pass unreadable-doc || bad unreadable-doc "rc=$rc $(first "$T/c19b.txt")"
  chmod 600 "$T/noperm.md" "$T/noperm.$EXT"

  # C20. 넓은 머리 행 + 칸 하나짜리 행이 많은 표: 칸을 채운(패딩) 뒤의 칸 수(행 수 × 열 수)로 한계를 본다.
  #      적은 입력이 수억 칸으로 불어나 메모리를 다 쓰기 전에 한 줄 ERROR, 출력 없음(빨리 끝남)
  case "$EXT" in docx) pc=63; pr=1600 ;; pptx) pc=75; pr=1334 ;; xlsx) pc=16384; pr=61 ;; esac
  padded_table_md "$T/padded.md" "$pc" "$pr"
  limited 30 "$W" from-md "$T/padded.md" "$T/padded.$EXT" > "$T/c20.txt" 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(lines "$T/c20.txt")" = "1" ] && grep -q '^ERROR ' "$T/c20.txt" && [ ! -e "$T/padded.$EXT" ] && pass table-too-big-padded || bad table-too-big-padded "rc=$rc $(first "$T/c20.txt")"
  padded_table_md "$T/padbomb.md" "$pc" 3000
  limited 30 "$W" from-md "$T/padbomb.md" "$T/padbomb.$EXT" > "$T/c20b.txt" 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(lines "$T/c20b.txt")" = "1" ] && grep -q '^ERROR ' "$T/c20b.txt" && [ ! -e "$T/padbomb.$EXT" ] && pass table-pad-bomb || bad table-pad-bomb "rc=$rc $(first "$T/c20b.txt")"

  # C21. `_rels/.rels` 가 작은따옴표 속성·접두어 붙은 요소(<pr:Relationship …>)로 쓰여도 (라이브러리는 연다) 형식을 알아보고 읽는다
  "$PY" -I - "$out" "$T/prefixed.$EXT" <<'EOF'
import sys, zipfile, xml.etree.ElementTree as ET
src, dst = sys.argv[1], sys.argv[2]
NS = "http://schemas.openxmlformats.org/package/2006/relationships"
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zo:
    for item in zi.infolist():
        data = zi.read(item.filename)
        if item.filename == "_rels/.rels":
            rels = ET.fromstring(data)
            parts = "".join(f"<pr:Relationship Id='{r.get('Id')}' Type='{r.get('Type')}' Target='{r.get('Target')}'/>" for r in rels)
            data = (f"<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\n<pr:Relationships xmlns:pr='{NS}'>{parts}</pr:Relationships>").encode()
        zo.writestr(item, data)
EOF
  "$W" read "$T/prefixed.$EXT" > "$T/c21.txt" 2>&1; rc=$?
  [ $rc -eq 0 ] && grep -q '^OK ' "$T/c21.txt" && pass rels-prefixed-single-quote || bad rels-prefixed-single-quote "rc=$rc $(first "$T/c21.txt")"

  # C22. `_rels/.rels` 의 XML 선언 encoding 이 알 수 없는 값이면 내부 오류가 아니라 한 줄 ERROR 안내
  "$PY" -I - "$out" "$T/badenc.$EXT" <<'EOF'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zo:
    for item in zi.infolist():
        data = zi.read(item.filename)
        if item.filename == "_rels/.rels":
            data = b'<?xml version="1.0" encoding="bogus"?><Relationships/>'
        zo.writestr(item, data)
EOF
  "$W" read "$T/badenc.$EXT" > "$T/c22.txt" 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(lines "$T/c22.txt")" = "1" ] && grep -q '^ERROR ' "$T/c22.txt" && ! grep -q '내부 오류' "$T/c22.txt" \
    && pass rels-bad-encoding || bad rels-bad-encoding "rc=$rc $(first "$T/c22.txt")"
}

# limited <초> <명령>...: 그 시간 안에 끝나지 않으면 SIGALRM 으로 끊는다(rc 142). 메모리 폭주·무한 대기 시험용.
limited() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }

# wide_table_md <파일> <열 수> <행 수>: 머리 2칸 + 데이터 행들(각 <열 수> 칸)인 표 하나
wide_table_md() {
  "$PY" -I -c 'import sys
p, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(p, "w") as f:
    f.write("# 큰 표\n\n## 표\n\n| 가 | 나 |\n| --- | --- |\n")
    for _ in range(rows): f.write("|" + "1|" * cols + "\n")' "$@"
}

# padded_table_md <파일> <머리 열 수> <행 수>: 머리 행만 <열 수> 칸이고 데이터 행은 모두 칸 하나인 표 하나
# (입력 칸 수는 작아도 열 수를 맞춰 채우면 행 수 × 열 수 칸이 된다)
padded_table_md() {
  "$PY" -I -c 'import sys
p, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(p, "w") as f:
    f.write("# 큰 표\n\n## 표\n\n|" + "가|" * cols + "\n|" + "---|" * cols + "\n")
    f.write("| 1 |\n" * rows)' "$@"
}
