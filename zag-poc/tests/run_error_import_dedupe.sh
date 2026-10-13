#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh

compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-error-import-dedupe.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

printf '%s\n' 'name = "error-import-dedupe-test"' 'edition = "2027"' >"$tmp/zag.mod"

cat >"$tmp/same.zag" <<'ZAG'
error { Same }
pub fn one() i32 { return 1; }
pub fn may_fail(fail: bool) !i32 {
    if (fail) { return error.Same; }
    return 1;
}
ZAG

cat >"$tmp/two-aliases.zag" <<'ZAG'
@import("same.zag") as left
@import("same.zag") as right
fn main() i32 {
    let a: i32 = left.may_fail(false) catch 10;
    let b: i32 = right.may_fail(false) catch 20;
    return left.one() + right.one() + a + b - 4;
}
ZAG

cat >"$tmp/plain-then-alias.zag" <<'ZAG'
@import("same.zag")
@import("same.zag") as again
fn main() i32 {
    let a: i32 = may_fail(false) catch 10;
    let b: i32 = again.may_fail(false) catch 20;
    return one() + again.one() + a + b - 4;
}
ZAG

cat >"$tmp/alias-then-plain.zag" <<'ZAG'
@import("same.zag") as again
@import("same.zag")
fn main() i32 {
    let a: i32 = again.may_fail(false) catch 10;
    let b: i32 = may_fail(false) catch 20;
    return again.one() + one() + a + b - 4;
}
ZAG

for source in two-aliases plain-then-alias alias-then-plain; do
    "$compiler" "$tmp/$source.zag" -o "$tmp/$source" \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/$source.out" 2>"$tmp/$source.err" || {
        cat "$tmp/$source.out" >&2
        cat "$tmp/$source.err" >&2
        exit 1
    }
    "$tmp/$source"
done

cat >"$tmp/a.zag" <<'ZAG'
error { Same }
pub fn a() i32 { return 1; }
ZAG

cat >"$tmp/b.zag" <<'ZAG'
error { Same }
pub fn b() i32 { return 2; }
ZAG

cat >"$tmp/distinct.zag" <<'ZAG'
@import("a.zag") as a
@import("b.zag") as b
fn main() i32 { return a.a() + b.b() - 3; }
ZAG

if "$compiler" "$tmp/distinct.zag" -o "$tmp/distinct" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/distinct.out" 2>"$tmp/distinct.err"; then
    echo "distinct module error sets unexpectedly merged" >&2
    exit 1
fi
grep -q "duplicate type definition '__zag_errors'" "$tmp/distinct.err"
test ! -e "$tmp/distinct"

echo "error import dedupe: PASS"
