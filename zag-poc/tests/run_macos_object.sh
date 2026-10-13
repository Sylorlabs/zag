#!/usr/bin/env bash
# Full validating CLI -> Zag-lowered MH_OBJECT/BSD archive -> Apple linker ->
# native C/Zag/C ABI execution. Clang is an interoperability oracle only.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS object: requires native Apple Silicon' >&2
    exit 2
fi
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
test -x "$compiler"
command -v xcrun >/dev/null
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-object.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/project"
printf 'name = "macos-object"\nversion = "0"\nedition = "2027"\n' >"$work/project/zag.mod"
cp tests/fixtures/macos_object_library.zag "$work/project/library.zag"
build() {
    zag_run_bounded 240 "$compiler" "$@" --target macos-arm64 \
        --no-zagd --no-analyze --no-foreground-cache
}
for mode in object archive checked; do
    case "$mode" in
        object) args=(--emit-obj); suffix=o ;;
        archive) args=(--emit-static); suffix=a ;;
        checked) args=(--emit-obj --safety=checked); suffix=o ;;
    esac
    build "$work/project/library.zag" "${args[@]}" -o "$work/$mode.$suffix"
    build "$work/project/library.zag" "${args[@]}" -o "$work/$mode-repeat.$suffix"
    cmp "$work/$mode.$suffix" "$work/$mode-repeat.$suffix"
done
file "$work/object.o" | grep -q 'Mach-O 64-bit object arm64'
file "$work/archive.a" | grep -q 'ar archive'
nm "$work/object.o" >"$work/symbols"
otool -rv "$work/object.o" >"$work/relocations"
grep -q 'BR26' "$work/relocations"
grep -q 'PAGE21' "$work/relocations"
grep -q 'PAGOF12' "$work/relocations"
grep -Eq '[[:space:]]T[[:space:]]+_zag_object_answer$' "$work/symbols"
grep -Eq '[[:space:]]T[[:space:]]+__zag_object_prefixed$' "$work/symbols"
grep -Eq '[[:space:]]U[[:space:]]+_cabi_mul3$' "$work/symbols"
if grep -Eq '[[:space:]](_main|_start|_private_value)$' "$work/symbols"; then
    echo 'macOS object: entrypoint or private export leaked' >&2; exit 1
fi
cat >"$work/caller.c" <<'C'
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
int64_t cabi_mul3(int64_t value) { return value * 3; }
#define PARAMS int64_t a0,int64_t a1,int64_t a2,int64_t a3,int64_t a4,int64_t a5, \
    int64_t a6,int64_t a7,int8_t b,uint8_t c,int16_t d,uint16_t e,int32_t f, \
    uint32_t g,int64_t h,uint64_t i,bool j,int64_t *k
int64_t cabi_mixed(PARAMS) {
    if (a0!=1 || a1!=2 || a2!=3 || a3!=4 || a4!=5 || a5!=6 || a6!=7 || a7!=8) return 101;
    if (b!=-7 || c!=251 || d!=-1234 || e!=60000 || f!=-123456 || g!=UINT32_C(4000000000)) return 102;
    if (h!=-INT64_C(9876543210) || i!=UINT64_C(1234567890123) || !j || !k || *k!=42) return 103;
    return 42;
}
extern int64_t zag_object_answer(int64_t);
extern uint8_t _zag_object_prefixed(uint8_t);
extern int64_t zag_object_counter(void);
extern const char *zag_object_literal(void);
extern int64_t zag_object_allocate(void);
extern int64_t zag_object_mixed(PARAMS);
extern int64_t zag_object_internal_call(int64_t *);
int main(void) {
    int64_t value=42;
    if (zag_object_answer(12)!=42 || _zag_object_prefixed(251)!=251) return 1;
    if (zag_object_counter()!=1 || zag_object_counter()!=2) return 2;
    if (strcmp(zag_object_literal(),"native-object")!=0) return 3;
    if (zag_object_allocate()!=42) return 4;
    if (zag_object_mixed(1,2,3,4,5,6,7,8,-7,251,-1234,60000,-123456,
        UINT32_C(4000000000),-INT64_C(9876543210),UINT64_C(1234567890123),true,&value)!=42) return 5;
    if (zag_object_internal_call(&value)!=42) return 6;
    return 0;
}
C
for mode in object archive checked; do
    case "$mode" in archive) suffix=a ;; *) suffix=o ;; esac
    xcrun clang -Wall -Wextra -Werror "$work/caller.c" "$work/$mode.$suffix" -o "$work/$mode-app"
    codesign --verify --deep --strict "$work/$mode-app"
    zag_run_bounded 30 "$work/$mode-app"
