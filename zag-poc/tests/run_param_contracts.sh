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
printf '%s\n' 'extern fn inspect(left:@borrows *u8,right:@borrows_mut *u8)void @cabi;' 'fn inspect_slices(data:@borrows []u8,out:@borrows_mut []u8)void { }' 'fn main()i32{return 0;}' >"$WORK/format/main.zag"
if (cd "$WORK/format" && "$ZNC_BIN" fmt --in-place main.zag) >"$WORK/format/log" 2>&1 &&
   grep -q 'left: @borrows \*u8, right: @borrows_mut \*u8' "$WORK/format/main.zag" &&
   grep -q 'data: @borrows \[\]u8, out: @borrows_mut \[\]u8' "$WORK/format/main.zag"; then
    ok "formatter preserves pointer and slice parameter lifetime contracts"
else
    bad "formatter preserves pointer and slice parameter lifetime contracts"; sed -n '1,12p' "$WORK/format/log"
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

project slice_runtime 2027
printf '%s\n' \
  'struct SliceSnapshot { length:i32, first:u8 }' \
  'fn checksum(data:@borrows []u8)i32 { let total:i32=0; let i:i32=0; while(i<data.len){total=total+(data[i] as i32);i=i+1;} return total; }' \
  'fn snapshot(data:@borrows []u8)SliceSnapshot { return SliceSnapshot{.length=data.len,.first=data[0]}; }' \
  'fn stamp(data:@borrows_mut []u8)void { data[0]=42; }' \
  'fn main()i32 { let bytes:[]u8=_zag_strdup("***"); let before:i32=checksum(bytes); let copy:SliceSnapshot=snapshot(bytes); stamp(bytes); let value:i32=bytes[0] as i32; _zag_str_free(bytes); if(before==126&&copy.length==3&&copy.first==42){return value;} return 1; }' \
  >"$WORK/slice_runtime/main.zag"
