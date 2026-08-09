#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
WORK="$(mktemp -d /tmp/zag_dynamic_abi.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

if "$ZNC_BIN" tests/dynamic_vulkan_test.zag --dynamic --needed libvulkan.so.1 \
    --no-analyze -o "$WORK/vulkan" >"$WORK/build.log" 2>&1 &&
    readelf -l "$WORK/vulkan" | grep -q 'Requesting program interpreter' &&
    readelf -d "$WORK/vulkan" | grep -q 'libvulkan.so.1'; then
    "$WORK/vulkan"
    rc=$?
    if [ "$rc" = 42 ]; then ok "Vulkan loader call through Zag-emitted dynamic ELF"; else bad "Vulkan call exit=$rc"; fi
else
    bad "dynamic Vulkan build metadata"
    sed -n '1,16p' "$WORK/build.log"
fi

if "$ZNC_BIN" tests/dynamic_vulkan_test.zag --needed libvulkan.so.1 \
    --no-analyze -o "$WORK/no-mode" >"$WORK/no-mode.log" 2>&1; then
    bad "--needed accepted without --dynamic"
else
    grep -q 'requires explicit --dynamic' "$WORK/no-mode.log" && ok "--needed fails closed without --dynamic" || bad "missing --needed diagnostic"
fi

if "$ZNC_BIN" tests/dynamic_vulkan_test.zag --dynamic --needed '../libvulkan.so.1' \
    --no-analyze -o "$WORK/unsafe-name" >"$WORK/unsafe-name.log" 2>&1; then
    bad "unsafe SONAME accepted"
else
    grep -q 'safe shared-library SONAME' "$WORK/unsafe-name.log" && ok "unsafe SONAME rejected" || bad "missing unsafe SONAME diagnostic"
fi

cat >"$WORK/float.zag" <<'ZAG'
extern fn foreign_float(x: f64) f64 @io;
fn main() i32 { let x: f64 = foreign_float(1.0); if (x > 0.0) { return 1; } return 0; }
ZAG
if "$ZNC_BIN" "$WORK/float.zag" --dynamic --needed libm.so.6 \
    --no-analyze -o "$WORK/float" >"$WORK/float.log" 2>&1; then
    bad "unsupported float ABI accepted"
else
    grep -q 'dynamic extern ABI supports scalar integers' "$WORK/float.log" && ok "legacy float ABI remains rejected without @cabi" || bad "missing ABI rejection diagnostic"
fi

# Edition-2027 foreign calls require an explicit C-ABI contract and an unsafe
# call site.  Keep these checks separate from the legacy v1 dynamic loader
# fixture above so a broad extern regression cannot silently weaken v2.
mkdir -p "$WORK/v2-cabi"
printf 'name = "v2cabi"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn getpid() i64 @cabi; fn main() i32 { unsafe { let pid:i64=getpid(); if (pid > 0) { return 42; } } return 1; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o out) >"$WORK/v2-cabi/build.log" 2>&1 && [ -x "$WORK/v2-cabi/out" ]; then
    "$WORK/v2-cabi/out"
    rc=$?
    [ "$rc" = 42 ] && ok "v2 @cabi dynamic integer import executes" || bad "v2 @cabi execution exit=$rc"
else
    bad "v2 @cabi dynamic import build"
    sed -n '1,16p' "$WORK/v2-cabi/build.log"
fi

# SysV AMD64 places f64 arguments and results in independent XMM registers.
# Exercise one, two, and mixed f64/GPR imports through libm; Zag still emits
# the dynamic ELF and native call sequence itself, with libm only at the
# declared C boundary.
printf 'name = "v2cabif64"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn cos(x:f64) f64 @cabi; extern fn pow(x:f64,y:f64) f64 @cabi; extern fn ldexp(x:f64,n:i32) f64 @cabi; fn main() i32 { unsafe { let a:f64=cos(0.0); let b:f64=pow(2.0,3.0); let c:f64=ldexp(1.5,2); if(a>0.99&&b>7.99&&c>5.99){return 42;} return 1; } }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libm.so.6 --no-zagd --no-analyze -o f64) >"$WORK/v2-cabi/f64.log" 2>&1 && [ -x "$WORK/v2-cabi/f64" ]; then
    "$WORK/v2-cabi/f64"
    rc=$?
    [ "$rc" = 42 ] && ok "v2 @cabi f64 XMM imports execute" || bad "v2 @cabi f64 import exit=$rc"