done
cp "$work/archive.a" "$work/libzag-object.a"
xcrun clang -Wall -Wextra -Werror "$work/caller.c" -L"$work" -lzag-object -o "$work/indexed-app"
zag_run_bounded 30 "$work/indexed-app"

reject() {
    local label=$1 source=$2
    shift 2
    if build "$source" "$@" -o "$work/rejected-$label" >"$work/$label.log" 2>&1; then
        echo "macOS object: unexpectedly accepted $label" >&2; exit 1
    fi
    test ! -e "$work/rejected-$label"
    grep -Eq 'znc|error|arm64' "$work/$label.log"
}
reject competing "$work/project/library.zag" --emit-obj --emit-static
reject executable "$work/project/library.zag" --emit-obj --dynamic
reject hot "$work/project/library.zag" --emit-obj --hot
reject run "$work/project/library.zag" --emit-obj --run
reject exit-sanitizer "$work/project/library.zag" --emit-obj --sanitize=memory
reject debug "$work/project/library.zag" --emit-obj --debug
reject legacy tests/fixtures/cabi_object_add.zag --emit-obj
printf 'fn main() i32 { return 0; }\n' >"$work/project/no-export.zag"
reject no-export "$work/project/no-export.zag" --emit-obj
cat >"$work/project/float-import.zag" <<'ZAG'
extern fn cabi_scale(value: f64) f64 @cabi;
extern fn cabi_mix(left: f64, bias: i64, right: f64) f64 @cabi;
extern fn cabi_scale32(value: f32) f32 @cabi;
extern fn cabi_mix32(left: f32, bias: i64, right: f32) f32 @cabi;
extern fn cabi_sum10f64(a0:f64,a1:f64,a2:f64,a3:f64,a4:f64,a5:f64,a6:f64,a7:f64,a8:f64,a9:f64) f64 @cabi;
extern fn cabi_sum10f32(a0:f32,a1:f32,a2:f32,a3:f32,a4:f32,a5:f32,a6:f32,a7:f32,a8:f32,a9:f32) f32 @cabi;
pub fn zag_float_import() i64 @cabi_export {
    unsafe {
        let scaled: f64 = cabi_scale(3.0);
        let mixed: f64 = cabi_mix(1.5, 3, 2.5);
        let scaled32: f32 = cabi_scale32(3.0);
        let mixed32: f32 = cabi_mix32(1.5, 3, 2.5);
        let sum64: f64 = cabi_sum10f64(1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0);
        let sum32: f32 = cabi_sum10f32(1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0);
        if (scaled > 5.99 && scaled < 6.01 && mixed > 6.99 && mixed < 7.01 &&
            scaled32 > 5.99 && scaled32 < 6.01 && mixed32 > 6.99 && mixed32 < 7.01 &&
            sum64 > 54.99 && sum64 < 55.01 && sum32 > 54.99 && sum32 < 55.01) { return 42; }
    }
    return 1;
}
ZAG
build "$work/project/float-import.zag" --emit-obj -o "$work/float-import.o"
nm "$work/float-import.o" >"$work/float-symbols"
grep -Eq '[[:space:]]U[[:space:]]+_cabi_scale$' "$work/float-symbols"
grep -Eq '[[:space:]]U[[:space:]]+_cabi_mix$' "$work/float-symbols"
grep -Eq '[[:space:]]U[[:space:]]+_cabi_scale32$' "$work/float-symbols"
grep -Eq '[[:space:]]U[[:space:]]+_cabi_mix32$' "$work/float-symbols"
cat >"$work/float-caller.c" <<'C'
#include <stdint.h>
double cabi_scale(double value) { return value * 2.0; }
double cabi_mix(double left, int64_t bias, double right) { return left + (double)bias + right; }
float cabi_scale32(float value) { return value * 2.0f; }
float cabi_mix32(float left, int64_t bias, float right) { return left + (float)bias + right; }
double cabi_sum10f64(double a0,double a1,double a2,double a3,double a4,double a5,double a6,double a7,double a8,double a9) {
    return a0+a1+a2+a3+a4+a5+a6+a7+a8+a9;
}
float cabi_sum10f32(float a0,float a1,float a2,float a3,float a4,float a5,float a6,float a7,float a8,float a9) {
    return a0+a1+a2+a3+a4+a5+a6+a7+a8+a9;
}
extern int64_t zag_float_import(void);
int main(void) { return zag_float_import() == 42 ? 0 : 1; }
C
xcrun clang -Wall -Wextra -Werror "$work/float-caller.c" "$work/float-import.o" -o "$work/float-app"
codesign --verify --deep --strict "$work/float-app"
zag_run_bounded 30 "$work/float-app"

