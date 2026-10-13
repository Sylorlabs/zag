#!/usr/bin/env bash
# Production macOS ARM64 static-input linker qualification. Apple clang/libtool
# create independent object/archive fixtures; Zag owns parsing, selection,
# relocation, dylib/executable linking, signing, and dynamic-symbol resolution.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then exit 2; fi

compiler=${ZNC:-$(zag_native_compiler "$PWD")}
case "$compiler" in /*) ;; *) compiler="$PWD/$compiler" ;; esac
test -x "$compiler"
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-static-link.XXXXXX")
work=$(cd "$work" && pwd -P)
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ] || [ "${ZAG_TEST_KEEP_WORK:-0}" = 1 ]; then
        printf 'macOS static link: retained test artifacts: %s\n' "$work" >&2
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$work/project" "$work/obj" "$work/lib" "$work/out"
printf 'name = "static-link"\nversion = "0"\nedition = "2027"\n' >"$work/project/zag.mod"

build() {
    zag_run_bounded 240 "$compiler" "$@" --target macos-arm64 \
        --no-zagd --no-analyze --no-foreground-cache
}
cc_obj() {
    xcrun clang -arch arm64 -Wall -Wextra -Werror -O0 -c "$1" -o "$2" "${@:3}"
}

cat >"$work/static-add.c" <<'C'
#include <stdint.h>
int64_t static_add(int64_t value) { return value + 30; }
C
cc_obj "$work/static-add.c" "$work/obj/static-add.o"
cat >"$work/project/static-add.zag" <<'ZAG'
extern fn static_add(value: i64) i64 @cabi;
pub fn zag_static_add(value: i64) i64 @cabi_export {
    unsafe { return static_add(value); }
}
ZAG
cat >"$work/project/static-app.zag" <<'ZAG'
extern fn static_add(value: i64) i64 @cabi;
fn main() i32 {
    unsafe { if (static_add(12) == 42) { return 0; } }
    return 1;
}
ZAG
cat >"$work/add-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*add)(int64_t)=(int64_t(*)(int64_t))dlsym(lib,"zag_static_add");
    if (!add || add(12)!=42) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/add-loader.c" -o "$work/add-loader"

# Positional input before the source, --static-input, and its = form are one
# deterministic request. Keep an explicit install name so output filenames do
# not intentionally perturb Mach-O load-command bytes.
common=(--emit-dylib --install-name @rpath/libstatic-cli.dylib)
build "$work/obj/static-add.o" "$work/project/static-add.zag" "${common[@]}" -o "$work/out/positional.dylib"
build "$work/project/static-add.zag" --static-input "$work/obj/static-add.o" "${common[@]}" -o "$work/out/option.dylib"
build "$work/project/static-add.zag" --static-input="$work/obj/static-add.o" "${common[@]}" -o "$work/out/equal.dylib"
cmp "$work/out/positional.dylib" "$work/out/option.dylib"
cmp "$work/out/option.dylib" "$work/out/equal.dylib"
file -b "$work/out/option.dylib" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'
codesign --verify --deep --strict "$work/out/option.dylib"
zag_run_bounded 30 "$work/add-loader" "$work/out/option.dylib"

# Explicit static input also composes with the native custom executable path.
build "$work/project/static-app.zag" "$work/obj/static-add.o" --dynamic -o "$work/out/static-app"
zag_assert_native_executable "$work/out/static-app"
zag_run_bounded 30 "$work/out/static-app"

# A selected static leaf symlink follows the same bounded regular-file policy
# as an explicitly selected dylib input.
ln -s static-add.o "$work/obj/static-add-link.o"
build "$work/project/static-add.zag" "$work/obj/static-add-link.o" "${common[@]}" -o "$work/out/symlink.dylib"
zag_run_bounded 30 "$work/add-loader" "$work/out/symlink.dylib"

# Apple-Clang globals/string literals exercise load/store PAGEOFF12 in addition
# to address PAGE21/PAGEOFF12 relocation pairs.
cat >"$work/static-data.c" <<'C'
#include <stdint.h>
int64_t c_global = 42;
int64_t c_value(void) { return c_global; }
const char *c_literal(void) { return "static-data-ok"; }
int64_t *c_pointer(void) { return &c_global; }
C
cc_obj "$work/static-data.c" "$work/obj/static-data.o"
cat >"$work/project/static-data.zag" <<'ZAG'
extern fn c_value() i64 @cabi;
extern fn c_literal() *u8 @cabi;
extern fn c_pointer() *i64 @cabi;
pub fn zag_c_value() i64 @cabi_export { unsafe { return c_value(); } }
pub fn zag_c_literal() *u8 @cabi_export { unsafe { return c_literal(); } }
pub fn zag_c_pointer() *i64 @cabi_export { unsafe { return c_pointer(); } }
ZAG
cat >"$work/data-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*value)(void)=(int64_t(*)(void))dlsym(lib,"zag_c_value");
    const char *(*literal)(void)=(const char *(*)(void))dlsym(lib,"zag_c_literal");
    int64_t *(*pointer)(void)=(int64_t *(*)(void))dlsym(lib,"zag_c_pointer");
    if (!value || !literal || !pointer) return 4;
    if (value()!=42 || strcmp(literal(),"static-data-ok") || !pointer() || *pointer()!=42) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/data-loader.c" -o "$work/data-loader"
build "$work/project/static-data.zag" "$work/obj/static-data.o" --emit-dylib -o "$work/out/static-data.dylib"
zag_run_bounded 30 "$work/data-loader" "$work/out/static-data.dylib"

# Absolute data pointers are rebased by the final Zag-owned Mach-O image.
cat >"$work/static-pointer.c" <<'C'
#include <stdint.h>
static int64_t local_add(int64_t value) { return value + 30; }
int64_t (*c_function_pointer)(int64_t) = local_add;
C
cc_obj "$work/static-pointer.c" "$work/obj/static-pointer.o"
cat >"$work/project/dummy.zag" <<'ZAG'
pub fn zag_static_dummy() i64 @cabi_export { return 42; }
ZAG
cat >"$work/pointer-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (**slot)(int64_t)=(int64_t (**)(int64_t))dlsym(lib,"c_function_pointer");
    if (!slot || !*slot || (*slot)(12)!=42) return 4;
    if (dlsym(lib,"local_add")) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/pointer-loader.c" -o "$work/pointer-loader"
build "$work/project/dummy.zag" "$work/obj/static-pointer.o" --emit-dylib -o "$work/out/static-pointer.dylib"
zag_run_bounded 30 "$work/pointer-loader" "$work/out/static-pointer.dylib"

# Demand-driven archive extraction: unused members stay out, and extraction
# iterates to a fixed point when one member introduces another dependency.
cat >"$work/wanted.c" <<'C'
#include <stdint.h>
int64_t wanted(int64_t value) { return value + 30; }
C
cat >"$work/unused.c" <<'C'
#include <stdint.h>
int64_t unused_archive_symbol(int64_t value) { return value + 9000; }
C
cc_obj "$work/wanted.c" "$work/obj/wanted.o"
cc_obj "$work/unused.c" "$work/obj/unused.o"
xcrun libtool -static -o "$work/lib/libselect.a" "$work/obj/wanted.o" "$work/obj/unused.o"
cat >"$work/project/archive.zag" <<'ZAG'
extern fn wanted(value: i64) i64 @cabi;
pub fn zag_archive_answer(value: i64) i64 @cabi_export { unsafe { return wanted(value); } }
ZAG
cat >"$work/archive-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*answer)(int64_t)=(int64_t(*)(int64_t))dlsym(lib,"zag_archive_answer");
    if (!answer || answer(12)!=42 || dlsym(lib,"unused_archive_symbol")) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/archive-loader.c" -o "$work/archive-loader"
build "$work/project/archive.zag" "$work/lib/libselect.a" --emit-dylib -o "$work/out/archive.dylib"
zag_run_bounded 30 "$work/archive-loader" "$work/out/archive.dylib"

cat >"$work/stage1.c" <<'C'
#include <stdint.h>
extern int64_t second_stage(int64_t value);
int64_t first_stage(int64_t value) { return second_stage(value) + 10; }
C
cat >"$work/stage2.c" <<'C'
#include <stdint.h>
int64_t second_stage(int64_t value) { return value + 20; }
C
cc_obj "$work/stage1.c" "$work/obj/stage1.o"
cc_obj "$work/stage2.c" "$work/obj/stage2.o"
xcrun libtool -static -o "$work/lib/libtransitive.a" "$work/obj/stage1.o" "$work/obj/stage2.o" "$work/obj/unused.o"
cat >"$work/project/transitive.zag" <<'ZAG'
extern fn first_stage(value: i64) i64 @cabi;
pub fn zag_archive_transitive(value: i64) i64 @cabi_export { unsafe { return first_stage(value); } }
ZAG
cat >"$work/transitive-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if (!lib) return 3;
    int64_t (*value)(int64_t)=(int64_t(*)(int64_t))dlsym(lib,"zag_archive_transitive");
    if (!value || value(12)!=42 || dlsym(lib,"unused_archive_symbol")) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/transitive-loader.c" -o "$work/transitive-loader"
build "$work/project/transitive.zag" "$work/lib/libtransitive.a" --emit-dylib -o "$work/out/transitive.dylib"
zag_run_bounded 30 "$work/transitive-loader" "$work/out/transitive.dylib"

# A selected archive member may still need dyld. Its unresolved getpid import
# is passed to the existing audited libSystem resolver after static merging.
cat >"$work/archive-dynamic.c" <<'C'
#include <stdint.h>
#include <unistd.h>
int64_t archive_pid(void) { return (int64_t)getpid(); }
C
cc_obj "$work/archive-dynamic.c" "$work/obj/archive-dynamic.o"
xcrun libtool -static -o "$work/lib/libdynamic.a" "$work/obj/archive-dynamic.o"
cat >"$work/project/archive-dynamic.zag" <<'ZAG'
extern fn archive_pid() i64 @cabi;
pub fn zag_archive_pid() i64 @cabi_export { unsafe { return archive_pid(); } }
ZAG
cat >"$work/dynamic-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if (!lib) return 3;
    int64_t (*pid)(void)=(int64_t(*)(void))dlsym(lib,"zag_archive_pid");
    if (!pid || pid()!=(int64_t)getpid()) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/dynamic-loader.c" -o "$work/dynamic-loader"
build "$work/project/archive-dynamic.zag" "$work/lib/libdynamic.a" --emit-dylib -o "$work/out/archive-dynamic.dylib"
zag_run_bounded 30 "$work/dynamic-loader" "$work/out/archive-dynamic.dylib"

# Resolution follows the native static-link hierarchy: regular strong > COMMON
# > weak; COMMON coalesces to the maximum requested size/alignment.
cat >"$work/common-small.c" <<'C'
char common_blob[4];
C
cat >"$work/common-large.c" <<'C'
char common_blob[32];
C
cat >"$work/weak.c" <<'C'
#include <stdint.h>
__attribute__((weak)) int64_t weak_answer(void) { return 7; }
C
cat >"$work/strong.c" <<'C'
#include <stdint.h>
int64_t weak_answer(void) { return 42; }
C
cc_obj "$work/common-small.c" "$work/obj/common-small.o" -fcommon
cc_obj "$work/common-large.c" "$work/obj/common-large.o" -fcommon
cc_obj "$work/weak.c" "$work/obj/weak.o"
cc_obj "$work/strong.c" "$work/obj/strong.o"
cat >"$work/common-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if (!lib) return 3;
    char *common=(char *)dlsym(lib,"common_blob");
    int64_t (*answer)(void)=(int64_t(*)(void))dlsym(lib,"weak_answer");
    if (!common || !answer || answer()!=42) return 4;
    for (int i=0;i<32;++i) if (common[i]!=0) return 5;
    common[31]=42; if (common[31]!=42) return 6;
    return dlclose(lib)==0 ? 0 : 7;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/common-loader.c" -o "$work/common-loader"
build "$work/project/dummy.zag" "$work/obj/common-small.o" "$work/obj/common-large.o" \
    "$work/obj/weak.o" "$work/obj/strong.o" --emit-dylib -o "$work/out/common-weak.dylib"
zag_run_bounded 30 "$work/common-loader" "$work/out/common-weak.dylib"

# COMMON definitions in an archive satisfy a strong demand introduced by an
# earlier direct object. Weak archive definitions do not satisfy that demand.
cat >"$work/common-ref.c" <<'C'
extern char common_blob[];
char *common_ptr = common_blob;
int common_dummy(void) { return 42; }
C
cc_obj "$work/common-ref.c" "$work/obj/common-ref.o"
xcrun libtool -static -o "$work/lib/libcommon.a" "$work/obj/common-large.o"
cat >"$work/common-archive-loader.c" <<'C'
#include <dlfcn.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); if (!lib) return 3;
    char **slot=(char **)dlsym(lib,"common_ptr"); if (!slot || !*slot) return 4;
    for (int i=0;i<32;++i) if ((*slot)[i]!=0) return 5;
    (*slot)[31]=42; if ((*slot)[31]!=42) return 6;
    return dlclose(lib)==0 ? 0 : 7;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/common-archive-loader.c" -o "$work/common-archive-loader"
build "$work/project/dummy.zag" "$work/obj/common-ref.o" "$work/lib/libcommon.a" \
    --emit-dylib -o "$work/out/common-archive.dylib"
zag_run_bounded 30 "$work/common-archive-loader" "$work/out/common-archive.dylib"
xcrun libtool -static -o "$work/lib/libweak.a" "$work/obj/weak.o"
cat >"$work/project/weak-demand.zag" <<'ZAG'
extern fn weak_answer() i64 @cabi;
pub fn zag_weak_demand() i64 @cabi_export { unsafe { return weak_answer(); } }
ZAG

rejections=0
reject() {
    local label=$1 source=$2
    shift 2
    printf 'caller-owned-output\n' >"$work/out/rejected"
    cp "$work/out/rejected" "$work/out/sentinel"
    local status=0
    if build "$source" "$@" -o "$work/out/rejected" >"$work/$label.log" 2>&1; then
        echo "macOS static link: unexpectedly accepted $label" >&2; exit 1
    else
        status=$?
    fi
    if [ "$status" -ne 1 ]; then
        echo "macOS static link: abnormal rejection status $status for $label" >&2
        tail -n 16 "$work/$label.log" >&2
        exit 1
    fi
    cmp "$work/out/rejected" "$work/out/sentinel"
    grep -Eq 'znc|Mach-O|static|link|arm64|^E[0-9]{4}:' "$work/$label.log"
    rejections=$((rejections + 1))
}

# A weak-import reference is statically satisfiable when a direct definition
# exists. Without one, preserve the weak undefined symbol through the native
# linker so dyld flat lookup leaves its GOT slot null when no provider exists.
cat >"$work/weak-import.c" <<'C'
#include <stdint.h>
extern __attribute__((weak_import)) int64_t optional_value(void);
int64_t weak_import_call(void) {
    return optional_value ? optional_value() : -1;
}
C
cat >"$work/optional-value.c" <<'C'
#include <stdint.h>
int64_t optional_value(void) { return 42; }
C
cc_obj "$work/weak-import.c" "$work/obj/weak-import.o"
cc_obj "$work/optional-value.c" "$work/obj/optional-value.o"
cat >"$work/project/weak-import.zag" <<'ZAG'
extern fn weak_import_call() i64 @cabi;
pub fn zag_weak_import_call() i64 @cabi_export { unsafe { return weak_import_call(); } }
ZAG
cat >"$work/weak-import-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*value)(void)=(int64_t(*)(void))dlsym(lib,"zag_weak_import_call");
    if (!value || value()!=42) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/weak-import-loader.c" -o "$work/weak-import-loader"
build "$work/project/weak-import.zag" "$work/obj/weak-import.o" "$work/obj/optional-value.o" \
    --emit-dylib -o "$work/out/weak-import-resolved.dylib"
zag_run_bounded 30 "$work/weak-import-loader" "$work/out/weak-import-resolved.dylib"
cat >"$work/weak-import-missing-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*value)(void)=(int64_t(*)(void))dlsym(lib,"zag_weak_import_call");
    if (!value || value()!=-1) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/weak-import-missing-loader.c" -o "$work/weak-import-missing-loader"
build "$work/project/weak-import.zag" "$work/obj/weak-import.o" --emit-dylib -o "$work/out/weak-import-missing.dylib"
zag_run_bounded 30 "$work/weak-import-missing-loader" "$work/out/weak-import-missing.dylib"
nm -m "$work/out/weak-import-missing.dylib" | grep -q '(undefined) weak external _optional_value (dynamically looked up)'

# Imported thread-local variable access uses ARM64 TLVP_LOAD_PAGE21/PAGEOFF12.
# Those relocations address a pointer slot; dyld binds the slot to the provider's
# exported TLV descriptor, so the final image can reuse the native GOT path.
cat >"$work/tlvp.c" <<'C'
extern __thread int external_tls;
int tls_reader(void) { return external_tls; }
C
cc_obj "$work/tlvp.c" "$work/obj/tlvp.o"
cat >"$work/tlvp-provider.c" <<'C'
__thread int external_tls = 42;
C
xcrun clang -arch arm64 -Wall -Wextra -Werror -dynamiclib "$work/tlvp-provider.c" \
    -Wl,-install_name,@rpath/libtlvp-provider.dylib -o "$work/lib/libtlvp-provider.dylib"
cat >"$work/tlvp-loader.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int (*reader)(void)=(int(*)(void))dlsym(lib,"tls_reader");
    if (!reader || reader()!=42) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/tlvp-loader.c" -o "$work/tlvp-loader"
build "$work/project/dummy.zag" "$work/obj/tlvp.o" --emit-dylib \
    -L "$work/lib" -l tlvp-provider --rpath "$work/lib" -o "$work/out/tlvp.dylib"
zag_run_bounded 30 "$work/tlvp-loader" "$work/out/tlvp.dylib"

reject weak-archive "$work/project/weak-demand.zag" "$work/lib/libweak.a" --emit-dylib
cat >"$work/duplicate.c" <<'C'
#include <stdint.h>
int64_t weak_answer(void) { return 99; }
C
cc_obj "$work/duplicate.c" "$work/obj/duplicate.o"
reject duplicate-strong "$work/project/dummy.zag" "$work/obj/strong.o" "$work/obj/duplicate.o" --emit-dylib

printf 'not a Mach-O object\n' >"$work/obj/malformed.o"
printf '!<arch>\ntruncated' >"$work/lib/malformed.a"
reject malformed-object "$work/project/dummy.zag" "$work/obj/malformed.o" --emit-dylib
reject malformed-archive "$work/project/dummy.zag" "$work/lib/malformed.a" --emit-dylib
reject missing-static-input "$work/project/dummy.zag" --emit-dylib --static-input
reject invalid-static-suffix "$work/project/dummy.zag" --emit-dylib --static-input "$work/static-add.c"
reject no-linked-mode "$work/project/static-add.zag" "$work/obj/static-add.o"
reject object-output-conflict "$work/project/static-add.zag" "$work/obj/static-add.o" --emit-obj

# PIC access to an unresolved external data object produces the standard
# GOT_LOAD_PAGE21/PAGEOFF12 pair. The static merger keeps that import unresolved
# and the final native writer addresses its already-bound dylib GOT slot.
cat >"$work/got.c" <<'C'
#include <stdint.h>
extern int64_t external_slot;
int64_t got_reader(void) { return external_slot; }
C
cc_obj "$work/got.c" "$work/obj/got.o"
cat >"$work/got-provider.c" <<'C'
#include <stdint.h>
int64_t external_slot = 42;
C
xcrun clang -arch arm64 -Wall -Wextra -Werror -dynamiclib "$work/got-provider.c" \
    -Wl,-install_name,@rpath/libgot-provider.dylib -o "$work/lib/libgot-provider.dylib"
cat >"$work/project/got.zag" <<'ZAG'
extern fn got_reader() i64 @cabi;
pub fn zag_got_reader() i64 @cabi_export { unsafe { return got_reader(); } }
ZAG
cat >"$work/got-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*value)(void)=(int64_t(*)(void))dlsym(lib,"zag_got_reader");
    if (!value || value()!=42) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/got-loader.c" -o "$work/got-loader"
build "$work/project/got.zag" "$work/obj/got.o" --emit-dylib \
    -L "$work/lib" -l got-provider --rpath "$work/lib" -o "$work/out/got.dylib"
zag_run_bounded 30 "$work/got-loader" "$work/out/got.dylib"

# The same relocation pair may resolve to another static object. In that case
# the final writer allocates a local GOT slot containing a rebased pointer to
# the retained definition rather than changing the two-instruction load shape.
cc_obj "$work/got-provider.c" "$work/obj/got-provider.o"
build "$work/project/got.zag" "$work/obj/got.o" "$work/obj/got-provider.o" \
    --emit-dylib -o "$work/out/got-static.dylib"
zag_run_bounded 30 "$work/got-loader" "$work/out/got-static.dylib"

# POINTER_TO_GOT is a 32-bit PC-relative datum naming a GOT entry. Validate
# both the bound-import slot and the rebased local slot rather than merely
# inspecting relocation metadata.
cat >"$work/pointer-got.s" <<'ASM'
.section __DATA,__data
.globl _got_delta
.p2align 2
_got_delta:
.long _external_slot@GOT - .
ASM
xcrun clang -arch arm64 -c "$work/pointer-got.s" -o "$work/obj/pointer-got.o"
cat >"$work/pointer-got-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int32_t *delta=(int32_t *)dlsym(lib,"got_delta");
    if (!delta) return 4;
    int64_t **slot=(int64_t **)((char *)delta + *delta);
    if (!slot || !*slot || **slot!=42) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/pointer-got-loader.c" -o "$work/pointer-got-loader"
build "$work/project/dummy.zag" "$work/obj/pointer-got.o" --emit-dylib \
    -L "$work/lib" -l got-provider --rpath "$work/lib" -o "$work/out/pointer-got-import.dylib"
zag_run_bounded 30 "$work/pointer-got-loader" "$work/out/pointer-got-import.dylib"
build "$work/project/dummy.zag" "$work/obj/pointer-got.o" "$work/obj/got-provider.o" \
    --emit-dylib -o "$work/out/pointer-got-local.dylib"
zag_run_bounded 30 "$work/pointer-got-loader" "$work/out/pointer-got-local.dylib"

# The 64-bit absolute POINTER_TO_GOT form is distinct: the datum itself is a
# rebased pointer to the GOT slot. Exercise it for both imported and local GOT
# ownership so the normalized internal relocation cannot regress to PC-relative
# semantics accidentally.
cat >"$work/pointer-got64.s" <<'ASM'
.section __DATA,__data
.globl _got_pointer
.p2align 3
_got_pointer:
.quad _external_slot@GOT
ASM
xcrun clang -arch arm64 -c "$work/pointer-got64.s" -o "$work/obj/pointer-got64.o"
cat >"$work/pointer-got64-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t ***pointer=(int64_t ***)dlsym(lib,"got_pointer");
    if (!pointer || !*pointer || !**pointer || ***pointer!=42) return 4;
    return dlclose(lib)==0 ? 0 : 5;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/pointer-got64-loader.c" -o "$work/pointer-got64-loader"
build "$work/project/dummy.zag" "$work/obj/pointer-got64.o" --emit-dylib \
    -L "$work/lib" -l got-provider --rpath "$work/lib" -o "$work/out/pointer-got64-import.dylib"
zag_run_bounded 30 "$work/pointer-got64-loader" "$work/out/pointer-got64-import.dylib"
build "$work/project/dummy.zag" "$work/obj/pointer-got64.o" "$work/obj/got-provider.o" \
    --emit-dylib -o "$work/out/pointer-got64-local.dylib"
zag_run_bounded 30 "$work/pointer-got64-loader" "$work/out/pointer-got64-local.dylib"

# SUBTRACTOR+UNSIGNED pairs whose endpoints land in the same merged output
# section are link-time constants. Resolve both 32- and 64-bit forms directly
# in the static merger, including the addend encoded in the datum.
cat >"$work/subtractor.s" <<'ASM'
.section __DATA,__data
.globl _difference64
.p2align 3
_difference64:
.quad _right_marker - _left_marker + 4
.globl _difference32
.p2align 2
_difference32:
.long _right_marker - _left_marker + 4
ASM
xcrun clang -arch arm64 -c "$work/subtractor.s" -o "$work/obj/subtractor.o"
cat >"$work/left-marker.c" <<'C'
#include <stdint.h>
int64_t left_marker = 11;
C
cat >"$work/right-marker.c" <<'C'
#include <stdint.h>
int64_t right_marker = 22;
C
cc_obj "$work/left-marker.c" "$work/obj/left-marker.o"
cc_obj "$work/right-marker.c" "$work/obj/right-marker.o"
cat >"$work/subtractor-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t *left=(int64_t *)dlsym(lib,"left_marker");
    int64_t *right=(int64_t *)dlsym(lib,"right_marker");
    int64_t *d64=(int64_t *)dlsym(lib,"difference64");
    int32_t *d32=(int32_t *)dlsym(lib,"difference32");
    if (!left || !right || !d64 || !d32) return 4;
    intptr_t expected=(char *)right-(char *)left+4;
    if (*d64!=(int64_t)expected || *d32!=(int32_t)expected) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/subtractor-loader.c" -o "$work/subtractor-loader"
build "$work/project/dummy.zag" "$work/obj/subtractor.o" "$work/obj/left-marker.o" \
    "$work/obj/right-marker.o" --emit-dylib -o "$work/out/subtractor.dylib"
zag_run_bounded 30 "$work/subtractor-loader" "$work/out/subtractor.dylib"

# Cross-output-section subtraction is resolved in two phases: the merger folds
# the symbol-relative constant and the final writer adds the text/data base
# delta once segment placement is known. Exercise both directions and widths.
cat >"$work/cross-subtractor.s" <<'ASM'
.section __DATA,__data
.globl _cross_difference64
.p2align 3
_cross_difference64:
.quad _text_marker - _left_marker + 4
.globl _cross_difference32
.p2align 2
_cross_difference32:
.long _text_marker - _left_marker + 4
.globl _cross_reverse64
.p2align 3
_cross_reverse64:
.quad _left_marker - _text_marker - 4
.globl _cross_reverse32
.p2align 2
_cross_reverse32:
.long _left_marker - _text_marker - 4
ASM
xcrun clang -arch arm64 -c "$work/cross-subtractor.s" -o "$work/obj/cross-subtractor.o"
cat >"$work/text-marker.c" <<'C'
void text_marker(void) {}
C
cc_obj "$work/text-marker.c" "$work/obj/text-marker.o"
cat >"$work/cross-subtractor-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    void *text=dlsym(lib,"text_marker");
    void *left=dlsym(lib,"left_marker");
    int64_t *f64=(int64_t *)dlsym(lib,"cross_difference64");
    int32_t *f32=(int32_t *)dlsym(lib,"cross_difference32");
    int64_t *r64=(int64_t *)dlsym(lib,"cross_reverse64");
    int32_t *r32=(int32_t *)dlsym(lib,"cross_reverse32");
    if (!text || !left || !f64 || !f32 || !r64 || !r32) return 4;
    intptr_t forward=(intptr_t)text-(intptr_t)left+4;
    intptr_t reverse=(intptr_t)left-(intptr_t)text-4;
    if (*f64!=(int64_t)forward || *f32!=(int32_t)forward ||
        *r64!=(int64_t)reverse || *r32!=(int32_t)reverse) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/cross-subtractor-loader.c" -o "$work/cross-subtractor-loader"
build "$work/project/dummy.zag" "$work/obj/cross-subtractor.o" \
    "$work/obj/left-marker.o" "$work/obj/text-marker.o" --emit-dylib -o "$work/out/cross-subtractor.dylib"
zag_run_bounded 30 "$work/cross-subtractor-loader" "$work/out/cross-subtractor.dylib"

# Private-external (N_PEXT) definitions must remain available for static
# resolution inside the image without leaking into the final dylib export set.
cat >"$work/hidden.c" <<'C'
#include <stdint.h>
__attribute__((visibility("hidden"))) int64_t hidden_value = 41;
__attribute__((visibility("hidden"))) int64_t hidden_add(int64_t value) { return value + hidden_value; }
int64_t public_call_hidden(int64_t value) { return hidden_add(value); }
C
cc_obj "$work/hidden.c" "$work/obj/hidden.o"
cat >"$work/hidden-loader.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!lib) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
    int64_t (*call)(int64_t)=(int64_t(*)(int64_t))dlsym(lib,"public_call_hidden");
    if (!call || call(1)!=42) return 4;
    if (dlsym(lib,"hidden_add") || dlsym(lib,"hidden_value")) return 5;
    return dlclose(lib)==0 ? 0 : 6;
}
C
xcrun clang -arch arm64 -Wall -Wextra -Werror "$work/hidden-loader.c" -o "$work/hidden-loader"
build "$work/project/dummy.zag" "$work/obj/hidden.o" --emit-dylib -o "$work/out/hidden.dylib"
zag_run_bounded 30 "$work/hidden-loader" "$work/out/hidden.dylib"

printf 'macOS static link: PASS production CLI, direct objects, executable/static dylib, deterministic forms, symlink input, PAGEOFF12 globals/strings, data rebases, selective/transitive archives, libSystem composition, resolved/unresolved weak imports, imported/local GOT loads, imported TLVP, both POINTER_TO_GOT forms, same/cross-section SUBTRACTOR, private-external visibility, COMMON/weak resolution, and %s negative cases\n' "$rejections"
