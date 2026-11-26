#!/bin/bash
# export-public.sh acceptance test (build Mac only; a human runs it). Builds a tiny git repo
# holding the exporter plus link shapes into excluded paths — a table first cell, a sentence
# link, a wiki note outside KEEP_CONCEPTS, a docs/internal sentence link — and a kept link.
# Also checks the public-only host rename (spark.local → spark.local). A reference-style
# definition ([r]: archive/z.md) is present on purpose: the rewrite need not handle it, the
# run must only not fail. A second repo holds an image link into an excluded path: that
# export must fail (the re-check catches what the rewrite skips). All content is synthetic.
# Usage:
#   accept_export_public.sh
set -u
SECONDS=0
G="$(cd "$(dirname "$0")/../.." && pwd)"      # export-public.sh 는 guardian/ 이 아니라 저장소 루트에 있다
EP="$G/export-public.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-export-public.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "${T:?}"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
has()  { local f="$1" s="$2"; grep -Fq -e "$s" "$f"; }
hasnt(){ local f="$1" s="$2"; ! grep -Fq -e "$s" "$f"; }

[ -f "$EP" ] || { echo "FAIL export-public.sh missing"; exit 1; }

# ---- 작은 저장소: 제외 경로(docs/training, docs/internal, archive, KEEP_CONCEPTS 밖 wiki 노트)를
# ---- 가리키는 링크 + 공개본 전용 호스트명(spark) --------------------------------------
R="$T/repo"
mkdir -p "$R/docs/training" "$R/docs/internal" "$R/archive" "$R/wiki/concepts"
printf '# ok doc\n' >"$R/docs/ok.md"
printf 'internal deck\n' >"$R/docs/training/x.md"
printf 'internal only\n' >"$R/docs/internal/secret.md"
printf 'archived y\n' >"$R/archive/y.md"
printf 'archived z\n' >"$R/archive/z.md"
printf 'deploy host: spark.local\nbare host: spark\n' >"$R/HOSTS.md"
printf 'other note\n' >"$R/wiki/concepts/other.md"
printf '# welcome\n\n- kept sibling: [sample](sample-concept.md)\n- other note: [other](other.md)\n' \
    >"$R/wiki/concepts/welcome.md"
printf '# sample\n' >"$R/wiki/concepts/sample-concept.md"
printf '# another\n' >"$R/wiki/concepts/another-concept.md"
cat >"$R/README.md" <<'EOF'
# Tiny repo

| Doc | Note |
| --- | --- |
| [`docs/training/x.md`](docs/training/x.md) | **Training**: internal deck |
| [`docs/ok.md`](docs/ok.md) | **Kept**: this row stays |

Sentence link to [the archive note](archive/y.md) plus a kept [usage](docs/ok.md) link.

Internal design map: [settings map](docs/internal/secret.md) stays unlinked.

[r]: archive/z.md
EOF
cp "$EP" "$R/export-public.sh"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --no-gpg-sign -m seed

# ---- 1. export 실행: 끝까지 성공 -----------------------------------------------------------
D="$T/pub"
bash "$R/export-public.sh" "$D" >"$T/out" 2>"$T/err"
rc=$?
[ "$rc" = 0 ] && pass "1 export exits 0" || bad "1 export exits 0" "rc=$rc $(tail -3 "$T/err")"
has "$T/out" "완료" && pass "1 export finishes (완료)" || bad "1 export finishes (완료)" "$(tail -2 "$T/out")"
[ -f "$D/docs/ok.md" ] && pass "1 kept file extracted" || bad "1 kept file extracted" "missing"
[ ! -e "$D/docs/training" ] && pass "1 excluded dir not extracted" || bad "1 excluded dir not extracted" "exists"

# ---- 2. 표 행: 첫 칸의 링크가 제외 경로를 가리키면 행이 지워지고 다른 행은 남는다 -------------
hasnt "$D/README.md" "docs/training" && pass "2 training row dropped" \
    || bad "2 training row dropped" "$(grep -n training "$D/README.md")"
hasnt "$D/README.md" "internal deck" && pass "2 row text dropped with the row" \
    || bad "2 row text dropped with the row" "kept"
has "$D/README.md" '| [`docs/ok.md`](docs/ok.md) | **Kept**: this row stays |' \
    && pass "2 other row intact" || bad "2 other row intact" "$(grep -n 'ok.md' "$D/README.md")"
has "$D/README.md" '| --- | --- |' && pass "2 table header intact" \
    || bad "2 table header intact" "missing"

# ---- 3. 문장 안 링크: 링크는 풀리고 본문은 남는다 ------------------------------------------
has "$D/README.md" "the archive note" && pass "3 sentence text kept" \
    || bad "3 sentence text kept" "missing"
