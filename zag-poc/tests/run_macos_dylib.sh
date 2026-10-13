#!/usr/bin/env bash
# Production validating CLI -> Zag's native linker/signer -> dyld execution.
# Apple clang builds only the independent C interoperability fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then exit 2; fi
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
case "$compiler" in /*) ;; *) compiler="$PWD/$compiler" ;; esac
test -x "$compiler"
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-dylib.XXXXXX")
# Relative compiler inputs use the physical cwd. Compare them to that same
# absolute directory, not a different /var -> /private/var symlink spelling:
# explicit runtime search directories must retain their caller-selected alias.
# The redundant //./ test below independently checks lexical normalization.
work=$(cd "$work" && pwd -P)
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ] || [ "${ZAG_TEST_KEEP_WORK:-0}" = 1 ]; then
        printf 'macOS dylib: retained test artifacts: %s\n' "$work" >&2
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
mkdir -p "$work/project/src" "$work/libs" "$work/bin" "$work/relocated"
printf 'name = "dylib"\nversion = "0"\nedition = "2027"\n' >"$work/project/zag.mod"
cp tests/fixtures/macos_object_library.zag "$work/project/src/library.zag"
build() {
    zag_run_bounded 240 "$compiler" "$@" --target macos-arm64 \
        --no-zagd --no-analyze --no-foreground-cache
}
cat >"$work/helper.c" <<'C'
#include <stdbool.h>
#include <stdint.h>
int64_t cabi_mul3(int64_t value) { return value * 3; }
int64_t cabi_mixed(int64_t a0,int64_t a1,int64_t a2,int64_t a3,int64_t a4,int64_t a5,
    int64_t a6,int64_t a7,int8_t b,uint8_t c,int16_t d,uint16_t e,int32_t f,
    uint32_t g,int64_t h,uint64_t i,bool j,int64_t *k) {
    if (a0!=1 || a1!=2 || a2!=3 || a3!=4 || a4!=5 || a5!=6 || a6!=7 || a7!=8) return 101;
    if (b!=-7 || c!=251 || d!=-1234 || e!=60000 || f!=-123456 || g!=UINT32_C(4000000000)) return 102;
    if (h!=-INT64_C(9876543210) || i!=UINT64_C(1234567890123) || !j || !k || *k!=42) return 103;
    return 42;
}
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
int64_t cabi_apply(int64_t value, int64_t (*callback)(int64_t)) { return callback(value); }
float cabi_apply_float32(float value, float (*callback)(float)) { return callback(value); }
double cabi_apply_float64(double value, double (*callback)(double)) { return callback(value); }
double cabi_apply_float_mixed(double value, double (*callback)(float,int64_t,double)) {
    return callback(1.5f,3,value);
}
float cabi_apply_float10(float (*callback)(float,float,float,float,float,float,float,float,float,float)) {
    return callback(1,2,3,4,5,6,7,8,9,10);
}
C
xcrun clang -Wall -Wextra -Werror -dynamiclib "$work/helper.c" \
    -Wl,-install_name,@rpath/libhelper.dylib -o "$work/libs/libhelper.dylib"
cat >"$work/loader.c" <<'C'
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef int64_t (*mixed_fn)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,
    int8_t,uint8_t,int16_t,uint16_t,int32_t,uint32_t,int64_t,uint64_t,bool,int64_t *);
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*answer)(int64_t)=(int64_t(*)(int64_t))dlsym(lib,"zag_object_answer");
    uint8_t (*prefixed)(uint8_t)=(uint8_t(*)(uint8_t))dlsym(lib,"_zag_object_prefixed");
    int64_t (*counter)(void)=(int64_t(*)(void))dlsym(lib,"zag_object_counter");
    char *(*literal)(void)=(char *(*)(void))dlsym(lib,"zag_object_literal");
    int64_t (*allocate)(void)=(int64_t(*)(void))dlsym(lib,"zag_object_allocate");
    int64_t (*internal)(int64_t *)=(int64_t(*)(int64_t *))dlsym(lib,"zag_object_internal_call");
    mixed_fn mixed=(mixed_fn)dlsym(lib,"zag_object_mixed");
    int64_t value=42;
    if (!answer || !prefixed || !counter || !literal || !allocate || !internal || !mixed) return 4;
    if (answer(12)!=42 || prefixed(251)!=251 || counter()!=1 || counter()!=2) return 5;
    if (strcmp(literal(),"native-object") || allocate()!=42 || internal(&value)!=42) return 6;
    if (mixed(1,2,3,4,5,6,7,8,-7,251,-1234,60000,-123456,UINT32_C(4000000000),
        -INT64_C(9876543210),UINT64_C(1234567890123),true,&value)!=42) return 7;
    if (dlsym(lib,"private_value") || dlsym(lib,"main")) return 8;
    if (dlclose(lib)!=0) return 9;
    return 0;
}
C
xcrun clang -Wall -Wextra -Werror "$work/loader.c" -o "$work/loader"
for mode in ordinary checked; do
    args=(--emit-dylib)
    if [ "$mode" = checked ]; then args+=(--safety=checked); fi
    for suffix in first repeat; do
        build "$work/project/src/library.zag" "${args[@]}" \
            -L "$work/libs" -l helper --install-name @rpath/libzag-library.dylib \
            -o "$work/$mode-$suffix.dylib"
    done
    cmp "$work/$mode-first.dylib" "$work/$mode-repeat.dylib"
    file -b "$work/$mode-first.dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'
    codesign --verify --deep --strict "$work/$mode-first.dylib"
    otool -D "$work/$mode-first.dylib" | grep -Fxq '@rpath/libzag-library.dylib'
    otool -l "$work/$mode-first.dylib" >"$work/load-commands"
    if grep -q LC_MAIN "$work/load-commands"; then echo 'dylib has process entrypoint' >&2; exit 1; fi
    grep -q LC_RPATH "$work/load-commands"
    zag_run_bounded 30 "$work/loader" "$work/$mode-first.dylib"
done
build "$work/project/src/library.zag" --emit-shared --needed="$work/libs/libhelper.dylib" \
    --install-name=@rpath/libzag-library.dylib -o "$work/alias.dylib"
cmp "$work/ordinary-first.dylib" "$work/alias.dylib"
build "$work/project/src/library.zag" --emit-dylib \
    --needed="$work/libs//./libhelper.dylib" -L "$work/libs" -l helper \
    --install-name=@rpath/libzag-library.dylib -o "$work/normalized.dylib"
cmp "$work/ordinary-first.dylib" "$work/normalized.dylib"
(cd "$work" && build "$work/project/src/library.zag" --emit-dylib \
    --needed ./libs/libhelper.dylib --install-name @rpath/libzag-library.dylib \
    -o "$work/relative.dylib")
cmp "$work/ordinary-first.dylib" "$work/relative.dylib"
build "$work/project/src/library.zag" --emit-dylib -L "$work/libs" -l helper \
    -o "$work/libdefault.dylib"
otool -D "$work/libdefault.dylib" | grep -Fxq '@rpath/libdefault.dylib'

cat >"$work/project/src/app.zag" <<'ZAG'
extern fn cabi_mul3(value: i64) i64 @cabi;
fn main() i32 { unsafe { if (cabi_mul3(14) == 42) { _zag_println("linked-app-ok"); return 0; } } return 1; }
ZAG
for form in named needed equal; do
    case "$form" in
        named) args=(-L"$work/libs" -lhelper) ;;
        needed) args=(--needed "$work/libs/libhelper.dylib") ;;
        equal) args=(--needed=libhelper.dylib -L "$work/libs") ;;
    esac
    build "$work/project/src/app.zag" --dynamic "${args[@]}" -o "$work/bin/$form"
    zag_assert_native_executable "$work/bin/$form"
    test "$(zag_run_bounded 30 "$work/bin/$form")" = linked-app-ok
done

# The custom linker shares the same Apple C call lowering as object output.
# Prove independent integer/FP argument banks and f32/f64 return values against
# a real linked dylib.
cat >"$work/project/src/float-app.zag" <<'ZAG'
extern fn cabi_scale(value: f64) f64 @cabi;
extern fn cabi_mix(left: f64, bias: i64, right: f64) f64 @cabi;
extern fn cabi_scale32(value: f32) f32 @cabi;
extern fn cabi_mix32(left: f32, bias: i64, right: f32) f32 @cabi;
extern fn cabi_sum10f64(a0:f64,a1:f64,a2:f64,a3:f64,a4:f64,a5:f64,a6:f64,a7:f64,a8:f64,a9:f64) f64 @cabi;
extern fn cabi_sum10f32(a0:f32,a1:f32,a2:f32,a3:f32,a4:f32,a5:f32,a6:f32,a7:f32,a8:f32,a9:f32) f32 @cabi;
fn main() i32 {
    unsafe {
        let scaled: f64 = cabi_scale(3.0);
        let mixed: f64 = cabi_mix(1.5, 3, 2.5);
        let scaled32: f32 = cabi_scale32(3.0);
        let mixed32: f32 = cabi_mix32(1.5, 3, 2.5);
        let sum64: f64 = cabi_sum10f64(1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0);
        let sum32: f32 = cabi_sum10f32(1.0,2.0,3.0,4.0,5.0,6.0,7.0,8.0,9.0,10.0);
        if (scaled > 5.99 && scaled < 6.01 && mixed > 6.99 && mixed < 7.01 &&
            scaled32 > 5.99 && scaled32 < 6.01 && mixed32 > 6.99 && mixed32 < 7.01 &&
            sum64 > 54.99 && sum64 < 55.01 && sum32 > 54.99 && sum32 < 55.01) { return 0; }
    }
    return 1;
}
ZAG
build "$work/project/src/float-app.zag" --dynamic -L "$work/libs" -l helper -o "$work/bin/float-app"
zag_run_bounded 30 "$work/bin/float-app"

cat >"$work/project/src/aggregate-app.zag" <<'ZAG'
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
fn main() i32 {
    let input2:Pair2=Pair2{.x=20,.y=20};
    let input:Pair3=Pair3{.x=10,.y=20,.z=6};
    unsafe {
        let out2:Pair2=cabi_pair2(input2);
        let out:Pair3=cabi_pair3(input);
        let nested2:Nested2=cabi_nested2(Nested2{.head=Word{.value=20},.tail=20});
        let nested3:Nested3=cabi_nested3(Nested3{.pair=Pair2{.x=10,.y=20},.tail=6});
        let stack:i64=cabi_pair2_stack(1,2,3,4,5,6,7,Pair2{.x=10,.y=20},12);
        let pair32:Pair32=cabi_pair32(Pair32{.first=-10,.second=40});
        let mix16:Mix16=cabi_mix16(Mix16{.first=-5,.second=40});
        let tiny:Tiny=cabi_tiny(Tiny{.first=1,.second=2,.third=36});
        let flagptr:FlagPtr=cabi_flagptr(FlagPtr{.flag=true,.code=7,.ptr=4096 as *i64});
        let pair32_stack:i64=cabi_pair32_stack(1,2,3,4,5,6,7,Pair32{.first=10,.second=20},12);
        let mix16_stack:i64=cabi_mix16_stack(1,2,3,4,5,6,7,Mix16{.first=10,.second=20},12);
        if(out2.x==21&&out2.y==21&&stack==42&&out.x==11&&out.y==22&&out.z==9&&
           nested2.head.value==21&&nested2.tail==21&&nested3.pair.x==11&&nested3.pair.y==22&&nested3.tail==9&&
           pair32.first==-9&&pair32.second==42&&pair32_stack==42&&
           mix16.first==-2&&mix16.second==44&&mix16_stack==42&&
           tiny.first==2&&tiny.second==4&&tiny.third==39&&flagptr.flag&&flagptr.code==8&&
           flagptr.ptr==4096 as *i64){return 0;}
    }
    return 1;
}
ZAG
build "$work/project/src/aggregate-app.zag" --dynamic -L "$work/libs" -l helper -o "$work/bin/aggregate-app"
zag_run_bounded 30 "$work/bin/aggregate-app"

cat >"$work/project/src/float-export.zag" <<'ZAG'
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
build "$work/project/src/float-export.zag" --emit-dylib \
    --install-name @rpath/libzag-float-export.dylib -o "$work/float-export.dylib"
cat >"$work/float-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
    if (!lib) return 3;
    double (*fn)(double,int64_t,double)=(double(*)(double,int64_t,double))dlsym(lib,"zag_float_export");
    float (*fn32)(float,int64_t,float)=(float(*)(float,int64_t,float))dlsym(lib,"zag_float32_export");
    double (*sum64)(double,double,double,double,double,double,double,double,double,double)=
        (double(*)(double,double,double,double,double,double,double,double,double,double))dlsym(lib,"zag_sum10f64");
    float (*sum32)(float,float,float,float,float,float,float,float,float,float)=
        (float(*)(float,float,float,float,float,float,float,float,float,float))dlsym(lib,"zag_sum10f32");
    if (!fn || !fn32 || !sum64 || !sum32) return 4;
    double got=fn(1.5,3,2.5);
    float got32=fn32(1.5f,3,2.5f);
    double wide64=sum64(1,2,3,4,5,6,7,8,9,10);
    float wide32=sum32(1,2,3,4,5,6,7,8,9,10);
    if (!(got>6.99 && got<7.01 && got32>6.99f && got32<7.01f &&
        wide64>54.99 && wide64<55.01 && wide32>54.99f && wide32<55.01f)) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -Wall -Wextra -Werror "$work/float-loader.c" -o "$work/float-loader"
zag_run_bounded 30 "$work/float-loader" "$work/float-export.dylib"

cat >"$work/project/src/aggregate-export.zag" <<'ZAG'
struct Pair2 { x:i64, y:i64 }
struct Pair3 { x:i64, y:i64, z:i64 }
struct Word { value:i64 }
struct Nested2 { head:Word, tail:i64 }
struct Nested3 { pair:Pair2, tail:i64 }
struct Pair32 { first:i32, second:i32 }
struct Mix16 { first:i32, second:i64 }
struct Tiny { first:u8, second:u16, third:u32 }
struct FlagPtr { flag:bool, code:i32, ptr:*i64 }
pub fn zag_pair2_export(value:Pair2) Pair2 @cabi_export {
    return Pair2{.x=value.x+1,.y=value.y+1};
}
pub fn zag_pair2_stack_export(a0:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64,value:Pair2,tail:i64) i64 @cabi_export {
    if(a0!=1||a1!=2||a2!=3||a3!=4||a4!=5||a5!=6||a6!=7){return 1;}
    return value.x+value.y+tail;
}
pub fn zag_pair3_export(value:Pair3) Pair3 @cabi_export {
    return Pair3{.x=value.x+1,.y=value.y+2,.z=value.z+3};
}
pub fn zag_nested2_export(value:Nested2) Nested2 @cabi_export {
    return Nested2{.head=Word{.value=value.head.value+1},.tail=value.tail+1};
}
pub fn zag_nested3_export(value:Nested3) Nested3 @cabi_export {
    return Nested3{.pair=Pair2{.x=value.pair.x+1,.y=value.pair.y+2},.tail=value.tail+3};
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
build "$work/project/src/aggregate-export.zag" --emit-dylib \
    --install-name @rpath/libzag-aggregate-export.dylib -o "$work/aggregate-export.dylib"
cat >"$work/aggregate-loader.c" <<'C'
#include <dlfcn.h>
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
typedef struct Pair2 (*pair2_fn)(struct Pair2);
typedef int64_t (*pair2_stack_fn)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,struct Pair2,int64_t);
typedef struct Pair3 (*pair3_fn)(struct Pair3);
typedef struct Nested2 (*nested2_fn)(struct Nested2);
typedef struct Nested3 (*nested3_fn)(struct Nested3);
typedef struct Pair32 (*pair32_fn)(struct Pair32);
typedef int64_t (*pair32_stack_fn)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,struct Pair32,int64_t);
typedef struct Mix16 (*mix16_fn)(struct Mix16);
typedef int64_t (*mix16_stack_fn)(int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,int64_t,struct Mix16,int64_t);
typedef struct Tiny (*tiny_fn)(struct Tiny);
typedef struct FlagPtr (*flagptr_fn)(struct FlagPtr);
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
    if (!lib) return 3;
    pair2_fn fn2=(pair2_fn)dlsym(lib,"zag_pair2_export");
    pair2_stack_fn stack=(pair2_stack_fn)dlsym(lib,"zag_pair2_stack_export");
    pair3_fn fn=(pair3_fn)dlsym(lib,"zag_pair3_export");
    nested2_fn nested2_fn_ptr=(nested2_fn)dlsym(lib,"zag_nested2_export");
    nested3_fn nested3_fn_ptr=(nested3_fn)dlsym(lib,"zag_nested3_export");
    pair32_fn pair32=(pair32_fn)dlsym(lib,"zag_pair32_export");
    pair32_stack_fn pair32_stack=(pair32_stack_fn)dlsym(lib,"zag_pair32_stack_export");
    mix16_fn mix16=(mix16_fn)dlsym(lib,"zag_mix16_export");
    mix16_stack_fn mix16_stack=(mix16_stack_fn)dlsym(lib,"zag_mix16_stack_export");
    tiny_fn tiny=(tiny_fn)dlsym(lib,"zag_tiny_export");
    flagptr_fn flagptr=(flagptr_fn)dlsym(lib,"zag_flagptr_export");
    if (!fn2 || !stack || !fn || !nested2_fn_ptr || !nested3_fn_ptr ||
        !pair32 || !pair32_stack || !mix16 || !mix16_stack || !tiny || !flagptr) return 4;
    struct Pair2 input2={20,20};
    struct Pair2 out2=fn2(input2);
    struct Pair3 input={10,20,6};
    struct Pair3 out=fn(input);
    struct Nested2 nested2=nested2_fn_ptr((struct Nested2){{20},20});
    struct Nested3 nested3=nested3_fn_ptr((struct Nested3){{10,20},6});
    struct Pair32 pair32_out=pair32((struct Pair32){-10,40});
    struct Mix16 mix16_out=mix16((struct Mix16){-5,40});
    struct Tiny tiny_out=tiny((struct Tiny){1,2,36});
    struct FlagPtr flagptr_out=flagptr((struct FlagPtr){true,7,(int64_t *)(uintptr_t)4096});
    if (!(out2.x==21 && out2.y==21)) return 5;
    if (stack(1,2,3,4,5,6,7,(struct Pair2){10,20},12)!=42) return 6;
    if (!(out.x==11 && out.y==22 && out.z==9)) return 7;
    if (nested2.head.value!=21 || nested2.tail!=21) return 8;
    if (nested3.pair.x!=11 || nested3.pair.y!=22 || nested3.tail!=9) return 9;
    if (pair32_out.first!=-9 || pair32_out.second!=42) return 10;
    if (pair32_stack(1,2,3,4,5,6,7,(struct Pair32){10,20},12)!=42) return 11;
    if (mix16_out.first!=-2 || mix16_out.second!=44) return 12;
    if (mix16_stack(1,2,3,4,5,6,7,(struct Mix16){10,20},12)!=42) return 13;
    if (tiny_out.first!=1 || tiny_out.second!=2 || tiny_out.third!=36) return 14;
    if (!flagptr_out.flag || flagptr_out.code!=8 || flagptr_out.ptr!=(int64_t *)(uintptr_t)4096) return 15;
    return dlclose(lib)==0 ? 0 : 16;
}
C
xcrun clang -Wall -Wextra -Werror "$work/aggregate-loader.c" -o "$work/aggregate-loader"
zag_run_bounded 30 "$work/aggregate-loader" "$work/aggregate-export.dylib"

cat >"$work/project/src/float-callback-export.zag" <<'ZAG'
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
build "$work/project/src/float-callback-export.zag" --emit-dylib -L "$work/libs" -l helper \
    --install-name @rpath/libzag-float-callback.dylib -o "$work/float-callback.dylib"
cat >"$work/float-callback-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
    if (!lib) return 3;
    int64_t (*fn)(void)=(int64_t(*)(void))dlsym(lib,"zag_float_callback_import");
    if (!fn) return 4;
    if (fn()!=42) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -Wall -Wextra -Werror "$work/float-callback-loader.c" -o "$work/float-callback-loader"
DYLD_LIBRARY_PATH="$work/libs" zag_run_bounded 30 "$work/float-callback-loader" "$work/float-callback.dylib"

cat >"$work/project/src/callback-app.zag" <<'ZAG'
extern fn cabi_apply(value: i64, callback: fn(i64)i64) i64 @cabi;
fn add_nine(value: i64) i64 { return value + 9; }
fn main() i32 {
    unsafe { if (cabi_apply(33, add_nine) == 42) { return 0; } }
    return 1;
}
ZAG
build "$work/project/src/callback-app.zag" --dynamic -L "$work/libs" -l helper -o "$work/bin/callback-app"
zag_run_bounded 30 "$work/bin/callback-app"

# Framework search uses SDK TAPI stubs as bounded symbol/install-name metadata;
# dyld still loads the canonical shared-cache framework at runtime.
cat >"$work/project/src/corefoundation-app.zag" <<'ZAG'
extern fn CFAbsoluteTimeGetCurrent() f64 @cabi;
fn main() i32 {
    unsafe {
        let now: f64 = CFAbsoluteTimeGetCurrent();
        if (now > 100000000.0) { return 0; }
    }
    return 1;
}
ZAG
build "$work/project/src/corefoundation-app.zag" --dynamic -framework CoreFoundation \
    -o "$work/bin/corefoundation-app"
otool -L "$work/bin/corefoundation-app" | grep -q '/System/Library/Frameworks/CoreFoundation.framework/'
zag_run_bounded 30 "$work/bin/corefoundation-app"

# Exercise explicit -F independently of the host SDK. The .tbd is the link
# metadata; the sibling framework binary is the actual dyld runtime image.
mkdir -p "$work/frameworks/LocalKit.framework"
cat >"$work/local-kit.c" <<'C'
#include <stdint.h>
int64_t local_kit_answer(void) { return 42; }
C
xcrun clang -Wall -Wextra -Werror -dynamiclib "$work/local-kit.c" \
    -Wl,-install_name,"$work/frameworks/LocalKit.framework/LocalKit" \
    -o "$work/frameworks/LocalKit.framework/LocalKit"
cat >"$work/frameworks/LocalKit.framework/LocalKit.tbd" <<TBD
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-macos ]
install-name: '$work/frameworks/LocalKit.framework/LocalKit'
exports:
  - targets: [ arm64-macos ]
    symbols: [ _local_kit_answer ]
...
TBD
cat >"$work/project/src/framework-app.zag" <<'ZAG'
extern fn local_kit_answer() i64 @cabi;
fn main() i32 { unsafe { if (local_kit_answer() == 42) { return 0; } } return 1; }
ZAG
build "$work/project/src/framework-app.zag" --dynamic -F "$work/frameworks" -framework LocalKit \
    -o "$work/bin/framework-app"
otool -L "$work/bin/framework-app" | grep -Fq "$work/frameworks/LocalKit.framework/LocalKit"
zag_run_bounded 30 "$work/bin/framework-app"

# Ordinary -l and --needed lookup also consume bounded SDK TAPI stubs when the
# runtime library lives only in the dyld shared cache. Both forms must resolve
# the same direct arm64 symbol and embed the stub's canonical install name.
cat >"$work/project/src/sdk-lib-app.zag" <<'ZAG'
extern fn zlibCompileFlags() u64 @cabi;
fn main() i32 { unsafe { if (zlibCompileFlags() > 0) { return 0; } } return 1; }
ZAG
build "$work/project/src/sdk-lib-app.zag" --dynamic -lz -o "$work/bin/sdk-lib-named"
build "$work/project/src/sdk-lib-app.zag" --dynamic --needed libz.tbd -o "$work/bin/sdk-lib-needed"
cmp "$work/bin/sdk-lib-named" "$work/bin/sdk-lib-needed"
otool -L "$work/bin/sdk-lib-named" | grep -Fq '/usr/lib/libz.1.dylib'
zag_run_bounded 30 "$work/bin/sdk-lib-named"

# Run paths containing whitespace, quotes and shell metacharacters as one
# executable operand, not a command template.
build "$work/project/src/app.zag" --dynamic -L "$work/libs" -l helper \
    --run -o "$work/bin/app with 'quote';exit 91" >"$work/run.log"
grep -Fxq linked-app-ok "$work/run.log"
grep -Fxq 'znc: program exited 0' "$work/run.log"

# A versioned symlink is a normal library input; cache readers remain no-follow.
ln -s libhelper.dylib "$work/libs/libalias.dylib"
build "$work/project/src/app.zag" --dynamic -L "$work/libs" -l alias -o "$work/bin/symlink"
test "$(zag_run_bounded 30 "$work/bin/symlink")" = linked-app-ok

# Both source @link and nearest ancestor manifest dependencies use the same
# reader, symbol resolver and native linker as command-line options.
{ printf '@link("helper");\n'; cat "$work/project/src/app.zag"; } >"$work/project/src/source-link.zag"
build "$work/project/src/source-link.zag" --dynamic -L "$work/libs" -o "$work/bin/source-link"
test "$(zag_run_bounded 30 "$work/bin/source-link")" = linked-app-ok
cp "$work/project/zag.mod" "$work/manifest-base"
printf '\n[deps]\nhelper = { link = "helper", path = "../libs" }\n' >>"$work/project/zag.mod"
build "$work/project/src/app.zag" --dynamic -o "$work/bin/manifest-link"
test "$(zag_run_bounded 30 "$work/bin/manifest-link")" = linked-app-ok
cp "$work/manifest-base" "$work/project/zag.mod"

# A source-only dependency may declare its own native-library requirement.
# Resolve its manifest relative to that module, not the root or working dir.
mkdir -p "$work/project/vendor/wrapped"
printf '\n[deps]\nwrapped = { path = "vendor/wrapped" }\n' >>"$work/project/zag.mod"
printf 'name = "wrapped"\nversion = "0"\nedition = "2027"\n\n[deps]\nnative = { link = "helper", path = "../../../libs" }\n' \
    >"$work/project/vendor/wrapped/zag.mod"
cat >"$work/project/vendor/wrapped/bridge.zag" <<'ZAG'
extern fn cabi_mul3(value: i64) i64 @cabi;
pub fn value() i64 { unsafe { return cabi_mul3(14); } }
ZAG
cat >"$work/project/src/imported-link.zag" <<'ZAG'
@import("pkg:wrapped/bridge.zag") as wrapped
fn main() i32 { if (wrapped.value() == 42) { return 0; } return 1; }
ZAG
build "$work/project/src/imported-link.zag" --dynamic -o "$work/bin/imported-manifest"
zag_run_bounded 30 "$work/bin/imported-manifest"
cp "$work/manifest-base" "$work/project/zag.mod"

# Shared-cache providers have no required on-disk image. The selected system
# library must still resolve and execute the requested scalar foreign call.
cat >"$work/project/src/system-link.zag" <<'ZAG'
extern fn labs(value: i64) i64 @cabi;
fn main() i32 { unsafe { if (labs(-42) == 42) { return 0; } } return 1; }
ZAG
build "$work/project/src/system-link.zag" --dynamic -l c -o "$work/bin/system-provider"
zag_run_bounded 30 "$work/bin/system-provider"

# Moving the tree must work through a user-supplied loader-relative rpath,
# with the build-time library directory absent.
build "$work/project/src/app.zag" --dynamic -L "$work/libs" -l helper \
    --rpath @loader_path/../libs -o "$work/bin/relocatable"
build "$work/project/src/app.zag" --dynamic -L "$work/libs" -l helper \
    --rpath=@loader_path/../libs -o "$work/bin/relocatable-equal"
cmp "$work/bin/relocatable" "$work/bin/relocatable-equal"
mv "$work/bin" "$work/relocated/bin"
mv "$work/libs" "$work/relocated/libs"
test "$(zag_run_bounded 30 "$work/relocated/bin/relocatable")" = linked-app-ok
mv "$work/relocated/bin" "$work/bin"
mv "$work/relocated/libs" "$work/libs"

# A Zag-generated dylib can itself be a link input, selected by its export
# trie, not a hard-coded imported-name list.
cat >"$work/project/src/consumer.zag" <<'ZAG'
extern fn zag_object_answer(value: i64) i64 @cabi;
fn main() i32 { unsafe { if (zag_object_answer(12) == 42) { return 0; } } return 1; }
ZAG
cp "$work/ordinary-first.dylib" "$work/libs/libzag-library.dylib"
build "$work/project/src/consumer.zag" --dynamic -L "$work/libs" -l zag-library -o "$work/bin/consumer"
zag_run_bounded 30 "$work/bin/consumer"

rejections=0
reject() {
    local label=$1 source=$2
    local status=0
    shift 2
    printf 'caller-owned-output\n' >"$work/rejected"
    cp "$work/rejected" "$work/sentinel"
    if build "$source" "$@" -o "$work/rejected" >"$work/$label.log" 2>&1; then
        echo "macOS dylib: unexpectedly accepted $label" >&2; exit 1
    else
        status=$?
    fi
    if [ "$status" -ne 1 ]; then
        echo "macOS dylib: abnormal rejection status $status for $label" >&2
        tail -n 12 "$work/$label.log" >&2
        exit 1
    fi
    cmp "$work/rejected" "$work/sentinel"
    grep -Eq 'znc|error|Mach-O|arm64|^E[0-9]{4}:' "$work/$label.log"
    rejections=$((rejections + 1))
}
reject object-conflict "$work/project/src/library.zag" --emit-dylib --emit-obj
reject archive-conflict "$work/project/src/library.zag" --emit-dylib --emit-static
reject dynamic-conflict "$work/project/src/library.zag" --emit-dylib --dynamic
reject run-library "$work/project/src/library.zag" --emit-dylib --run
reject missing-install-name "$work/project/src/library.zag" --emit-dylib --install-name
reject empty-install-name "$work/project/src/library.zag" --emit-dylib --install-name=
reject duplicate-install-name "$work/project/src/library.zag" --emit-dylib --install-name one --install-name two
reject missing-rpath "$work/project/src/app.zag" --dynamic --rpath
reject empty-rpath "$work/project/src/app.zag" --dynamic --rpath=
reject missing-library-name "$work/project/src/app.zag" --dynamic -l
reject missing-library-path "$work/project/src/app.zag" --dynamic -L
reject missing-framework-name "$work/project/src/app.zag" --dynamic -framework
reject missing-framework-path "$work/project/src/app.zag" --dynamic -F
reject nonexistent-framework "$work/project/src/app.zag" --dynamic -F "$work/frameworks" -framework AbsentKit
reject empty-needed "$work/project/src/app.zag" --dynamic --needed=
reject no-explicit-dynamic "$work/project/src/app.zag" -L "$work/libs" -l helper
reject nonexistent-library "$work/project/src/app.zag" --dynamic -L "$work/libs" -l absent
reject unresolved "$work/project/src/library.zag" --emit-dylib
reject incompatible-debug "$work/project/src/library.zag" --emit-dylib --debug
reject incompatible-hot "$work/project/src/library.zag" --emit-dylib --hot
reject exit-sanitizer "$work/project/src/library.zag" --emit-dylib --sanitize=memory
reject executable-install-name "$work/project/src/app.zag" --dynamic --install-name arbitrary
printf 'not a Mach-O library\n' >"$work/libs/libmalformed.dylib"
reject malformed-library "$work/project/src/app.zag" --dynamic -L "$work/libs" -l malformed
mkdir -p "$work/frameworks/MalformedKit.framework"
printf '%s\n' '--- !tapi-tbd' 'tbd-version: 4' 'targets: [ arm64-macos ]' \
    'exports:' '  - symbols: [ _cabi_mul3' >"$work/frameworks/MalformedKit.framework/MalformedKit.tbd"
reject malformed-framework "$work/project/src/app.zag" --dynamic -F "$work/frameworks" -framework MalformedKit
mkdir -p "$work/frameworks/WrongArchKit.framework"
cat >"$work/frameworks/WrongArchKit.framework/WrongArchKit.tbd" <<TBD
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-macos, x86_64-macos ]
install-name: '$work/frameworks/WrongArchKit.framework/WrongArchKit'
exports:
  - targets: [ x86_64-macos ]
    symbols: [ _cabi_mul3 ]
  - targets: [ arm64-macos ]
    symbols: [ _wrong_arch_arm64_only ]
...
TBD
reject wrong-arch-framework-export "$work/project/src/app.zag" --dynamic -F "$work/frameworks" -framework WrongArchKit
mkfifo "$work/libs/libfifo.dylib"
reject fifo-library "$work/project/src/app.zag" --dynamic -L "$work/libs" -l fifo
zag_truncate_file 67108865 "$work/libs/liboversized.dylib"
reject oversized-library "$work/project/src/app.zag" --dynamic -L "$work/libs" -l oversized
xcrun clang -Wall -Wextra -Werror -dynamiclib "$work/helper.c" \
    -Wl,-install_name,@rpath/libhelper.dylib -o "$work/libs/libduplicate.dylib"
reject duplicate-identity "$work/project/src/app.zag" --dynamic -L "$work/libs" -l helper -l duplicate
reject ambiguous-system-provider "$work/project/src/app.zag" --dynamic -l objc -l sqlite3
cp "$work/project/src/library.zag" "$work/legacy.zag"
reject legacy-edition "$work/legacy.zag" --emit-dylib
cat >"$work/project/float-callback.zag" <<'ZAG'
extern fn cabi_apply_float(value: f32, callback: fn(f32)f32) f32 @cabi;
fn identity(value: f32) f32 { return value; }
pub fn invalid(value: f32) f32 @cabi_export { unsafe { return cabi_apply_float(value, identity); } }
ZAG
reject f32-callback "$work/project/float-callback.zag" --emit-dylib
cat >"$work/project/small-aggregate.zag" <<'ZAG'
struct Inner32 { first:i32, second:i32 }
struct Nested32 { inner:Inner32, tail:i64 }
pub fn invalid(value:Nested32) Nested32 @cabi_export { return value; }
ZAG
reject small-aggregate "$work/project/small-aggregate.zag" --emit-dylib
printf 'pub fn invalid() i64 @cabi_export { let x: Missing = 1; return x; }\n' >"$work/project/invalid.zag"
reject unknown-type "$work/project/invalid.zag" --emit-dylib
printf 'macOS dylib: PASS production CLI, deterministic signed dylibs, C/Zag/C including bounded-f32/f64, flat/nested 64-bit-leaf plus flat mixed-width small register/stack and large indirect aggregate imports/exports, direct scalar callbacks, and explicit-export f32/f64 callbacks, .tbd/framework search, checked access, custom executables, library/imported-manifest lookup, system providers, rpaths/relocation, symlinks, --run, %s negative cases\n' "$rejections"
