#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/portable.sh"
compiler=${ZNC:-$(zag_native_compiler "$root")}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-auto-lower.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" "$root/tests/script_auto_lower.zag" -o "$tmp/lower" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || {
    cat "$tmp/build.log" >&2; exit 1;
}
"$tmp/lower"
cat >"$tmp/source.zag" <<'ZAG'
fn input(counter:*i64,value:i64)i64{counter.*=counter.*+1;return value;}
fn main()i32 {
    let y:i64=0;
    while(y<16){let x:i64=0;while(x<16){
        let n:i64=script_auto_u4("x 0 + y 0 + *",x,y);
        if(n!=(x*y)%16){return 1;}
        if(__zag_auto_u4("x y -",x,y)!=(x+16-y)%16){return 2;}
        x=x+1;
    }y=y+1;}
    let count:i64=0;
    if(script_auto_u4("x y +",input(&count,3),input(&count,5))!=8||count!=2){return 3;}
    if(__zag_auto_u4("x y +", __zag_auto_u4("x x *",3), __zag_auto_u4("15 1 +"))!=9){return 4;}
    if(__zag_auto_u4("x",-1)!=-1||__zag_auto_u4("x",16)!=-1){return 5;}
    if(__zag_auto_u4("x y +",0,16)!=-1||__zag_auto_u4("x y +",0,-1)!=-1){return 6;}
    return 0;
}
ZAG
"$tmp/lower" --lower "$tmp/source.zag" >"$tmp/ordinary.zag"
"$tmp/lower" --lower "$tmp/source.zag" >"$tmp/repeat.zag"
cmp "$tmp/ordinary.zag" "$tmp/repeat.zag"
"$compiler" "$tmp/ordinary.zag" -o "$tmp/ordinary" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/native.log" 2>&1 || {
    cat "$tmp/ordinary.zag" "$tmp/native.log" >&2; exit 1;
}
"$tmp/ordinary"
# Evidence-bearing explicit artifacts remain ordinary compilable Zag.
"$tmp/lower" --artifact "$tmp/source.zag" >"$tmp/artifact.zag"
"$tmp/lower" --artifact "$tmp/source.zag" >"$tmp/artifact-repeat.zag"
cmp "$tmp/artifact.zag" "$tmp/artifact-repeat.zag"
grep -q '^// auto-record: checker=exhaustive-unsigned-modular-v1' "$tmp/artifact.zag"
grep -q '^// auto-record: optimum=finite-candidate-cost-only' "$tmp/artifact.zag"
"$compiler" "$tmp/artifact.zag" -o "$tmp/artifact" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/artifact.log" 2>&1 || {
    cat "$tmp/artifact.log" >&2; exit 1;
}
"$tmp/artifact"
# Verify every record's symbol resolves to a generated function and that
# removing those dependencies is rejected by the ordinary compiler.
python3 - "$tmp/artifact.zag" "$tmp/missing.zag" <<'PYDEPEND'
import re,sys
source=open(sys.argv[1]).read()
symbols=re.findall(r'^// auto-symbol: (\w+)$',source,re.M)
assert symbols and len(symbols)==len(set(symbols))
for symbol in symbols:
    assert re.search(r'fn '+re.escape(symbol)+r'\(',source)
plain='\n'.join(line for line in source.splitlines() if not line.startswith('// auto-'))
for symbol in symbols:
    match=re.search(r'fn '+re.escape(symbol)+r'\([^)]*\)[^{]*\{',plain)
    assert match
    depth=1;end=match.end()
    while depth:
        if plain[end]=='{':depth+=1
        if plain[end]=='}':depth-=1
        end+=1
    plain=plain[:match.start()]+plain[end:]
open(sys.argv[2],'w').write(plain)
PYDEPEND
if "$compiler" "$tmp/missing.zag" -o "$tmp/missing" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/missing.log" 2>&1; then
    echo 'auto artifact with missing generated dependencies unexpectedly compiled' >&2; exit 1
fi
grep -q '__zag_auto_u4_generated_' "$tmp/missing.log"
test ! -e "$tmp/missing"
echo 'script auto lower: PASS (28 unit checks, aggregate budget, deterministic evidence artifact, native execution, required generated dependencies)'