hasnt "$D/README.md" "](archive/" && pass "3 archive link unlinked" \
    || bad "3 archive link unlinked" "$(grep -n 'archive' "$D/README.md")"
has "$D/README.md" "[usage](docs/ok.md)" && pass "3 kept sentence link intact" \
    || bad "3 kept sentence link intact" "$(grep -n 'usage' "$D/README.md")"

# ---- 4. wiki 노트: KEEP_CONCEPTS 밖을 가리키는 링크만 풀린다 --------------------------------
has "$D/wiki/concepts/welcome.md" "[sample](sample-concept.md)" && pass "4 kept-concept link intact" \
    || bad "4 kept-concept link intact" "$(grep -n sample "$D/wiki/concepts/welcome.md")"
hasnt "$D/wiki/concepts/welcome.md" "](other.md)" && pass "4 non-kept concept link unlinked" \
    || bad "4 non-kept concept link unlinked" "$(grep -n other "$D/wiki/concepts/welcome.md")"

# ---- 5. 참조식 정의([r]: archive/z.md)는 다루지 않는다 — 실행만 깨지지 않으면 된다 ----------
has "$D/README.md" "[r]: archive/z.md" && pass "5 reference definition left alone" \
    || bad "5 reference definition left alone" "changed or missing"
[ -s "$T/err" ] && bad "5 nothing on stderr" "$(cat "$T/err")" || pass "5 nothing on stderr"

# ---- 6. docs/internal: 폴더째 제외되고 남은 문서의 링크는 풀린다 ----------------------------
[ ! -e "$D/docs/internal" ] && pass "6 docs/internal not extracted" \
    || bad "6 docs/internal not extracted" "exists"
hasnt "$D/README.md" "](docs/internal/" && pass "6 internal link unlinked" \
    || bad "6 internal link unlinked" "$(grep -n 'docs/internal' "$D/README.md")"
has "$D/README.md" "settings map" && pass "6 internal link text kept" \
    || bad "6 internal link text kept" "missing"

# ---- 7. 공개본 전용 호스트명 치환: spark.local → spark.local (export 는 계속 성공) ------
has "$D/HOSTS.md" "deploy host: spark.local" && pass "7 spark.local renamed to spark.local" \
    || bad "7 spark.local renamed to spark.local" "$(cat "$D/HOSTS.md")"
has "$D/HOSTS.md" "bare host: spark" && pass "7 bare spark renamed to spark" \
    || bad "7 bare spark renamed to spark" "$(cat "$D/HOSTS.md")"
hasnt "$D/HOSTS.md" "spark" && pass "7 no spark left (export stayed green)" \
    || bad "7 no spark left (export stayed green)" "$(grep -n spark "$D/HOSTS.md")"

# ---- 8. 이미지 링크가 제외 경로를 가리키면 재검사에서 실패한다 (정리 단계는 건드리지 않음) ----
R2="$T/repo2"
mkdir -p "$R2/archive" "$R2/wiki/concepts"
printf 'archived y\n' >"$R2/archive/y.md"
printf '# welcome\n' >"$R2/wiki/concepts/welcome.md"
printf '# sample\n' >"$R2/wiki/concepts/sample-concept.md"
printf '# another\n' >"$R2/wiki/concepts/another-concept.md"
cat >"$R2/README.md" <<'EOF'
# img doc

![logo](archive/y.png)

Text link to the same path: [doc](archive/y.md) — this one gets unlinked, not fatal.
EOF
cp "$EP" "$R2/export-public.sh"
git -C "$R2" init -q
git -C "$R2" add -A
git -C "$R2" -c user.name=t -c user.email=t@example.com commit -q --no-gpg-sign -m seed
D2="$T/pub2"
bash "$R2/export-public.sh" "$D2" >"$T/out2" 2>"$T/err2"
rc=$?
[ "$rc" != 0 ] && pass "8 image link into excluded path fails export" \
    || bad "8 image link into excluded path fails export" "rc=0 (export succeeded)"
has "$T/err2" "link into excluded path" && pass "8 failure names an excluded-path link" \
    || bad "8 failure names an excluded-path link" "$(tail -3 "$T/err2")"
has "$T/err2" "archive/y.png" && pass "8 failure names the image target" \
    || bad "8 failure names the image target" "$(tail -3 "$T/err2")"
has "$D2/README.md" "![logo](archive/y.png)" && pass "8 image link itself left in place" \
    || bad "8 image link itself left in place" "rewritten"

echo
echo "elapsed: ${SECONDS}s"
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
