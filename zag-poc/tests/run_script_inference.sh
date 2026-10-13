#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-script-inference.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/script_inference_test.zag -o "$tmp/normalizer" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || {
    cat "$tmp/build.log" >&2; exit 1;
}
"$tmp/normalizer"
cat >"$tmp/runtime.zs" <<'ZAG'
script;
def first(x):
    return later(x)
def later(value):
    return value
def flag(x):
    return not x
def doubled(x):
    result=x*2
    return result
def recursive(x):
    if x==0:
        return True
    else:
        return recursive(x-1)
def narrow(x:i32)->i32:
    return x+1
def second_local(x):
    result=x+2
    return result
def mutate(x):
    x += 1
    return x
def optional(x:i64)->?i64:
    return x
def fallible(x:i64)->!i64:
    return x
def empty():
    pass
text=first("hello")
if not @strEq(text,"hello"):
    return 1
if flag(False)!=True:
    return 2
if doubled(21)!=42:
    return 3
if recursive(3)!=True:
    return 4
if narrow(6)!=7:
    return 5
if second_local(8)!=10:
    return 6
if mutate(9)!=10:
    return 7
empty()
return 0
ZAG
"$tmp/normalizer" "$tmp/runtime.zs" >"$tmp/runtime.zag"
"$compiler" "$tmp/runtime.zag" -o "$tmp/runtime" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/runtime.log" 2>&1 || {
    cat "$tmp/runtime.zag" "$tmp/runtime.log" >&2; exit 1;
}
"$tmp/runtime"
negative() {
    local name=$1 diagnostic=$2
    cat >"$tmp/$name.zs"
    if "$tmp/normalizer" "$tmp/$name.zs" >"$tmp/$name.log" 2>&1; then
        echo "unexpected inference success: $name" >&2; exit 1
    fi
    if ! grep -q "$diagnostic" "$tmp/$name.log"; then
        cat "$tmp/$name.log" >&2; exit 1
    fi
}
negative unused 'ambiguous type' <<'ZAG'
script;
def unused(x):
    return 1
ZAG
negative identity 'ambiguous type' <<'ZAG'
script;
def identity(x):
    return x
ZAG
negative conflict 'conflicting types' <<'ZAG'
script;
def identity(x):
    return x
a=identity(True)
b=identity("no")
ZAG
negative returns 'conflicting types' <<'ZAG'
script;
def mixed(x):
    if x:
        return 1
    else:
        return "no"
ZAG
negative recursion 'ambiguous type' <<'ZAG'
script;
def first():
    return second()
def second():
    return first()
ZAG
negative fallthrough 'not all paths return' <<'ZAG'
script;
def partial(x):
    if x:
        return 1
ZAG
negative bare 'conflicting types' <<'ZAG'
script;
def partial(x):
    if x:
        return 1
    return
ZAG
negative annotation 'conflicting types' <<'ZAG'
script;
def wrong(x:bool)->bool:
    return x
value=wrong("wrong")
ZAG
negative arity 'argument' <<'ZAG'
script;
def identity(x):
    return x
value=identity(1,2)
ZAG
negative nested 'nested def' <<'ZAG'
script;
def outer(x):
    def inner(y):
        return y
    return inner(x)
ZAG
negative unknown_call 'ambiguous type' <<'ZAG'
script;
def unresolved():
    return external()
ZAG
negative width 'conflicting types' <<'ZAG'
script;
def narrow(x:i32)->i32:
    return x
def wide(x:i64)->i64:
    return narrow(x)
ZAG
negative explicit_unused 'ambiguous type' <<'ZAG'
script;
def unused(x)->bool:
    return True
ZAG
negative bad_math 'conflicting types' <<'ZAG'
script;
def bad(x):
    return x+True
ZAG
negative null_return 'ambiguous type' <<'ZAG'
script;
def absent():
    return None
ZAG
negative mixed_null 'conflicting types' <<'ZAG'
script;
def maybe(flag):
    if flag:
        return "yes"
    return None
ZAG
# Reverse-order forwarding takes multiple propagation rounds.
{
    echo 'script;'
    for ((i=0;i<24;i++)); do
        printf 'def f%d(x):\n    return f%d(x)\n' "$i" "$((i+1))"
    done
    printf 'def f24(x):\n    return x\nvalue=f0("chain")\n'
} >"$tmp/chain.zs"
"$tmp/normalizer" "$tmp/chain.zs" >"$tmp/chain.zag"
grep -q 'fn f24(x:\[\]u8) \[\]u8' "$tmp/chain.zag"
{
    echo 'script;'
    for ((i=0;i<129;i++)); do
        printf 'def f%d():\n    return 1\n' "$i"
    done
} >"$tmp/limit.zs"
if "$tmp/normalizer" "$tmp/limit.zs" >"$tmp/limit.log" 2>&1; then
    echo "function limit unexpectedly accepted" >&2; exit 1
fi
grep -q 'function limit (128)' "$tmp/limit.log"
{
    echo 'script;'
    printf 'def text():\n    return f"'
    for ((i=0;i<65;i++)); do printf '{1}'; done
    printf '"\n'
} >"$tmp/holes.zs"
if "$tmp/normalizer" "$tmp/holes.zs" >"$tmp/holes.log" 2>&1; then
    echo "interpolation hole limit unexpectedly accepted" >&2; exit 1
fi
grep -q 'too many interpolation expressions' "$tmp/holes.log"
echo "script inference: PASS (35 checks, native runtime, 16 diagnostics, forward chain, function/interpolation bounds)"
