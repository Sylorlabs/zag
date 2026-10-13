#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-script-symbol-view.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/app.zs" <<'ZAG'
script;

def doubled(value):
    return value * 2

def tripled(value):
    return value * 3

if doubled(21) != 42:
    return 1
ZAG

"$compiler" view "$tmp/app.zs" --level explicit --symbol doubled --no-zagd >"$tmp/view.zag"
grep -q 'fn doubled(' "$tmp/view.zag"
! grep -q 'fn tripled(' "$tmp/view.zag"

"$compiler" expand "$tmp/app.zs" --to explicit --symbol tripled --no-zagd >"$tmp/expand.zag"
grep -q 'fn tripled(' "$tmp/expand.zag"
! grep -q 'fn doubled(' "$tmp/expand.zag"

if "$compiler" view "$tmp/app.zs" --level explicit --symbol missing --no-zagd >"$tmp/missing.out" 2>"$tmp/missing.err"; then
    echo "missing selective symbol unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'no function named `missing`' "$tmp/missing.err"

if "$compiler" expand "$tmp/app.zs" --to explicit --symbol doubled --output "$tmp/owned.zag" --no-zagd >"$tmp/output.out" 2>"$tmp/output.err"; then
    echo "selective expand unexpectedly published an output artifact" >&2
    exit 1
fi
grep -q 'reserved for provenance-backed selective promotion' "$tmp/output.err"
test ! -e "$tmp/owned.zag"

pass=4
reject() {
    local diagnostic=$1
    shift
    if "$compiler" "$@" >"$tmp/reject.out" 2>"$tmp/reject.err"; then
        echo "selective symbol unexpectedly succeeded: $*" >&2
        exit 1
    fi
    grep -Fq -- "$diagnostic" "$tmp/reject.err"
    test ! -s "$tmp/reject.out"
    test ! -e "$tmp/owned.zag"
    pass=$((pass + 1))
}

for operation in view expand; do
    level=--level
    if [ "$operation" = expand ]; then level=--to; fi
    args=("$operation" "$tmp/app.zs" "$level" explicit --no-zagd)
    reject '--symbol requires a value' "${args[@]}" --symbol
    reject '--symbol requires a value' "${args[@]}" --symbol ''
    reject '--symbol requires a value' "${args[@]}" --symbol --no-zagd
    reject 'use --symbol <function>' "${args[@]}" --symbol=doubled
    for projection in simple explained native invalid; do
        reject '--symbol requires the explicit level' "$operation" "$tmp/app.zs" "$level" "$projection" --symbol doubled --no-zagd
    done
    reject '--symbol requires the explicit level' "$operation" "$tmp/app.zs" --symbol doubled --no-zagd
    reject "$level requires a value" "$operation" "$tmp/app.zs" --symbol doubled "$level"
    for flag in --output -o; do
        reject "$flag requires a value" "${args[@]}" --symbol doubled "$flag"
        reject 'reserved for provenance-backed selective promotion' "${args[@]}" --symbol doubled "$flag" "$tmp/owned.zag"
    done
    reject 'reserved for provenance-backed selective promotion' "${args[@]}" --symbol doubled "--output=$tmp/owned.zag"
    reject '--format requires a value' "${args[@]}" --symbol doubled --format
    reject '--format requires a value' "${args[@]}" --symbol doubled --format --no-zagd
    for format in json invalid; do
        reject '--format with --symbol must be text' "${args[@]}" --symbol doubled --format "$format"
    done
    reject '--format with --symbol must be text' "${args[@]}" --symbol doubled --format=json
    "$compiler" "${args[@]}" --symbol doubled --format text >"$tmp/text.zag"
    cmp "$tmp/view.zag" "$tmp/text.zag"
    pass=$((pass + 1))
    for symbol in main __zag_compiler_script_body_7f3a __zag_compiler_script_uncaught_7f3a; do
        reject "no function named \`$symbol\`" "${args[@]}" --symbol "$symbol"
    done
done

cat >"$tmp/helpers.zag" <<'ZAG'
pub fn imported_only(value: i32) i32 { return value + 100; }
pub fn doubled(value: i32) i32 { return value + 200; }
ZAG
cat >"$tmp/root.zs" <<'ZAG'
script;
@import("helpers.zag") as helpers
fn doubled(value: i32) i32 { return value * 2; }
return 0;
ZAG
for operation in view expand; do
    level=--level
    if [ "$operation" = expand ]; then level=--to; fi
    # The alias keeps both doubled declarations legal. Check the resolved
    # imported names too, so this proves origin filtering rather than a miss.
    for symbol in imported_only helpers__imported_only helpers__doubled; do
        reject "no function named \`$symbol\`" "$operation" "$tmp/root.zs" "$level" explicit --symbol "$symbol" --no-zagd
    done
    "$compiler" "$operation" "$tmp/root.zs" "$level" explicit --symbol doubled --no-zagd >"$tmp/root.zag"
    grep -q 'fn doubled(' "$tmp/root.zag"
    grep -q 'value \* 2' "$tmp/root.zag"
    ! grep -q '200' "$tmp/root.zag"
    pass=$((pass + 1))
done

cat >"$tmp/closure.zs" <<'ZAG'
script;
fn apply(value: i32) i32 {
    let double: fn(i32) i32 = fn[](x: i32) i32 { return x * 2; };
    return double(value);
}
return 0;
ZAG
for operation in view expand; do
    level=--level
    if [ "$operation" = expand ]; then level=--to; fi
    reject 'no function named `__clos_0`' "$operation" "$tmp/closure.zs" "$level" explicit --symbol __clos_0 --no-zagd
done

echo "zagscript-symbol-view pass=$pass fail=0"