cat >"$work/project/float-export.zag" <<'ZAG'
pub fn zag_float_export(left: f64, bias: i64, right: f64) f64 @cabi_export {
    return left + (bias as f64) + right;
}
pub fn zag_float32_export(left: f32, bias: i64, right: f32) f32 @cabi_export {
    return left + (bias as f32) + right;
}
pub fn zag_sum10f64(a0:f64,a1:f64,a2:f64,a3:f64,a4:f64,a5:f64,a6:f64,a7:f64,a8:f64,a9:f64) f64 @cabi_export {
    return a0+a1+a2+a3+a4+a5+a6+a7+a8+a9;
}
pub fn zag_sum10f32(a0:f32,a1:f32,a2:f32,a3:f32,a4:f32,a5:f32,a6:f32,a7:f32,a8:f32,a9:f32) f32 @cabi_export {
    return a0+a1+a2+a3+a4+a5+a6+a7+a8+a9;
}
ZAG
build "$work/project/float-export.zag" --emit-obj -o "$work/float-export.o"
cat >"$work/float-export-caller.c" <<'C'
#include <stdint.h>
extern double zag_float_export(double left, int64_t bias, double right);
extern float zag_float32_export(float left, int64_t bias, float right);
extern double zag_sum10f64(double,double,double,double,double,double,double,double,double,double);
extern float zag_sum10f32(float,float,float,float,float,float,float,float,float,float);
int main(void) {
    double got=zag_float_export(1.5,3,2.5);
    float got32=zag_float32_export(1.5f,3,2.5f);
    double sum64=zag_sum10f64(1,2,3,4,5,6,7,8,9,10);
    float sum32=zag_sum10f32(1,2,3,4,5,6,7,8,9,10);
    return (got>6.99 && got<7.01 && got32>6.99f && got32<7.01f &&
        sum64>54.99 && sum64<55.01 && sum32>54.99f && sum32<55.01f) ? 0 : 1;
}
C
xcrun clang -Wall -Wextra -Werror "$work/float-export-caller.c" "$work/float-export.o" -o "$work/float-export-app"
codesign --verify --deep --strict "$work/float-export-app"
zag_run_bounded 30 "$work/float-export-app"