else
    bad "v2 @cabi f64 dynamic import build"
    sed -n '1,20p' "$WORK/v2-cabi/f64.log"
fi

# Exercise the implemented six-register scalar/pointer C-ABI path rather than
# inferring it from the zero-argument getpid witness. `mmap` returns a raw
# pointer and accepts mixed integer/pointer arguments; `munmap` proves the
# returned pointer can cross the same explicitly unsafe outbound boundary.
printf 'name = "v2cabimmap"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn mmap(addr:*u8, len:i64, prot:i32, flags:i32, fd:i32, offset:i64) *u8 @cabi; extern fn munmap(addr:*u8, len:i64) i32 @cabi; fn main() i32 { unsafe { let p:*u8=mmap(null as *u8,4096,3,34,-1,0); if (p == null as *u8) { return 1; } p[0]=42; if (p[0] != 42) { return 2; } if (munmap(p,4096) != 0) { return 3; } return 42; } }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o mmap) >"$WORK/v2-cabi/mmap.log" 2>&1 && [ -x "$WORK/v2-cabi/mmap" ]; then
    "$WORK/v2-cabi/mmap"
    rc=$?
    [ "$rc" = 42 ] && ok "v2 @cabi six-argument pointer import executes" || bad "v2 @cabi mmap execution exit=$rc"
else
    bad "v2 @cabi six-argument pointer import build"
    sed -n '1,16p' "$WORK/v2-cabi/mmap.log"
fi

# Exercise the SysV AMD64 stack-argument path.  `syscall` is declared with a
# fixed seven-integer signature here (the libc symbol is variadic in C, but a
# fixed call with these scalar representations has the same register/stack
# ABI).  The seventh argument is Linux `mmap`'s file offset: an unaligned
# offset must produce libc's `-1` error result, proving the callee consumed the stack word;
# a zero offset then allocates a page which is written and unmapped.  This
# remains a fixed-arity scalar import, not a variadic-ABI claim.
printf 'name = "v2cabistack"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn syscall(n:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64) i64 @cabi; fn main() i32 { unsafe { let bad:i64=syscall(9,0,4096,3,34,-1,1); if(bad != 0-1){return 1;} let p:i64=syscall(9,0,4096,3,34,-1,0); if(p < 4096){return 2;} (p as *u8)[0]=42; let gone:i64=syscall(11,p,4096,0,0,0,0); if(gone != 0){return 3;} return 42; } }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o stack) >"$WORK/v2-cabi/stack.log" 2>&1 && [ -x "$WORK/v2-cabi/stack" ]; then
    "$WORK/v2-cabi/stack"
    rc=$?
    [ "$rc" = 42 ] && ok "v2 @cabi seven-argument stack import executes" || bad "v2 @cabi stack import exit=$rc"
else
    bad "v2 @cabi seven-argument stack import build"
    sed -n '1,16p' "$WORK/v2-cabi/stack.log"
fi

# Validate named struct-by-value arguments. We use a temporary C library with
# `libaggcabi.so.1` exporting `Pair3 add_pair3(Pair3)`; this exercises the C-ABI
# aggregate path in checker + lowering while remaining a minimal symbol contract.
cat >"$WORK/v2-cabi/agg_lib.c" <<'C'
#include <stdint.h>
struct Pair3 { int64_t x; int64_t y; int64_t z; };
struct Pair3 add_pair3(struct Pair3 p) {
    struct Pair3 q;
    q.x = p.x + 1;
    q.y = p.y + 2;
    q.z = p.z + 3;
    return q;
}
long consume_pair3(struct Pair3 p) {
    struct Pair3 q = add_pair3(p);
    return q.x + q.y + q.z;
}
C
if gcc -fPIC -shared -Wl,-soname,libaggcabi.so.1 -o "$WORK/v2-cabi/libaggcabi.so.1" "$WORK/v2-cabi/agg_lib.c"; then
    ln -sf libaggcabi.so.1 "$WORK/v2-cabi/libaggcabi.so"
    printf 'struct Pair3 { x: i64, y: i64, z: i64 }\n' >"$WORK/v2-cabi/main.zag"
    printf 'extern fn consume_pair3(p: Pair3) i64 @cabi; fn main() i32 { let p:Pair3=Pair3{.x=10,.y=20,.z=6}; unsafe { let value:i64=consume_pair3(p); if (value == 42) { return 42; } } return 1; }\n' >>"$WORK/v2-cabi/main.zag"
    if (cd "$WORK/v2-cabi" && LD_LIBRARY_PATH="$WORK/v2-cabi" "$ZNC_BIN" main.zag --dynamic --needed libaggcabi.so.1 --no-zagd --no-analyze -o agg3) >"$WORK/v2-cabi/agg3.log" 2>&1 && [ -x "$WORK/v2-cabi/agg3" ]; then
        if (cd "$WORK/v2-cabi" && LD_LIBRARY_PATH="$WORK/v2-cabi" ./agg3); then rc=$?; else rc=$?; fi
        [ "$rc" = 42 ] && ok "v2 @cabi struct-by-value import executes" || bad "v2 @cabi struct import exit=$rc"
    else
        bad "v2 @cabi struct-by-value import build"
        sed -n '1,24p' "$WORK/v2-cabi/agg3.log"
    fi
