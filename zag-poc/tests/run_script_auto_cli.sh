#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-auto-cli.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf 'x 0 +\n' >"$tmp/reference"
"$compiler" auto "$tmp/reference" --bits 4 --variables 1 >"$tmp/generated.zag"
"$compiler" auto "$tmp/reference" --bits 4 --variables 1 --record >"$tmp/record"
"$compiler" auto "$tmp/reference" --bits 4 --variables 1 --record >"$tmp/repeat"
cmp "$tmp/record" "$tmp/repeat"
"$compiler" auto "$tmp/reference" --bits 4 --variables 1 --verify "$tmp/record"
cat >>"$tmp/generated.zag" <<'ZAG'
fn main() i32 {
    let x:i64=0;
    while(x<16){if(script_auto_selected(x)!=x){return 1;}x=x+1;}
    if(script_auto_selected(16)!=-1){return 2;}
    return 0;
}
ZAG
"$compiler" "$tmp/generated.zag" -o "$tmp/run" --no-zagd --no-analyze --no-foreground-cache >"$tmp/compile.log" 2>&1 || { cat "$tmp/compile.log"; exit 1; }
"$tmp/run"
printf 'tampered\n' >>"$tmp/record"
if "$compiler" auto "$tmp/reference" --bits 4 --variables 1 --verify "$tmp/record" >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'verification failed' "$tmp/err"
printf 'x 0 /\n' >"$tmp/reference"
if "$compiler" auto "$tmp/reference" --bits 4 --variables 1 >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
test ! -s "$tmp/out"
echo 'script auto CLI: PASS'