cat >"$work/project/aggregate-indirect.zag" <<'ZAG'
struct Pair2 { x:i64, y:i64 }
struct Pair3 { x:i64, y:i64, z:i64 }
struct Word { value:i64 }
struct Nested2 { head:Word, tail:i64 }
struct Nested3 { pair:Pair2, tail:i64 }
struct Pair32 { first:i32, second:i32 }
struct Mix16 { first:i32, second:i64 }
struct Tiny { first:u8, second:u16, third:u32 }
struct FlagPtr { flag:bool, code:i32, ptr:*i64 }
extern fn cabi_pair2(value:Pair2) Pair2 @cabi;
extern fn cabi_pair2_stack(a0:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64,value:Pair2,tail:i64) i64 @cabi;
extern fn cabi_pair3(value:Pair3) Pair3 @cabi;
extern fn cabi_nested2(value:Nested2) Nested2 @cabi;
extern fn cabi_nested3(value:Nested3) Nested3 @cabi;
extern fn cabi_pair32(value:Pair32) Pair32 @cabi;
extern fn cabi_pair32_stack(a0:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64,value:Pair32,tail:i64) i64 @cabi;
extern fn cabi_mix16(value:Mix16) Mix16 @cabi;
extern fn cabi_mix16_stack(a0:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64,value:Mix16,tail:i64) i64 @cabi;
extern fn cabi_tiny(value:Tiny) Tiny @cabi;
extern fn cabi_flagptr(value:FlagPtr) FlagPtr @cabi;
pub fn zag_pair2_import() i64 @cabi_export {
    let input:Pair2=Pair2{.x=20,.y=20};
    unsafe {
        let out:Pair2=cabi_pair2(input);
        if(out.x==21&&out.y==21){return out.x+out.y;}
    }
    return 1;
}
pub fn zag_pair2_stack_import() i64 @cabi_export {
    let input:Pair2=Pair2{.x=10,.y=20};
    unsafe { return cabi_pair2_stack(1,2,3,4,5,6,7,input,12); }
}
pub fn zag_pair2_export(value:Pair2) Pair2 @cabi_export {
    return Pair2{.x=value.x+1,.y=value.y+1};
}
pub fn zag_pair2_stack_export(a0:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64,value:Pair2,tail:i64) i64 @cabi_export {
    if(a0!=1||a1!=2||a2!=3||a3!=4||a4!=5||a5!=6||a6!=7){return 1;}
    return value.x+value.y+tail;
}
pub fn zag_pair3_import() i64 @cabi_export {
    let input:Pair3=Pair3{.x=10,.y=20,.z=6};
    unsafe {
        let out:Pair3=cabi_pair3(input);
        if(out.x==11&&out.y==22&&out.z==9){return out.x+out.y+out.z;}
    }
    return 1;
}
pub fn zag_pair3_export(value:Pair3) Pair3 @cabi_export {
    return Pair3{.x=value.x+1,.y=value.y+2,.z=value.z+3};
}
pub fn zag_nested_import() i64 @cabi_export {
    unsafe {
        let small:Nested2=cabi_nested2(Nested2{.head=Word{.value=20},.tail=20});
        let large:Nested3=cabi_nested3(Nested3{.pair=Pair2{.x=10,.y=20},.tail=6});
        if(small.head.value==21&&small.tail==21&&
           large.pair.x==11&&large.pair.y==22&&large.tail==9){return 42;}
    }
    return 1;
}
pub fn zag_nested2_export(value:Nested2) Nested2 @cabi_export {
    return Nested2{.head=Word{.value=value.head.value+1},.tail=value.tail+1};
}
pub fn zag_nested3_export(value:Nested3) Nested3 @cabi_export {
    return Nested3{.pair=Pair2{.x=value.pair.x+1,.y=value.pair.y+2},.tail=value.tail+3};
}
pub fn zag_mixed_import() i64 @cabi_export {
    unsafe {
        let pair:Pair32=cabi_pair32(Pair32{.first=-10,.second=40});
        let mix:Mix16=cabi_mix16(Mix16{.first=-5,.second=40});
        let tiny:Tiny=cabi_tiny(Tiny{.first=1,.second=2,.third=36});
        let flagptr:FlagPtr=cabi_flagptr(FlagPtr{.flag=true,.code=7,.ptr=4096 as *i64});
        let pair_stack:i64=cabi_pair32_stack(1,2,3,4,5,6,7,Pair32{.first=10,.second=20},12);
        let mix_stack:i64=cabi_mix16_stack(1,2,3,4,5,6,7,Mix16{.first=10,.second=20},12);
        if(pair.first==-9&&pair.second==42&&mix.first==-2&&mix.second==44&&
           tiny.first==2&&tiny.second==4&&tiny.third==39&&flagptr.flag&&flagptr.code==8&&
           flagptr.ptr==4096 as *i64&&pair_stack==42&&mix_stack==42){return 42;}
    }
    return 1;
}
pub fn zag_pair32_export(value:Pair32) Pair32 @cabi_export {
    return Pair32{.first=value.first+1,.second=value.second+2};
}
pub fn zag_pair32_stack_export(a0:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64,value:Pair32,tail:i64) i64 @cabi_export {
    if(a0!=1||a1!=2||a2!=3||a3!=4||a4!=5||a5!=6||a6!=7){return 1;}
    return (value.first as i64)+(value.second as i64)+tail;
}
pub fn zag_mix16_export(value:Mix16) Mix16 @cabi_export {
    return Mix16{.first=value.first+3,.second=value.second+4};
}
pub fn zag_mix16_stack_export(a0:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64,value:Mix16,tail:i64) i64 @cabi_export {
    if(a0!=1||a1!=2||a2!=3||a3!=4||a4!=5||a5!=6||a6!=7){return 1;}
    return (value.first as i64)+value.second+tail;
}
pub fn zag_tiny_export(value:Tiny) Tiny @cabi_export {
    return Tiny{.first=value.first,.second=value.second,.third=value.third};
}
pub fn zag_flagptr_export(value:FlagPtr) FlagPtr @cabi_export {
    return FlagPtr{.flag=value.flag,.code=value.code+1,.ptr=value.ptr};
}
ZAG
build "$work/project/aggregate-indirect.zag" --emit-obj -o "$work/aggregate-indirect.o"
cat >"$work/aggregate-indirect-caller.c" <<'C'
#include <stdbool.h>
#include <stdint.h>
struct Pair2 { int64_t x; int64_t y; };
struct Pair3 { int64_t x; int64_t y; int64_t z; };
struct Word { int64_t value; };
struct Nested2 { struct Word head; int64_t tail; };
struct Nested3 { struct Pair2 pair; int64_t tail; };
struct Pair32 { int32_t first; int32_t second; };
struct Mix16 { int32_t first; int64_t second; };
struct Tiny { uint8_t first; uint16_t second; uint32_t third; };
struct FlagPtr { bool flag; int32_t code; int64_t *ptr; };
struct Pair2 cabi_pair2(struct Pair2 value) {
    struct Pair2 out={value.x+1,value.y+1};
    return out;
}
int64_t cabi_pair2_stack(int64_t a0,int64_t a1,int64_t a2,int64_t a3,int64_t a4,int64_t a5,int64_t a6,
    struct Pair2 value,int64_t tail) {
    if (a0!=1||a1!=2||a2!=3||a3!=4||a4!=5||a5!=6||a6!=7) return 1;
    return value.x+value.y+tail;
}
struct Pair3 cabi_pair3(struct Pair3 value) {
    struct Pair3 out={value.x+1,value.y+2,value.z+3};
    return out;
}
struct Nested2 cabi_nested2(struct Nested2 value) {
    struct Nested2 out={{value.head.value+1},value.tail+1};
    return out;
}
struct Nested3 cabi_nested3(struct Nested3 value) {
    struct Nested3 out={{value.pair.x+1,value.pair.y+2},value.tail+3};
    return out;
}
struct Pair32 cabi_pair32(struct Pair32 value) {
    struct Pair32 out={value.first+1,value.second+2};
    return out;
}
int64_t cabi_pair32_stack(int64_t a0,int64_t a1,int64_t a2,int64_t a3,int64_t a4,int64_t a5,int64_t a6,
    struct Pair32 value,int64_t tail) {
    if (a0!=1||a1!=2||a2!=3||a3!=4||a4!=5||a5!=6||a6!=7) return 1;
    return (int64_t)value.first+(int64_t)value.second+tail;
}
struct Mix16 cabi_mix16(struct Mix16 value) {
    struct Mix16 out={value.first+3,value.second+4};
    return out;
}
int64_t cabi_mix16_stack(int64_t a0,int64_t a1,int64_t a2,int64_t a3,int64_t a4,int64_t a5,int64_t a6,
    struct Mix16 value,int64_t tail) {
    if (a0!=1||a1!=2||a2!=3||a3!=4||a4!=5||a5!=6||a6!=7) return 1;
    return (int64_t)value.first+value.second+tail;
}
struct Tiny cabi_tiny(struct Tiny value) {
    struct Tiny out={(uint8_t)(value.first+1),(uint16_t)(value.second+2),value.third+3};
    return out;
}
struct FlagPtr cabi_flagptr(struct FlagPtr value) {
    value.code += 1;
    return value;
}
extern int64_t zag_pair2_import(void);
extern int64_t zag_pair2_stack_import(void);
extern struct Pair2 zag_pair2_export(struct Pair2 value);
extern int64_t zag_pair2_stack_export(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,struct Pair2,int64_t);
extern int64_t zag_pair3_import(void);
extern struct Pair3 zag_pair3_export(struct Pair3 value);
extern int64_t zag_nested_import(void);
extern struct Nested2 zag_nested2_export(struct Nested2 value);
extern struct Nested3 zag_nested3_export(struct Nested3 value);
extern int64_t zag_mixed_import(void);
extern struct Pair32 zag_pair32_export(struct Pair32 value);
extern int64_t zag_pair32_stack_export(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,struct Pair32,int64_t);
extern struct Mix16 zag_mix16_export(struct Mix16 value);
extern int64_t zag_mix16_stack_export(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,struct Mix16,int64_t);
extern struct Tiny zag_tiny_export(struct Tiny value);
extern struct FlagPtr zag_flagptr_export(struct FlagPtr value);
int main(void) {
    struct Pair2 input2={20,20};
    struct Pair2 out2=zag_pair2_export(input2);
    struct Pair3 input={10,20,6};
    struct Pair3 out=zag_pair3_export(input);
    struct Nested2 nested2=zag_nested2_export((struct Nested2){{20},20});
    struct Nested3 nested3=zag_nested3_export((struct Nested3){{10,20},6});
    struct Pair32 pair32=zag_pair32_export((struct Pair32){-10,40});
    struct Mix16 mix16=zag_mix16_export((struct Mix16){-5,40});
    struct Tiny tiny=zag_tiny_export((struct Tiny){1,2,36});
    struct FlagPtr flagptr=zag_flagptr_export((struct FlagPtr){true,7,(int64_t *)(uintptr_t)4096});
    if (zag_pair2_import()!=42 || zag_pair2_stack_import()!=42) return 1;
    if (out2.x!=21 || out2.y!=21) return 2;
    if (zag_pair2_stack_export(1,2,3,4,5,6,7,(struct Pair2){10,20},12)!=42) return 3;
    if (zag_pair3_import()!=42) return 1;
    if (!(out.x==11 && out.y==22 && out.z==9)) return 4;
    if (zag_nested_import()!=42) return 5;
    if (nested2.head.value!=21 || nested2.tail!=21) return 6;
    if (nested3.pair.x!=11 || nested3.pair.y!=22 || nested3.tail!=9) return 7;
    if (zag_mixed_import()!=42) return 8;
    if (pair32.first!=-9 || pair32.second!=42) return 9;
    if (zag_pair32_stack_export(1,2,3,4,5,6,7,(struct Pair32){10,20},12)!=42) return 10;
    if (mix16.first!=-2 || mix16.second!=44) return 11;
    if (zag_mix16_stack_export(1,2,3,4,5,6,7,(struct Mix16){10,20},12)!=42) return 12;
    if (tiny.first!=1 || tiny.second!=2 || tiny.third!=36) return 13;
    return (flagptr.flag && flagptr.code==8 && flagptr.ptr==(int64_t *)(uintptr_t)4096) ? 0 : 14;
}
C
xcrun clang -Wall -Wextra -Werror "$work/aggregate-indirect-caller.c" "$work/aggregate-indirect.o" -o "$work/aggregate-indirect-app"
codesign --verify --deep --strict "$work/aggregate-indirect-app"
zag_run_bounded 30 "$work/aggregate-indirect-app"