else
    bad "v2 @cabi struct-by-value library build"
    sed -n '1,24p' "$WORK/v2-cabi/agg_lib.c"
fi

# Foreign calls can be nested under an assignment while the destination base
# remains on Zag's evaluation stack. The lowering must realign rsp before the
# C call and restore that exact expression-stack pointer afterwards.
cat >"$WORK/v2-cabi/alignment_lib.c" <<'C'
#include <stdint.h>
__attribute__((naked)) int64_t cabi_entry_stack_mod16(int64_t ignored) {
    __asm__("mov %rsp, %rax; and $15, %rax; ret");
}
int64_t cabi_nine(int64_t a, int64_t b, int64_t c, int64_t d,
                  int64_t e, int64_t f, int64_t g, int64_t h, int64_t i) {
    return a + b * 10 + c * 100 + d * 1000 + e * 10000 +
        f * 100000 + g * 1000000 + h * 10000000 + i * 100000000;
}
C
if gcc -fPIC -shared -Wl,-soname,libcabialign.so.1 -o "$WORK/v2-cabi/libcabialign.so.1" "$WORK/v2-cabi/alignment_lib.c"; then
    printf 'struct AlignBox { entry_mod: i64, nine: i64, guard: i64 }\n' >"$WORK/v2-cabi/main.zag"
    printf 'extern fn cabi_entry_stack_mod16(ignored:i64)i64 @cabi; extern fn cabi_nine(a:i64,b:i64,c:i64,d:i64,e:i64,f:i64,g:i64,h:i64,i:i64)i64 @cabi; fn make_box() AlignBox { let box:AlignBox=AlignBox{.entry_mod=0,.nine=0,.guard=42}; unsafe { box.entry_mod=cabi_entry_stack_mod16(0); box.nine=cabi_nine(1,2,3,4,5,6,7,8,9); } return box; } fn main()i32 { let box:AlignBox=make_box(); if(box.entry_mod==8&&box.nine==987654321&&box.guard==42){return 42;} return 1; }\n' >>"$WORK/v2-cabi/main.zag"
    if (cd "$WORK/v2-cabi" && LD_LIBRARY_PATH="$WORK/v2-cabi" "$ZNC_BIN" main.zag --dynamic --needed libcabialign.so.1 --no-zagd --no-analyze -o align-call) >"$WORK/v2-cabi/align-call.log" 2>&1 && [ -x "$WORK/v2-cabi/align-call" ]; then
        if (cd "$WORK/v2-cabi" && LD_LIBRARY_PATH="$WORK/v2-cabi" ./align-call); then
            rc=$?
        else
            rc=$?
        fi
        [ "$rc" = 42 ] && ok "nested v2 C calls preserve SysV alignment, stack args, and expression stack" || bad "nested C call alignment/stack-arg exit=$rc"
    else
        bad "nested C call alignment build"
        sed -n '1,20p' "$WORK/v2-cabi/align-call.log"
    fi
else
    bad "nested C call alignment library build"
fi

# A bounded bidirectional ABI witness: libc `qsort` calls a direct named Zag
# comparator. The callback is passed as one SysV code pointer, not Zag's normal
# `{code, environment}` function-value representation. Its scalar/pointer
# signature is exact and it is valid for the executable's whole lifetime.
printf 'name = "v2cabicallback"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn qsort(base:*i64,n:i64,size:i64,cmp:fn(*i64,*i64)i32) void @cabi @borrows_mut; fn compare(a:*i64,b:*i64) i32 { unsafe { if(a.* < b.*){return -1;} if(a.* > b.*){return 1;} return 0; } } fn main() i32 { unsafe { let p:*i64=_zag_malloc(24) as *i64; p[0]=9; p[1]=2; p[2]=5; qsort(p,3,8,compare); let ok:i32=((p[0]==2)&&(p[1]==5)&&(p[2]==9)) as i32; _zag_free(p); if(ok==1){return 42;} return 1; } }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o callback) >"$WORK/v2-cabi/callback.log" 2>&1 && [ -x "$WORK/v2-cabi/callback" ]; then
    "$WORK/v2-cabi/callback"
    rc=$?
    [ "$rc" = 42 ] && ok "v2 @cabi direct Zag callback executes through libc qsort" || bad "v2 @cabi callback exit=$rc"
