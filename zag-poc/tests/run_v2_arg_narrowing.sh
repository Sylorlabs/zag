#!/usr/bin/env bash
# Edition 2027 rejects implicit integer narrowing at call boundaries (i64 value
# -> i32 parameter, or an out-of-range literal); explicit casts, fitting
# literals and widening still compile and run. Edition 2026 keeps the old
# wrapping behavior (compiles).
set -u
cd "$(dirname "$0")/.."
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-arg-narrow.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
build() { # $1 file $2 edition -> sets d; returns compile status
    d="$WORK/$(basename "$1" .zag)-$2"; mkdir -p "$d"
    printf 'name = "argn"\nversion = "0"\nedition = "%s"\n' "$2" >"$d/zag.mod"
    cp "tests/arg_narrowing/$1" "$d/main.zag"
    (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1
}
for f in narrow_var.zag narrow_lit.zag; do
    if build "$f" 2027; then bad "2027 $f compiled (want narrowing error); run rc=$(cd "$d" && ./out; echo $?)"
    elif grep -q "narrowing\|does not fit parameter" "$d/log"; then ok "2027 $f rejected with narrowing diagnostic"
    else bad "2027 $f failed for another reason"; sed -n '1,5p' "$d/log"; fi
done
if build narrow_ok.zag 2027; then
    (cd "$d" && ./out); rc=$?
    if [ "$rc" -eq 0 ]; then ok "2027 explicit casts / fitting literals / widening"; else bad "2027 narrow_ok rc=$rc"; fi
else bad "2027 narrow_ok compile"; sed -n '1,5p' "$d/log"; fi
if build narrow_var.zag 2026; then ok "2026 keeps legacy behavior (compiles)"; else bad "2026 narrow_var compile"; sed -n '1,5p' "$d/log"; fi
echo "v2 arg narrowing: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
