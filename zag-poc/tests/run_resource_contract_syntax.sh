#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
WORK=$(mktemp -d /tmp/zag-resource-contract-syntax.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

if "$ZNC_BIN" selfhost/resource_contract_syntax_test.zag -o "$WORK/contract-test" \
    --no-zagd --no-analyze --no-foreground-cache >"$WORK/build.log" 2>&1 &&
   "$WORK/contract-test" >"$WORK/run.log" 2>&1 &&
   grep -q '^resource syntax: 39/39$' "$WORK/run.log"; then
    ok "parser, formatter, AST JSON, import qualification, and manifest identity"
else
    bad "parser, formatter, AST JSON, import qualification, and manifest identity"
    sed -n '1,20p' "$WORK/build.log"
    sed -n '1,20p' "$WORK/run.log"
fi

project() {
    mkdir -p "$WORK/$1"
    printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$WORK/$1/zag.mod"
}
reject() {
    local name=$1 source=$2 diagnostic=$3
    project "$name"
    printf '%s\n' "$source" >"$WORK/$name/main.zag"
    if (cd "$WORK/$name" && "$ZNC_BIN" check main.zag --no-zagd --no-analyze --no-foreground-cache) >"$WORK/$name/log" 2>&1; then
        bad "$name rejects malformed resource syntax"
    elif grep -q "$diagnostic" "$WORK/$name/log"; then
        ok "$name rejects malformed resource syntax"
    else
        bad "$name emits its fail-closed diagnostic"
        sed -n '1,12p' "$WORK/$name/log"
    fi
}

project format
printf '%s\n' '@metadata(outer(inner, 2)) @resource pub struct Box[T]{ptr:@owned(release_box) *T} pub fn release_box[T](p:*T)void{} pub extern fn acquire(backing:@retained_by_return []u8)?*Box[u8] @acquires(release_box);' >"$WORK/format/main.zag"
if (cd "$WORK/format" && "$ZNC_BIN" fmt --in-place main.zag) >"$WORK/format/log" 2>&1 &&
   cp "$WORK/format/main.zag" "$WORK/format/once.zag" &&
   (cd "$WORK/format" && "$ZNC_BIN" fmt --in-place main.zag) >>"$WORK/format/log" 2>&1 &&
   cmp -s "$WORK/format/once.zag" "$WORK/format/main.zag" &&
   grep -q '^@metadata(outer(inner,2))$' "$WORK/format/main.zag" &&
   grep -q 'ptr: @owned(release_box) \*T' "$WORK/format/main.zag" &&
   grep -q 'backing: @retained_by_return \[\]u8' "$WORK/format/main.zag" &&
   grep -q '@acquires(release_box)' "$WORK/format/main.zag"; then
    ok "formatter canonicalizes and preserves balanced resource relations"
else
    bad "formatter canonicalizes and preserves balanced resource relations"
    sed -n '1,30p' "$WORK/format/log"
    sed -n '1,30p' "$WORK/format/main.zag"
fi

reject owned_missing 'fn release_box(p:*u8)void{} @resource struct Box { ptr:@owned *u8 } fn main()i32{return 0;}' 'requires a release-function relation'
reject owned_empty 'fn release_box(p:*u8)void{} @resource struct Box { ptr:@owned() *u8 } fn main()i32{return 0;}' 'requires one plain release-function identifier'
reject owned_member 'fn release_box(p:*u8)void{} @resource struct Box { ptr:@owned(api.release_box) *u8 } fn main()i32{return 0;}' 'accepts exactly one plain release-function identifier'
reject acquires_extra 'extern fn acquire() ?*u8 @acquires(release_box,release_other); fn main()i32{return 0;}' 'accepts exactly one plain release-function identifier'
reject resource_args '@resource(owner) struct Box { ptr:*u8 } fn main()i32{return 0;}' '@resource does not accept arguments'
reject retained_args 'extern fn acquire(backing:@retained_by_return(owner) []u8)?*u8 @acquires(release_box); fn main()i32{return 0;}' '@retained_by_return does not accept arguments'
reject duplicate_contract 'fn inspect(value:@borrows @consumes *u8)void{} fn main()i32{return 0;}' 'may declare only one lifetime/resource contract'
reject unbalanced_annotation '@metadata(outer(inner,2) @resource struct Box { ptr:*u8 }' 'unterminated annotation arguments'

echo "resource contract syntax: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