else
    bad "v2 @cabi callback build"
    sed -n '1,20p' "$WORK/v2-cabi/callback.log"
fi

# The callback rule intentionally rejects aliases and captures. Either would
# require a distinct ownership/effect/lifetime contract, and the latter would
# otherwise leak the Zag fat-function environment pointer into C.
printf 'extern fn qsort(base:*i64,n:i64,size:i64,cmp:fn(*i64,*i64)i32) void @cabi @borrows_mut; fn compare(a:*i64,b:*i64) i32 { return 0; } fn main() i32 { unsafe { let p:*i64=_zag_malloc(8) as *i64; let alias:fn(*i64,*i64)i32=compare; qsort(p,1,8,alias); _zag_free(p); return 0; } }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o callback-alias) >"$WORK/v2-cabi/callback-alias.log" 2>&1; then
    bad "v2 @cabi callback alias accepted"
else
    grep -q 'direct captureless function with an exact scalar/pointer signature' "$WORK/v2-cabi/callback-alias.log" && ok "v2 @cabi callback alias fails closed" || bad "missing callback-alias diagnostic"
fi

printf 'extern fn qsort(base:*i64,n:i64,size:i64,cmp:fn(*i64,*i64)i32) void @cabi @borrows_mut; fn main() i32 { unsafe { let p:*i64=_zag_malloc(8) as *i64; let bias:i64=0; let captured:fn(*i64,*i64)i32=fn[bias](a:*i64,b:*i64)i32 { return bias as i32; }; qsort(p,1,8,captured); _zag_free(p); return 0; } }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o callback-captured) >"$WORK/v2-cabi/callback-captured.log" 2>&1; then
    bad "v2 @cabi captured callback accepted"
else
    # Current ownership checking rejects the captured closure before dynamic
    # lowering; if that ordering changes, lowering must still reject it rather
    # than passing Zag's `{code,env}` value to C.
    grep -Eq 'direct captureless function with an exact scalar/pointer signature|owned allocation `captured`' "$WORK/v2-cabi/callback-captured.log" && ok "v2 @cabi captured callback fails closed" || bad "missing captured-callback diagnostic"
fi

printf 'name = "v2bareextern"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn getpid() i64; fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o bare) >"$WORK/v2-cabi/bare.log" 2>&1; then
    bad "v2 bare extern accepted"
else
    grep -q 'v2 foreign imports require explicit @cabi' "$WORK/v2-cabi/bare.log" && ok "v2 bare extern rejects without @cabi" || bad "missing @cabi requirement diagnostic"
fi

printf 'extern fn getpid() i64 @cabi; fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o nodynamic) >"$WORK/v2-cabi/nodynamic.log" 2>&1; then
    bad "v2 @cabi accepted without dynamic mode"
else
    grep -q 'v2 @cabi imports require --dynamic' "$WORK/v2-cabi/nodynamic.log" && ok "v2 @cabi rejects without dynamic mode" || bad "missing dynamic-mode diagnostic"
fi

# `--emit-obj` has a real i686 ET_REL path, but it is not evidence for the
# native x86-64 v2 C ABI.  A v2 @cabi declaration must fail before that target
# can emit an apparently-C-compatible object.
printf 'extern fn getpid() i64 @cabi; fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --target i686 --emit-obj --no-zagd --no-analyze -o foreign.o) >"$WORK/v2-cabi/i686.log" 2>&1 || [ -e "$WORK/v2-cabi/foreign.o" ]; then
    bad "v2 @cabi emitted non-native object"
else
    grep -q 'supported only for native x86-64 --dynamic' "$WORK/v2-cabi/i686.log" && ok "v2 @cabi rejects non-native object target" || bad "missing non-native ABI diagnostic"
fi

