#!/usr/bin/env bash
# Float literals across the full double range (normal, subnormal, overflow,
# >18 leading fractional zeros) must compile and encode bit-exactly.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
if [ ! -x "$ZNC" ]; then echo "float-literal-range: missing compiler: $ZNC" >&2; exit 2; fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-floatlit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf 'name = "floatlit"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
cp tests/float_literal_range.zag "$tmp/main.zag"
(cd "$tmp" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/build.log" 2>&1 || { sed -n '1,20p' "$tmp/build.log" >&2; echo "XX float-literal-range: compile failed" >&2; exit 1; }
"$tmp/out" || { echo "XX float-literal-range: runtime check failed" >&2; exit 1; }
echo "float-literal-range: ok"
