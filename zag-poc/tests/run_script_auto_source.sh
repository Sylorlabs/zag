#!/usr/bin/env bash
# Requires a final integrated compiler with Script configure auto lowering.
# Does not build/bootstrap that compiler. ZNC selects the parent-built artifact.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/portable.sh"
compiler=${ZNC:-$(zag_native_compiler "$root")}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-auto-source.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/source.zs" <<'ZAG'
script;
let y:i64=0;
while(y<16){let x:i64=0;while(x<16){
    let actual:i64=script_auto_u4("x 0 + y 0 + *",x,y);
    if(actual!=(x*y)%16){return 1;}
    x=x+1;
}y=y+1;}
if(__zag_auto_u4("x y +",__zag_auto_u4("x x *",3),__zag_auto_u4("15 1 +"))!=9){return 2;}
if(script_auto_u4("x",16)!=-1){return 3;}
return 0;
ZAG
cp "$tmp/source.zs" "$tmp/original.zs"
"$compiler" "$tmp/source.zs" -o "$tmp/native" --auto-evidence --no-zagd --no-analyze --no-foreground-cache 2>"$tmp/evidence.log"
grep -q '^auto symbol=__zag_auto_u4_generated_' "$tmp/evidence.log"
grep -q '^checker=exhaustive-unsigned-modular-v1$' "$tmp/evidence.log"
grep -q '^optimum=finite-candidate-cost-only$' "$tmp/evidence.log"
"$tmp/native"
"$compiler" expand "$tmp/source.zs" --to explicit --output "$tmp/explicit.zag" --no-zagd >"$tmp/expand.log"
grep -Eq 'fn __zag_auto_u4_generated_[0-9]+\(' "$tmp/explicit.zag"
if grep -Eq '(^|[^A-Za-z_])(__zag_auto_u4|script_auto_u4)\(' "$tmp/explicit.zag"; then
    echo 'explicit artifact retains unlowered auto call' >&2; exit 1
fi
"$compiler" "$tmp/explicit.zag" -o "$tmp/explicit" --no-zagd --no-analyze --no-foreground-cache
"$tmp/explicit"
"$compiler" harden "$tmp/source.zs" --output "$tmp/hardened.zag" --no-zagd >"$tmp/harden.log"
grep -Eq 'fn __zag_auto_u4_generated_[0-9]+\(' "$tmp/hardened.zag"
"$compiler" "$tmp/hardened.zag" -o "$tmp/hardened" --no-zagd --no-analyze --no-foreground-cache
"$tmp/hardened"
# No false exact-provenance promotion, publication, or test-command execution.
if "$compiler" promote "$tmp/source.zs" --to explicit --output "$tmp/promoted.zag" \
    --test-command "touch '$tmp/promotion-test-ran'" --no-zagd --no-analyze --no-foreground-cache >"$tmp/promote.log" 2>&1; then
    echo 'auto provenance unexpectedly promoted' >&2; exit 1
fi
grep -q 'auto-generated declaration provenance is not yet supported' "$tmp/promote.log"
test ! -e "$tmp/promoted.zag"
test ! -e "$tmp/promoted.zag.zsledger"
test ! -e "$tmp/promotion-test-ran"
cmp "$tmp/source.zs" "$tmp/original.zs"
cat >"$tmp/reject.zs" <<'ZAG'
script;
let reference:[]u8="x";
let value:i64=script_auto_u4(reference,1);
return 0;
ZAG
if "$compiler" "$tmp/reject.zs" -o "$tmp/reject" --no-zagd --no-analyze --no-foreground-cache >"$tmp/reject.log" 2>&1; then
    echo 'computed reference unexpectedly compiled' >&2; exit 1
fi
grep -q 'E_AUTO_U4' "$tmp/reject.log"
test ! -e "$tmp/reject"
echo 'script auto source: PASS (native root/evidence, expand, harden dependencies, promotion refusal, immutable source, computed-reference rejection)'