cat >"$work/project/callback-import.zag" <<'ZAG'
extern fn cabi_apply(value: i64, callback: fn(i64)i64) i64 @cabi;
fn add_nine(value: i64) i64 { return value + 9; }
pub fn zag_callback_import() i64 @cabi_export {
    unsafe { return cabi_apply(33, add_nine); }
}
ZAG
build "$work/project/callback-import.zag" --emit-obj -o "$work/callback-import.o"
cat >"$work/callback-caller.c" <<'C'
#include <stdint.h>
int64_t cabi_apply(int64_t value, int64_t (*callback)(int64_t)) { return callback(value); }
extern int64_t zag_callback_import(void);
int main(void) { return zag_callback_import() == 42 ? 0 : 1; }
C
xcrun clang -Wall -Wextra -Werror "$work/callback-caller.c" "$work/callback-import.o" -o "$work/callback-app"
codesign --verify --deep --strict "$work/callback-app"
zag_run_bounded 30 "$work/callback-app"

cat >"$work/project/float-callback-import.zag" <<'ZAG'
extern fn cabi_apply_float32(value: f32, callback: fn(f32)f32) f32 @cabi;
extern fn cabi_apply_float64(value: f64, callback: fn(f64)f64) f64 @cabi;
extern fn cabi_apply_float_mixed(value: f64, callback: fn(f32,i64,f64)f64) f64 @cabi;
extern fn cabi_apply_float10(callback: fn(f32,f32,f32,f32,f32,f32,f32,f32,f32,f32)f32) f32 @cabi;
pub fn zag_callback32(value: f32) f32 @cabi_export { return value + 1.0; }
pub fn zag_callback64(value: f64) f64 @cabi_export { return value * 2.0; }
pub fn zag_callback_mixed(left: f32, bias: i64, right: f64) f64 @cabi_export {
    return (left as f64) + (bias as f64) + right;
}
pub fn zag_callback10(a0:f32,a1:f32,a2:f32,a3:f32,a4:f32,a5:f32,a6:f32,a7:f32,a8:f32,a9:f32) f32 @cabi_export {
    return a0+a1+a2+a3+a4+a5+a6+a7+a8+a9;
}
pub fn zag_float_callback_import() i64 @cabi_export {
    unsafe {
        let got32: f32 = cabi_apply_float32(41.0, zag_callback32);
        let got64: f64 = cabi_apply_float64(21.0, zag_callback64);
        let mixed: f64 = cabi_apply_float_mixed(2.5, zag_callback_mixed);
        let wide: f32 = cabi_apply_float10(zag_callback10);
        if (got32 > 41.99 && got32 < 42.01 && got64 > 41.99 && got64 < 42.01 &&
            mixed > 6.99 && mixed < 7.01 && wide > 54.99 && wide < 55.01) { return 42; }
    }
    return 1;
}
ZAG
build "$work/project/float-callback-import.zag" --emit-obj -o "$work/float-callback-import.o"
cat >"$work/float-callback-caller.c" <<'C'
#include <stdint.h>
float cabi_apply_float32(float value, float (*callback)(float)) { return callback(value); }
double cabi_apply_float64(double value, double (*callback)(double)) { return callback(value); }
double cabi_apply_float_mixed(double value, double (*callback)(float,int64_t,double)) {
    return callback(1.5f,3,value);
}
float cabi_apply_float10(float (*callback)(float,float,float,float,float,float,float,float,float,float)) {
    return callback(1,2,3,4,5,6,7,8,9,10);
}
extern int64_t zag_float_callback_import(void);
int main(void) { return zag_float_callback_import() == 42 ? 0 : 1; }
C
xcrun clang -Wall -Wextra -Werror "$work/float-callback-caller.c" "$work/float-callback-import.o" -o "$work/float-callback-app"
codesign --verify --deep --strict "$work/float-callback-app"
zag_run_bounded 30 "$work/float-callback-app"

