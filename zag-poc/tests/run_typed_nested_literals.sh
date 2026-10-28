#!/usr/bin/env bash
# Prevent repeated recursive type-checking of nested record field initializers.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
tmp=$(mktemp -d /tmp/zag-typed-nested.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
flags=(--no-zagd --no-analyze --no-foreground-cache)
if [ "$(zag_native_platform)" = macos-arm64 ]; then flags+=(--target macos-arm64); fi

# Compiling this small harness imports the CURRENT selfhost/typed.zag, so the
# regression exercises the code under test even before a full znc bootstrap.
"$compiler" selfhost/script_record_test.zag -o "$tmp/checker" "${flags[@]}" >"$tmp/build.log" 2>&1 || {
    cat "$tmp/build.log" >&2
    exit 1
}

nested_fixture() {
    local depth=$1 mode=$2 i expr field
    if [ "$mode" = good ]; then field='null as *mut Node'; else field='"wrong"'; fi
    {
        printf 'struct Node { value:i32 }\n'
        printf 'struct Nest%s { ptr:*mut Node }\n' "$depth"
        i=$((depth - 1))
        while [ "$i" -ge 0 ]; do
            printf 'struct Nest%s { next:Nest%s }\n' "$i" "$((i + 1))"
            i=$((i - 1))
        done
        expr="Nest${depth}{.ptr=${field}}"
        i=$((depth - 1))
        while [ "$i" -ge 0 ]; do
            expr="Nest${i}{.next=${expr}}"
            i=$((i - 1))
        done
        printf 'fn main() i32 { let value:Nest0=%s; return 0; }\n' "$expr"
    } >"$tmp/${depth}-${mode}.zag"
}

# The old double-recursive implementation exceeded 7 seconds at depth 32;
# the fixed implementation checks depth 64 in a fraction of a second.
for depth in 16 64; do
    for mode in good bad; do
        nested_fixture "$depth" "$mode"
        code=0
        perl -e 'alarm 12; exec @ARGV' "$tmp/checker" "$tmp/${depth}-${mode}.zag"             >"$tmp/out" 2>"$tmp/err" || code=$?
        if [ "$mode" = good ]; then
            if [ "$code" -ne 0 ]; then
                echo "nested literal depth $depth: valid rejected or timed out (exit=$code)" >&2
                head -10 "$tmp/err" >&2
                exit 1
            fi
        else
            if [ "$code" -ne 1 ] || ! grep -q 'error\[E0203\]: expected \*mut Node, found \[\]u8' "$tmp/err"; then
                echo "nested literal depth $depth: missing inner type diagnostic (exit=$code)" >&2
                head -10 "$tmp/err" >&2
                exit 1
            fi
        fi
    done
done
echo "typed nested literals: PASS (depths 16/64, valid and invalid field types)"
