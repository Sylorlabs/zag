#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/portable.sh"
compiler=${ZNC:-$(zag_native_compiler "$root")}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-auto.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" "$root/tests/script_auto.zag" -o "$tmp/unit" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || {
    cat "$tmp/build.log" >&2; exit 1;
}
"$tmp/unit"
"$tmp/unit" --record 'x 0 + y 0 + *' >"$tmp/record1"
"$tmp/unit" --record 'x 0 + y 0 + *' >"$tmp/record2"
cmp "$tmp/record1" "$tmp/record2"
# Independently compile generated ordinary Zag and compare every input against
# Python's separately implemented modular arithmetic, not the engine evaluator.
for expr in 'x 0 + y 0 + *' 'x y -' 'x y &' 'x y |' 'x y ^' '15 1 +' 'x x * y +'; do
    "$tmp/unit" --emit "$expr" >"$tmp/generated.zag"
    cat >>"$tmp/generated.zag" <<'ZAG'
fn main() i32 {
    let y:i64=0;
    while(y<16){let x:i64=0;while(x<16){_zag_println(script_auto_selected(x,y));x=x+1;}y=y+1;}
    if(script_auto_selected(-1,0)!=-1||script_auto_selected(16,0)!=-1||script_auto_selected(0,-1)!=-1||script_auto_selected(0,16)!=-1){return 1;}
    return 0;
}
ZAG
    "$compiler" "$tmp/generated.zag" -o "$tmp/generated" \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/generated.log" 2>&1 || {
        cat "$tmp/generated.zag" "$tmp/generated.log" >&2; exit 1;
    }
    "$tmp/generated" >"$tmp/actual"
    "$tmp/unit" --record "$expr" >"$tmp/selection"
    python3 - "$expr" "$tmp/actual" "$tmp/selection" <<'PY'
import sys
expression, path, record_path = sys.argv[1:]
ops={'+':lambda a,b:a+b,'-':lambda a,b:a-b,'*':lambda a,b:a*b,
     '&':lambda a,b:a&b,'|':lambda a,b:a|b,'^':lambda a,b:a^b}
expected=[]
for y in range(16):
    for x in range(16):
        stack=[]
        for token in expression.split():
            if token in ops:
                b,a=stack.pop(),stack.pop()
                stack.append(ops[token](a,b)%16)
            else:
                stack.append({'x':x,'y':y}[token] if token in ('x','y') else int(token))
        assert len(stack)==1
        expected.append(stack[0])
actual=[int(line) for line in open(path)]
assert actual==expected, (expression, next(((i,a,b) for i,(a,b) in enumerate(zip(actual,expected)) if a!=b), 'length mismatch'))
# Reconstruct every grammar candidate independently, exhaust its truth table,
# and minimize (node count, enumeration index). This also detects incomplete
# enumeration or incorrect deterministic tie selection in the native engine.
leaves=[tuple([n]*256) for n in range(16)]
leaves += [tuple(x for y in range(16) for x in range(16)),
           tuple(y for y in range(16) for x in range(16))]
best=(len(expression.split()),0)
index=1
for leaf in leaves:
    if list(leaf)==expected: best=min(best,(1,index))
    index+=1
for operation in ops.values():
    for left in leaves:
        for right in leaves:
            if all(operation(a,b)%16==v for a,b,v in zip(left,right,expected)):
                best=min(best,(3,index))
            index+=1
# Parse length-framed strings rather than assuming embedded newlines are fields.
data=open(record_path,'rb').read()
framed={b'reference',b'source',b'compiler',b'target',b'generated'}
fields={}
while data:
    line,_,rest=data.partition(b'\n')
    key,sep,value=line.partition(b'=')
    if sep and key in framed:
        prefix,_,payload=data.partition(b':')
        length=int(prefix.split(b'=',1)[1])
        fields[key]=payload[:length]
        assert payload[length:length+1]==b'\n'
        data=payload[length+1:]
    else:
        if sep: fields[key]=value
        data=rest
assert (int(fields[b'cost']),int(fields[b'selected']))==best
assert int(fields[b'candidates'])==index==1963
assert fields[b'reference'].decode()==expression
assert fields[b'optimum']==b'finite-candidate-cost-only'
print(f'ok  native output + independent finite cost optimum: {expression} (256 assignments, 1963 candidates)')
PY
done
echo 'script auto: PASS (unit, deterministic record, 7 native exhaustive oracle cases)'