if (cd "$WORK/slice_runtime" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$WORK/slice_runtime/log" 2>&1 && [ -x "$WORK/slice_runtime/out" ]; then
    "$WORK/slice_runtime/out"; rc=$?
    [ "$rc" = 42 ] && ok "shared and mutable slice borrows execute and the owner may be freed after each call" || bad "slice borrow native execution exit=$rc"
else
    bad "slice borrow native execution builds"; sed -n '1,16p' "$WORK/slice_runtime/log"
fi

project slice_shared_write 2027
printf '%s\n' 'fn bad(data:@borrows []u8)void { data[0]=1; } fn main()i32{return 0;}' >"$WORK/slice_shared_write/main.zag"
check_reject slice_shared_write "shared slice borrow rejects element mutation" 'cannot mutate through a shared borrow'

project slice_return 2027
printf '%s\n' 'fn bad(data:@borrows []u8)[]u8 { return data; } fn main()i32{return 0;}' >"$WORK/slice_return/main.zag"
check_reject slice_return "borrowed slice cannot escape through return" 'without an explicit return-borrow contract'

project slice_pointer_return 2027
printf '%s\n' \
  'extern fn _zag_slice_ptr(data:[]u8)*i8' \
  'fn bad(data:@borrows []u8)*u8 { return _zag_slice_ptr(data) as *u8; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/slice_pointer_return/main.zag"
check_reject slice_pointer_return "pointer projected from a borrowed slice cannot escape through return" 'without an explicit return-borrow contract'

project slice_store 2027
printf '%s\n' \
  'struct Sink { retained:[]u8 }' \
  'fn bad(out:@borrows_mut *Sink,data:@borrows []u8)void { out.*.retained=data; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/slice_store/main.zag"
check_reject slice_store "borrowed slice cannot be retained in a non-local field" 'cannot be stored in a non-local aggregate'

project slice_field_return 2027
printf '%s\n' \
  'struct Sink { retained:[]u8 }' \
  'fn bad(data:@borrows []u8)Sink { return Sink{.retained=data}; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/slice_field_return/main.zag"
check_reject slice_field_return "borrowed slice cannot escape inside a returned field" 'without an explicit return-borrow contract'

project slice_escape 2027
printf '%s\n' \
  'fn retain(data:[]u8)void { }' \
  'fn bad(data:@borrows []u8)void { retain(data); }' \
  'fn main()i32{return 0;}' \
  >"$WORK/slice_escape/main.zag"
check_reject slice_escape "borrowed slice cannot escape through an uncontracted callee" 'escapes through uncontracted call `retain`'

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

project owned_print_free 2027
printf '%s\n' 'fn main()i32 { let text:[]u8=_zag_i64_to_str(42); _zag_print(text); _zag_str_free(text); return 0; }' >"$WORK/owned_print_free/main.zag"
check_ok owned_print_free "synchronous _zag_print permits an owned helper result to be freed"

project unknown_zag_escape 2027
printf '%s\n' 'fn _zag_unknown_sink(value:[]u8)void { } fn main()i32 { let text:[]u8=_zag_i64_to_str(42); _zag_unknown_sink(text); _zag_str_free(text); return 0; }' >"$WORK/unknown_zag_escape/main.zag"
check_reject unknown_zag_escape "unknown _zag bridges remain fail-closed" 'escapes through uncontracted call `_zag_unknown_sink`'

project legacy_mix 2027
printf '%s\n' 'fn bad(left:@borrows *u8,right:*u8)void @borrows { } fn main()i32{return 0;}' >"$WORK/legacy_mix/main.zag"
check_reject legacy_mix "legacy and parameter-local contracts cannot mix" 'cannot be mixed with legacy function-level'

project scalar_contract 2027
printf '%s\n' 'fn bad(count:@borrows i64)void { } fn main()i32{return 0;}' >"$WORK/scalar_contract/main.zag"
check_reject scalar_contract "lifetime contracts reject scalar parameters" 'raw-pointer, Allocation, slice'

project slice_consume 2027
printf '%s\n' 'fn bad(data:@consumes []u8)void { } fn main()i32{return 0;}' >"$WORK/slice_consume/main.zag"
check_reject slice_consume "slice views cannot claim ownership transfer" 'parameter consume contracts require a raw-pointer, Allocation'

project old_edition 2026
printf '%s\n' 'fn bad(value:@borrows *u8)void { } fn main()i32{return 0;}' >"$WORK/old_edition/main.zag"
check_reject old_edition "parameter contracts are edition-2027-only" 'require edition 2027'

project old_edition_import 2026
printf '%s\n' 'pub fn inspect(value:@borrows *u8)void { }' >"$WORK/old_edition_import/plain.zag"
printf '%s\n' 'pub fn mutate(value:@borrows_mut *u8)void { }' 'pub fn inspect_bytes(data:@borrows []u8)i32 { return data.len; }' >"$WORK/old_edition_import/qualified.zag"
printf '%s\n' \
  '@import("plain.zag")' \
  '@import("qualified.zag") as contracts' \
  'fn main()i32{return 0;}' \
  >"$WORK/old_edition_import/main.zag"
check_ok old_edition_import "edition-2026 roots accept inactive imported lifetime metadata"

project slice_old_edition 2026
printf '%s\n' 'fn bad(data:@borrows []u8)void { } fn main()i32{return 0;}' >"$WORK/slice_old_edition/main.zag"
check_reject slice_old_edition "slice parameter contracts are edition-2027-only" 'require edition 2027'

project slice_imported_contract 2027
printf '%s\n' 'pub fn inspect(data:@borrows []u8)i32 { return data.len; }' >"$WORK/slice_imported_contract/contracts.zag"
printf '%s\n' \
  '@import("contracts.zag") as contracts' \
  'fn main()i32 { let bytes:[]u8=_zag_strdup("zag"); let count:i32=contracts.inspect(bytes); _zag_str_free(bytes); return count-3; }' \
  >"$WORK/slice_imported_contract/main.zag"
check_ok slice_imported_contract "imported slice borrow metadata authorizes synchronous use before owner release"

project duplicate 2027
printf '%s\n' 'fn bad(value:@borrows @consumes *u8)void { } fn main()i32{return 0;}' >"$WORK/duplicate/main.zag"
check_reject duplicate "duplicate parameter contracts fail closed" 'only one lifetime/resource contract'

project declaration_conflict 2027
printf '%s\n' \
  'extern fn touch(value:@borrows *u8)void @cabi;' \
  'extern fn touch(value:@consumes *u8)void @cabi;' \
  'fn main()i32{return 0;}' \
  >"$WORK/declaration_conflict/main.zag"
check_reject declaration_conflict "conflicting contracts across duplicate declarations fail closed" 'conflicting parameter lifetime contracts'

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

project imported_contracts 2027
printf '%s\n' \
  'pub struct Cell { value:i32, pointer:*u8 }' \
  'pub fn read_cell(cell:@borrows *Cell)i32 { return cell.*.value; }' \
  'pub fn read_generic[T](cell:@borrows *T)i32 { return 42; }' \
  'extern fn imported_inspect(value:@borrows *u8)void @cabi;' \
  >"$WORK/imported_contracts/contracts.zag"
printf '%s\n' \
  '@import("contracts.zag") as contracts' \
  'struct Host { pointer:*u8 }' \
  'fn forward(host:@borrows *Host)void { unsafe { imported_inspect(host.*.pointer); } }' \
  'fn main()i32 { unsafe { let cell:*contracts.Cell=_zag_malloc(16) as *contracts.Cell; cell.*.value=42; cell.*.pointer=null as *u8; let a:i32=contracts.read_cell(cell); let b:i32=contracts.read_generic[contracts.Cell](cell); forward(cell as *Host); _zag_free(cell as *u8); return a+b-42; } }' \
  >"$WORK/imported_contracts/main.zag"
check_ok imported_contracts "imported C, qualified, and generic parameter contracts survive resolution"

project scalar_projection 2027
printf '%s\n' \
  'enum Kind { ready }' \
  'struct Source { kind:Kind, x:i32, y:i32, pointer:*u8 }' \
  'struct Snapshot { kind:Kind, x:i32, y:i32 }' \
  'fn scalar(source:@borrows *Source)i32 { return source.*.x; }' \
  'fn snapshot(source:@borrows *Source)Snapshot { return Snapshot{.kind=source.*.kind,.x=source.*.x,.y=source.*.y}; }' \
  'fn write_snapshot(out:@borrows_mut *Snapshot,source:@borrows *Source)void { out.*.x=source.*.x; out.*.y=source.*.y; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/scalar_projection/main.zag"
check_ok scalar_projection "borrowed-pointee scalar reads and pointer-free value snapshots do not escape"

project fresh_pointer_aggregate 2027
printf '%s\n' \
  'struct Box { pointer:*u8, length:i32 }' \
  'fn fresh(source:@borrows *Box)Box { return Box{.pointer=null as *u8,.length=source.*.length}; }' \
  'fn main()i32 { unsafe { let pointer:*u8=_zag_malloc(8); let source:Box=Box{.pointer=pointer,.length=42}; let copy:Box=fresh(&source); _zag_free(source.pointer); if(copy.length==42){return 0;} return 1; } }' \
  >"$WORK/fresh_pointer_aggregate/main.zag"
check_ok fresh_pointer_aggregate "parameter-local borrow permits a fresh pointer-bearing aggregate result"

project borrowed_scalar_discard 2027
printf '%s\n' \
  'struct Tree { count:i32 }' \
  'fn borrowed_mut_helper(tree:@borrows_mut *Tree)i32 { tree.*.count=tree.*.count+1; return tree.*.count; }' \
  'fn main()i32 { let local:Tree=Tree{.count=0}; _=borrowed_mut_helper(&local); return local.count; }' \
  >"$WORK/borrowed_scalar_discard/main.zag"
check_ok borrowed_scalar_discard "scalar call results do not propagate borrowed aggregate provenance into discard"

project retained_pointer_discard 2027
printf '%s\n' \
  'struct Tree { count:i32 }' \
  'fn retained(tree:*Tree)*Tree @borrows { return tree; }' \
  'fn main()i32 { let local:Tree=Tree{.count=0}; _=retained(&local); return 0; }' \
  >"$WORK/retained_pointer_discard/main.zag"
check_reject retained_pointer_discard "pointer-bearing call results retain borrowed aggregate provenance" 'escapes through non-local aggregate store'

project stored_backing_elements 2027
printf '%s\n' \
  'struct Buffer { data:*u8, len:i32 } struct PointerBuffer { data:**u8, len:i32 } struct PointerSnapshot { pointer:*u8 }' \
  'fn grow(source:@borrows_mut *Buffer)void { unsafe { source.*.data=_zag_realloc(source.*.data as *i8,16) as *u8; } }' \
  'fn pop(source:@borrows_mut *Buffer)u8 { let last:i32=source.*.len-1; return source.*.data[last]; }' \
  'fn pop_pointer(source:@borrows_mut *PointerBuffer)*u8 { let last:i32=source.*.len-1; return source.*.data[last]; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/stored_backing_elements/main.zag"
check_ok stored_backing_elements "mutable backing-pointer replacement and element loads preserve container lifetime"

project shared_realloc_reassign 2027
printf '%s\n' \
  'struct Buffer { data:*u8 }' \
  'fn bad(source:@borrows *Buffer)void { unsafe { source.*.data=_zag_realloc(source.*.data as *i8,16) as *u8; } }' \
  'fn main()i32{return 0;}' \
  >"$WORK/shared_realloc_reassign/main.zag"
check_reject shared_realloc_reassign "shared borrows cannot replace backing storage" 'uncontracted call `_zag_realloc`'

project mismatched_realloc_reassign 2027
printf '%s\n' \
  'struct Buffers { left:*u8, right:*u8 }' \
  'fn bad(source:@borrows_mut *Buffers)void { unsafe { source.*.right=_zag_realloc(source.*.left as *i8,16) as *u8; } }' \
  'fn main()i32{return 0;}' \
  >"$WORK/mismatched_realloc_reassign/main.zag"
check_reject mismatched_realloc_reassign "backing replacement must return to the exact source field" 'uncontracted call `_zag_realloc`'

project returned_realloc 2027
printf '%s\n' \
  'struct Buffer { data:*u8 }' \
  'fn bad(source:@borrows_mut *Buffer)*u8 { unsafe { return _zag_realloc(source.*.data as *i8,16) as *u8; } }' \
  'fn main()i32{return 0;}' \
  >"$WORK/returned_realloc/main.zag"
check_reject returned_realloc "backing realloc cannot escape directly through return" 'uncontracted call `_zag_realloc`'

project pointer_projection_return 2027
printf '%s\n' \
  'struct Source { pointer:*u8 } struct PointerSnapshot { pointer:*u8 }' \
  'fn bad(source:@borrows *Source)PointerSnapshot { return PointerSnapshot{.pointer=source.*.pointer}; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/pointer_projection_return/main.zag"
check_reject pointer_projection_return "direct pointer-field snapshots retain borrowed identity" 'cannot escape through return'

project pointer_projection_store 2027
printf '%s\n' \
  'struct Source { pointer:*u8 } struct Sink { pointer:*u8 }' \
  'fn bad(out:@borrows_mut *Sink,source:@borrows *Source)void { out.*.pointer=source.*.pointer; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/pointer_projection_store/main.zag"
check_reject pointer_projection_store "direct pointer fields cannot escape through non-local aggregate stores" 'cannot be stored in a non-local aggregate'

project address_projection_return 2027
printf '%s\n' \
  'struct Source { value:i32 }' \
  'fn bad(source:@borrows *Source)*i32 { return &source.*.value; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/address_projection_return/main.zag"
check_reject address_projection_return "address-of a borrowed field remains tied to the container" 'cannot escape through return'

project address_index_return 2027
printf '%s\n' \
  'struct Buffer { data:**u8, len:i32 }' \
  'fn bad(source:@borrows *Buffer)*u8 { let last:i32=source.*.len-1; return &source.*.data[last]; }' \
  'fn main()i32{return 0;}' \
  >"$WORK/address_index_return/main.zag"
check_reject address_index_return "address-of an indexed borrowed field remains tied to the container" 'cannot escape through return'

echo "param contracts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
