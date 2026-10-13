#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-script-ergonomics.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

"$compiler" selfhost/script_ergonomics_test.zag -o "$tmp/normalizer" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || {
    cat "$tmp/build.log" >&2; exit 1;
}
"$tmp/normalizer"

cat >"$tmp/runtime.zs" <<'ZAG'
script;
# { must not disable normalization
// } must not disable normalization
def same(a: int, b: int) -> bool: # equality in arguments
    return a==b
x=10
x -= 2+3
if x != 5:
    return 1
x *= 2+3;
if x != 25:
    return 2
x /= 2+3
if x != 5:
    return 3
x %= 1+2
if x != 2:
    return 4
x += 2*3 // is not an operator in this comment
if x != 8:
    return 5
ok = same(x, 8)
if not ok or False:
    return 6
literal = "is and # // += {"
ch = '#'
if ch != 35:
    return 7
return 0
ZAG
"$tmp/normalizer" "$tmp/runtime.zs" >"$tmp/runtime.zag"
"$compiler" "$tmp/runtime.zag" -o "$tmp/runtime" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/runtime.log" 2>&1 || {
    cat "$tmp/runtime.zag" "$tmp/runtime.log" >&2; exit 1;
}
"$tmp/runtime"

for expr in 'a is b' 'a is not b' 'a is None' 'a is not None'; do
    printf 'script;\nif %s:\n    return 0\n' "$expr" >"$tmp/identity.zs"
    if "$tmp/normalizer" "$tmp/identity.zs" >"$tmp/identity.log" 2>&1; then
        echo "identity unexpectedly accepted: $expr" >&2; exit 1
    fi
    grep -q 'identity operator is unsupported' "$tmp/identity.log"
done
echo "script ergonomics: PASS (normalizer, native runtime, 4 identity rejections)"