# x86-64 `--emit-obj` is deliberately narrower than the general executable
# path: it requires an explicit v2 `@cabi_export`, so an ordinary public
# function must still fail before artifact creation.
printf 'pub fn exported_answer() i64 { return 42; } fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --emit-obj --no-zagd --no-analyze -o native.o) >"$WORK/v2-cabi/native-object.log" 2>&1 || [ -e "$WORK/v2-cabi/native.o" ]; then
    bad "native x86-64 emitted a misleading object artifact"
else
    grep -q 'requires at least one pub fn annotated @cabi_export' "$WORK/v2-cabi/native-object.log" && ok "native x86-64 object request fails closed" || bad "missing native object diagnostic"
fi

# A shared-object request is also unsupported: it must not be ignored and
# silently fall through to the ET_EXEC writer.
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --emit-shared --no-zagd --no-analyze -o native.so) >"$WORK/v2-cabi/native-shared.log" 2>&1 || [ -e "$WORK/v2-cabi/native.so" ]; then
    bad "native x86-64 emitted a misleading shared-object artifact"
else
    grep -q 'v2 compiler option is not implemented: --emit-shared' "$WORK/v2-cabi/native-shared.log" && ok "native x86-64 shared-object request fails closed" || bad "missing native shared-object diagnostic"
fi

# Common shared/library spellings must be equally explicit.  None currently
# names an implemented object format, so accepting one as ET_EXEC would lie
# about its ABI just as --emit-shared did.
for shared_flag in --shared --emit-dylib --emit-lib --emit=shared; do
    shared_name=$(printf '%s' "$shared_flag" | tr -cd '[:alnum:]')
    if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag "$shared_flag" --no-zagd --no-analyze -o "$shared_name.out") >"$WORK/v2-cabi/$shared_name.log" 2>&1 || [ -e "$WORK/v2-cabi/$shared_name.out" ]; then
        bad "$shared_flag emitted a misleading output artifact"
    elif grep -q "v2 compiler option is not implemented: $shared_flag" "$WORK/v2-cabi/$shared_name.log"; then
        ok "$shared_flag fails closed"
    else
        bad "$shared_flag missing output-mode diagnostic"
    fi
done

# Symbol-export controls are equally unavailable without an x86-64 symbol
# table and public ABI. They must not make `pub fn` look externally callable.
for export_flag in --export --export-dynamic --export-symbol=exported_answer; do
    export_name=$(printf '%s' "$export_flag" | tr -cd '[:alnum:]')
    if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag "$export_flag" --no-zagd --no-analyze -o "$export_name.out") >"$WORK/v2-cabi/$export_name.log" 2>&1 || [ -e "$WORK/v2-cabi/$export_name.out" ]; then
        bad "$export_flag emitted a misleading export artifact"
    elif grep -q "v2 compiler option is not implemented: $export_flag" "$WORK/v2-cabi/$export_name.log"; then
        ok "$export_flag fails closed"
    else
        bad "$export_flag missing export diagnostic"
    fi
done
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --export-symbol exported_answer --no-zagd --no-analyze -o split-export.out) >"$WORK/v2-cabi/split-export.log" 2>&1 || [ -e "$WORK/v2-cabi/split-export.out" ]; then
    bad "split --export-symbol emitted a misleading export artifact"
elif grep -q 'v2 compiler option is not implemented: --export-symbol' "$WORK/v2-cabi/split-export.log"; then
    ok "split --export-symbol fails closed"
else
    bad "split --export-symbol missing export diagnostic"
fi

# Object aliases, PIE, loader-path, rpath/soname, and archive-selection flags
# would change ELF/link semantics. The native writer cannot implement those
# requests by falling through to its ordinary ET_EXEC output.
for linker_flag in --emit-object --emit=obj -c --pie -pie --whole-archive --no-whole-archive \
                   --dynamic-linker=/lib/ld-linux-x86-64.so.2 --rpath=/tmp/zag --soname=libzag.so; do
    linker_name=$(printf '%s' "$linker_flag" | tr -cd '[:alnum:]')
    if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag "$linker_flag" --no-zagd --no-analyze -o "$linker_name.out") >"$WORK/v2-cabi/$linker_name.log" 2>&1 || [ -e "$WORK/v2-cabi/$linker_name.out" ]; then
        bad "$linker_flag emitted a misleading linker artifact"
    elif grep -q "v2 compiler option is not implemented: $linker_flag" "$WORK/v2-cabi/$linker_name.log"; then
        ok "$linker_flag fails closed"
    else
        bad "$linker_flag missing linker-option diagnostic"
    fi
done

echo "════ dynamic ABI pass=$pass fail=$fail ════"
[ "$fail" = 0 ]