cat >"$work/project/f32-callback.zag" <<'ZAG'
extern fn cabi_apply_float(value: f32, callback: fn(f32)f32) f32 @cabi;
fn identity(value: f32) f32 { return value; }
pub fn answer(value: f32) f32 @cabi_export { unsafe { return cabi_apply_float(value, identity); } }
ZAG
reject f32-callback "$work/project/f32-callback.zag" --emit-obj
cat >"$work/project/aggregate-export.zag" <<'ZAG'
struct MixedLarge { first:i32, second:i64, third:i32 }
pub fn answer(value:MixedLarge) MixedLarge @cabi_export { return value; }
ZAG
reject aggregate-export "$work/project/aggregate-export.zag" --emit-obj
cat >"$work/project/invalid-type.zag" <<'ZAG'
pub fn answer() i64 @cabi_export { let x: NoSuchType = 42; return x; }
ZAG
reject invalid-type "$work/project/invalid-type.zag" --emit-obj
printf 'macOS object: PASS deterministic object/archive, native C/Zag/C packed-stack, bounded-f32/f64 import/export, flat/nested 64-bit-leaf plus flat mixed-width small register/stack and large indirect aggregate import/export, direct scalar callbacks, and explicit-export f32/f64 callbacks, globals, literals, allocator, checked access, index extraction, negative modes\n'
