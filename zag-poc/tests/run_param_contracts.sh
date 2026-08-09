#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
WORK="$(mktemp -d /tmp/zag-param-contracts.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
project() {
    mkdir -p "$WORK/$1"
    printf 'name = "%s"\nversion = "0"\nedition = "%s"\n' "$1" "$2" >"$WORK/$1/zag.mod"
}
check_ok() {
    name="$1"; label="$2"
    if (cd "$WORK/$name" && "$ZNC_BIN" check main.zag --no-zagd --no-analyze) >"$WORK/$name/log" 2>&1; then
        ok "$label"
    else
        bad "$label"; sed -n '1,12p' "$WORK/$name/log"
    fi
}
check_reject() {
    name="$1"; label="$2"; diagnostic="$3"
    if (cd "$WORK/$name" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$WORK/$name/log" 2>&1 || [ -e "$WORK/$name/out" ]; then
        bad "$label"
    elif grep -q "$diagnostic" "$WORK/$name/log"; then
        ok "$label"
    else
        bad "$label"; sed -n '1,12p' "$WORK/$name/log"
    fi
}

project format 2027
printf '%s\n' 'extern fn inspect(left:@borrows *u8,right:@borrows_mut *u8)void @cabi;' 'fn main()i32{return 0;}' >"$WORK/format/main.zag"
if (cd "$WORK/format" && "$ZNC_BIN" fmt --in-place main.zag) >"$WORK/format/log" 2>&1 &&
   grep -q 'left: @borrows \*u8, right: @borrows_mut \*u8' "$WORK/format/main.zag"; then
    ok "formatter preserves parameter lifetime contracts"
else
    bad "formatter preserves parameter lifetime contracts"; sed -n '1,12p' "$WORK/format/log"
fi

project multipointer 2027
printf '%s\n' \
  'fn inspect(left:@borrows *u8,right:@borrows *u8)void { }' \
  'fn main() i32 { unsafe { let left:*u8=_zag_malloc(8); let right:*u8=_zag_malloc(8); inspect(left,right); _zag_free(left); _zag_free(right); } return 0; }' \
  >"$WORK/multipointer/main.zag"
check_ok multipointer "two explicit pointer borrows authorize only their arguments"

project mutable 2027
printf '%s\n' \
  'fn fill(out:@borrows_mut *u8)void { unsafe { out[0]=42; } }' \
  'fn main() i32 { unsafe { let out:*u8=_zag_malloc(8); fill(out); let value:i32=out[0] as i32; _zag_free(out); return value; } }' \
  >"$WORK/mutable/main.zag"
check_ok mutable "parameter-local mutable borrow permits mutation"

project shared_write 2027
printf '%s\n' 'fn bad(value:@borrows *u8)void { unsafe { value[0]=1; } } fn main()i32{return 0;}' >"$WORK/shared_write/main.zag"
check_reject shared_write "shared parameter borrow rejects mutation" 'cannot mutate through a shared borrow'

project exact_argument 2027
printf '%s\n' \
  'fn inspect(left:@borrows *u8,right:*u8)void { }' \
  'fn main() i32 { unsafe { let left:*u8=_zag_malloc(8); let right:*u8=_zag_malloc(8); inspect(left,right); _zag_free(left); _zag_free(right); } return 0; }' \
  >"$WORK/exact_argument/main.zag"
check_reject exact_argument "an unannotated second owner remains fail-closed" 'root `right`'

project mixed_modes 2027
printf '%s\n' \
  'fn finish(dead:@consumes *u8,live:@borrows *u8)void { unsafe { _zag_free(dead); } }' \
  'fn main() i32 { unsafe { let dead:*u8=_zag_malloc(8); let live:*u8=_zag_malloc(8); finish(dead,live); live[0]=42; let value:i32=live[0] as i32; _zag_free(live); return value; } }' \
  >"$WORK/mixed_modes/main.zag"
check_ok mixed_modes "distinct consume and borrow parameters compose"

project consumed_use 2027
printf '%s\n' \
  'fn finish(dead:@consumes *u8,live:@borrows *u8)void { unsafe { _zag_free(dead); } }' \
  'fn main() i32 { unsafe { let dead:*u8=_zag_malloc(8); let live:*u8=_zag_malloc(8); finish(dead,live); dead[0]=1; _zag_free(live); } return 0; }' \
  >"$WORK/consumed_use/main.zag"
check_reject consumed_use "only the consumed argument becomes unavailable" 'use after free of named allocation `dead`'

project borrowed_return 2027
printf '%s\n' 'fn bad(value:@borrows *u8)*u8 { return value; } fn main()i32{return 0;}' >"$WORK/borrowed_return/main.zag"
check_reject borrowed_return "parameter-local borrow cannot imply a returned lifetime" 'without an explicit return-borrow contract'

project borrowed_escape 2027
printf '%s\n' 'fn retain(value:*u8)void { } fn bad(value:@borrows *u8)void { retain(value); } fn main()i32{return 0;}' >"$WORK/borrowed_escape/main.zag"
check_reject borrowed_escape "parameter-local borrow cannot escape through an uncontracted callee" 'escapes through uncontracted call `retain`'

project legacy_mix 2027
printf '%s\n' 'fn bad(left:@borrows *u8,right:*u8)void @borrows { } fn main()i32{return 0;}' >"$WORK/legacy_mix/main.zag"
check_reject legacy_mix "legacy and parameter-local contracts cannot mix" 'cannot be mixed with legacy function-level'

project scalar_contract 2027
printf '%s\n' 'fn bad(count:@borrows i64)void { } fn main()i32{return 0;}' >"$WORK/scalar_contract/main.zag"
check_reject scalar_contract "lifetime contracts reject scalar parameters" 'require a raw-pointer or Allocation parameter'

project old_edition 2026
printf '%s\n' 'fn bad(value:@borrows *u8)void { } fn main()i32{return 0;}' >"$WORK/old_edition/main.zag"
check_reject old_edition "parameter contracts are edition-2027-only" 'require edition 2027'

project duplicate 2027
printf '%s\n' 'fn bad(value:@borrows @consumes *u8)void { } fn main()i32{return 0;}' >"$WORK/duplicate/main.zag"
check_reject duplicate "duplicate parameter contracts fail closed" 'only one lifetime contract'

project cabi_multi 2027
printf '%s\n' \
  'extern fn memcmp(left:@borrows *u8,right:@borrows *u8,count:i64)i32 @cabi;' \
  'fn main() i32 { unsafe { let left:*u8=_zag_malloc(8); let right:*u8=_zag_malloc(8); left[0]=42; right[0]=42; let same:i32=memcmp(left,right,8); _zag_free(left); _zag_free(right); if(same==0){return 42;} return 1; } }' \
  >"$WORK/cabi_multi/main.zag"
if (cd "$WORK/cabi_multi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o out) >"$WORK/cabi_multi/log" 2>&1 && [ -x "$WORK/cabi_multi/out" ]; then
    "$WORK/cabi_multi/out"; rc=$?
    [ "$rc" = 42 ] && ok "multi-pointer parameter contracts execute through libc" || bad "multi-pointer C ABI execution exit=$rc"
else
    bad "multi-pointer parameter contracts build through libc"; sed -n '1,16p' "$WORK/cabi_multi/log"
fi

project cabi_null 2027
printf '%s\n' \
  'extern fn write(fd:i32,data:@borrows *u8,count:i64)i64 @cabi;' \
  'fn main() i32 { unsafe { let wrote:i64=write(1,null as *u8,0); if(wrote==0){return 42;} return 1; } }' \
  >"$WORK/cabi_null/main.zag"
if (cd "$WORK/cabi_null" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o out) >"$WORK/cabi_null/log" 2>&1 && [ -x "$WORK/cabi_null/out" ]; then
    "$WORK/cabi_null/out"; rc=$?
    [ "$rc" = 42 ] && ok "parameter-local C borrow accepts an untracked null pointer" || bad "null-pointer C ABI execution exit=$rc"
else
    bad "parameter-local C borrow builds with an untracked null pointer"; sed -n '1,16p' "$WORK/cabi_null/log"
fi

echo "param contracts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
