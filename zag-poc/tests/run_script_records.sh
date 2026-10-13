#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-record.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/script_record_test.zag -o "$tmp/parser" --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; exit 1; }
cat >"$tmp/valid.zag" <<'ZAG'
struct Pair { left: i64, right: bool }
struct Status { error: i32 }
fn main() i32 {
    let status=Status{.error=0};
    if(status.error!=0){return 2;}
    let bytes=(null as *u8)[0..0];
    if(bytes.len!=0){return 3;}
    let left: i64 = 42;
    let value = Pair{left, right: true};
    if(value.left != 42 || !value.right){return 1;}
    return 0;
}
ZAG
"$tmp/parser" "$tmp/valid.zag" >"$tmp/explicit.zag"
"$compiler" "$tmp/explicit.zag" -o "$tmp/run" --no-zagd --no-analyze --no-foreground-cache >"$tmp/native.log" 2>&1 || { cat "$tmp/native.log"; exit 1; }
"$tmp/run"
for fields in 'left: 1' 'left: 1, right: true, extra: 2' 'left: "wrong", right: true' 'left: 1, left: 2, right: true' 'left: 1 right: true'; do
    printf 'struct Pair { left: i64, right: bool }\nfn main() i32 { let x = Pair{%s}; return 0; }\n' "$fields" >"$tmp/bad.zag"
    if "$tmp/parser" "$tmp/bad.zag" >"$tmp/out" 2>"$tmp/err"; then echo "invalid record accepted: $fields"; exit 1; fi
    if ! test -s "$tmp/err" && ! test -s "$tmp/out"; then echo 'missing record diagnostic'; exit 1; fi
done
echo 'script records: PASS (native projection and five rejection cases)'
