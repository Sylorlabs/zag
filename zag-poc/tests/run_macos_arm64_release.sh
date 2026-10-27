#!/usr/bin/env bash
# Native macOS Apple-Silicon release gate.  This intentionally exercises the
# Darwin kernel, Mach-O loader, and embedded signature rather than assuming
# that the Linux/AArch64 ELF tests prove the macOS target.
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root=$PWD
. ./tests/portable.sh

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "XX  macos-arm64 release gate requires native Apple Silicon (got $(uname -s) $(uname -m))" >&2
    exit 2
fi

ZNC="${ZNC:-$PWD/znc-macos-arm64}"
if [ ! -x "$ZNC" ]; then
    echo "XX  compiler is not executable: $ZNC" >&2
    exit 2
fi

mkdir -p "$repo_root/build"
tmpdir="$(mktemp -d "$repo_root/build/macos-arm64-release.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
# Generated compilers discover modules relative to their executable. Give
# every generation the checkout's module roots before any validation runs.
ln -s "$repo_root/std" "$tmpdir/std"
ln -s "$repo_root/selfhost" "$tmpdir/selfhost"
pass=0

# Qualify one compiler-source snapshot. A long local run cannot authorize an
# artifact after its source graph changes underneath the later runtime checks.
macos_source_fingerprint() {
    {
        printf '%s\0' zag.mod
        find selfhost std -type f -name '*.zag' -print0
    } | zag_sort_nul | while IFS= read -r -d '' source_path; do
        source_digest=$(zag_sha256_file "$source_path") || exit 1
        printf '%s\0%s\0' "$source_digest" "$source_path"
    done | zag_sha256_stream
}
source_fingerprint=$(macos_source_fingerprint)
require_unchanged_source() {
    if [ "$(macos_source_fingerprint)" != "$source_fingerprint" ]; then
        echo 'XX compiler source changed during qualification; no verified artifact published' >&2
        exit 1
    fi
}

require_macho_arm64() {
    local artifact="$1"
    file "$artifact" | grep -q 'Mach-O 64-bit executable arm64'
}

require_signed() {
    local artifact="$1"
    codesign --verify --deep --strict --verbose=2 "$artifact" >/dev/null
}

echo "── native macOS arm64 release gate ──"

# Build the compiler with an explicit Darwin target.  Do not rely solely on
# the host-default rule: this catches target selection regressions too.
zag_run_bounded 3600 "$ZNC" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-gen1"
require_unchanged_source
require_macho_arm64 "$tmpdir/znc-gen1"
require_signed "$tmpdir/znc-gen1"
echo "  ok  signed Mach-O arm64 self-host compiler"; pass=$((pass + 1))

# The first generated compiler incorporates the current source graph and can
# differ from the trusted seed. Build stage 2 unconditionally. If stage 1 and
# stage 2 are already byte-identical, that pair itself proves the fixed point
# and a third identical rebuild adds no evidence. Otherwise retain the original
# stage-2 -> stage-3 byte-identical criterion used by bootstrap.sh.
zag_run_bounded 3600 "$tmpdir/znc-gen1" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-gen2"
require_unchanged_source
require_macho_arm64 "$tmpdir/znc-gen2"
require_signed "$tmpdir/znc-gen2"
if cmp -s "$tmpdir/znc-gen1" "$tmpdir/znc-gen2"; then
    echo "  ok  native Darwin self-host fixpoint at stage 2"
else
    zag_run_bounded 3600 "$tmpdir/znc-gen2" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-gen3"
    require_unchanged_source
    require_macho_arm64 "$tmpdir/znc-gen3"
    require_signed "$tmpdir/znc-gen3"
    cmp -s "$tmpdir/znc-gen2" "$tmpdir/znc-gen3"
    echo "  ok  native Darwin self-host fixpoint at stage 3"
fi
test_compiler="$tmpdir/znc-gen2"
pass=$((pass + 1))

# Explicit narrowing must preserve low-bit truncation and signed extension.
# The original ARM64 .cast_ lowering kept high bits for u16/i16 and treated
# i8 as unsigned. Run the independent exact-output regression on the
# fixed-point compiler before qualifying a release artifact.
ZNC_BIN="$test_compiler" bash tests/run_sentinel_narrow_cast_matrix.sh
echo "  ok  signed/unsigned narrow-cast normalization (25 outputs)"
pass=$((pass + 1))

# Exercise the signer independently of the compiler-sized artifact.
"$test_compiler" selfhost/native/macho_arm64_test.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/macho-sign-test"
require_macho_arm64 "$tmpdir/macho-sign-test"
require_signed "$tmpdir/macho-sign-test"
"$tmpdir/macho-sign-test"
echo "  ok  Mach-O SHA-256 signer regression"; pass=$((pass + 1))

# CPU selection on Apple Silicon must be native arm64 policy, not the Linux
# x86 /proc/CPUID path. Named Apple profiles currently share the proven arm64
# baseline; unrelated profiles fail before an artifact is produced.
"$test_compiler" examples/numeric.zag --target macos-arm64 --cpu=native --no-zagd --no-analyze -o "$tmpdir/cpu-native"
require_macho_arm64 "$tmpdir/cpu-native"
if "$test_compiler" examples/numeric.zag --target macos-arm64 --cpu=x86-64-v1 --no-zagd --no-analyze -o "$tmpdir/cpu-invalid" >/dev/null 2>&1; then
    echo "XX  macOS target accepted an x86 CPU profile" >&2
    exit 1
fi
test ! -e "$tmpdir/cpu-invalid"
echo "  ok  Apple Silicon CPU policy: native baseline and x86 rejection"; pass=$((pass + 1))

# A real libSystem call verifies LC_DYLD_INFO_ONLY, the dyld bind stream, the
# ARM64 import stub, and the externally resolved C ABI rather than merely
# accepting `--dynamic` as a command-line option.
"$test_compiler" tests/macos_dyld_getpid.zag --target macos-arm64 --dynamic --no-zagd --no-analyze -o "$tmpdir/dyld-getpid"
require_macho_arm64 "$tmpdir/dyld-getpid"
require_signed "$tmpdir/dyld-getpid"
otool -l "$tmpdir/dyld-getpid" | grep -q 'LC_DYLD_INFO_ONLY'
set +e
"$tmpdir/dyld-getpid"
dyld_status=$?
set -e
[ "$dyld_status" -eq 42 ]
echo "  ok  native dyld libSystem import and ARM64 stub"; pass=$((pass + 1))

# Edition 2027 uses the explicit @cabi spelling for the same closed dyld
# executable boundary. This must not fall back to v1 lowering merely because
# the selected target is Mach-O.
mkdir "$tmpdir/v2-dyld"
printf 'name = "macos-v2-dyld"\nversion = "0"\nedition = "2027"\n' \
    >"$tmpdir/v2-dyld/zag.mod"
cat >"$tmpdir/v2-dyld/main.zag" <<'EOF'
extern fn getpid() i64 @cabi;
fn main() i32 { unsafe { if (getpid() > 0) { return 42; } } return 1; }
EOF
"$test_compiler" "$tmpdir/v2-dyld/main.zag" --target macos-arm64 \
    --dynamic --no-zagd --no-analyze -o "$tmpdir/v2-dyld/app"
require_macho_arm64 "$tmpdir/v2-dyld/app"
require_signed "$tmpdir/v2-dyld/app"
set +e
"$tmpdir/v2-dyld/app"
v2_dyld_status=$?
set -e
[ "$v2_dyld_status" -eq 42 ]
echo "  ok  edition-2027 @cabi closed dyld import"; pass=$((pass + 1))

# Fixed f64 imports use Darwin's independent d0-d7 and x0-x7 argument banks.
# cos/pow cover one and two FP arguments/results; ldexp proves a mixed d0/x0
# call through the compiler-owned libSystem binding path.
cat >"$tmpdir/v2-dyld/f64.zag" <<'EOF'
extern fn cos(x: f64) f64 @cabi;
extern fn pow(x: f64, y: f64) f64 @cabi;
extern fn ldexp(x: f64, n: i32) f64 @cabi;
fn main() i32 {
    unsafe {
        let a: f64 = cos(0.0);
        let b: f64 = pow(2.0, 3.0);
        let c: f64 = ldexp(1.5, 2);
        if (a > 0.99 && b > 7.99 && c > 5.99) { return 42; }
    }
    return 1;
}
EOF
"$test_compiler" "$tmpdir/v2-dyld/f64.zag" --target macos-arm64 \
    --dynamic --no-zagd --no-analyze -o "$tmpdir/v2-dyld/f64"
require_macho_arm64 "$tmpdir/v2-dyld/f64"
require_signed "$tmpdir/v2-dyld/f64"
set +e
"$tmpdir/v2-dyld/f64"
v2_f64_status=$?
set -e
[ "$v2_f64_status" -eq 42 ]
echo "  ok  edition-2027 @cabi fixed f64/mixed-register libSystem imports"; pass=$((pass + 1))

# The same closed libSystem writer also exercises the single-precision C ABI.
# cosf/powf prove S-register arguments/results; ldexpf proves independent
# S0/X0 argument assignment while Zag converts its internal f32-as-f64 bits.
cat >"$tmpdir/v2-dyld/f32.zag" <<'EOF'
extern fn cosf(x: f32) f32 @cabi;
extern fn powf(x: f32, y: f32) f32 @cabi;
extern fn ldexpf(x: f32, n: i32) f32 @cabi;
fn main() i32 {
    unsafe {
        let a: f32 = cosf(0.0);
        let b: f32 = powf(2.0, 3.0);
        let c: f32 = ldexpf(1.5, 2);
        if (a > 0.99 && b > 7.99 && c > 5.99) { return 42; }
    }
    return 1;
}
EOF
"$test_compiler" "$tmpdir/v2-dyld/f32.zag" --target macos-arm64 \
    --dynamic --no-zagd --no-analyze -o "$tmpdir/v2-dyld/f32"
require_macho_arm64 "$tmpdir/v2-dyld/f32"
require_signed "$tmpdir/v2-dyld/f32"
set +e
"$tmpdir/v2-dyld/f32"
v2_f32_status=$?
set -e
[ "$v2_f32_status" -eq 42 ]
echo "  ok  edition-2027 @cabi fixed f32/mixed-register libSystem imports"; pass=$((pass + 1))

cat >"$tmpdir/v2-dyld/callback.zag" <<'EOF'
extern fn qsort(base: *i64, n: i64, size: i64, cmp: fn(*i64,*i64)i32) void @cabi @borrows_mut;
fn compare(a: *i64, b: *i64) i32 {
    unsafe { if (a.* < b.*) { return -1; } if (a.* > b.*) { return 1; } }
    return 0;
}
fn main() i32 {
    unsafe {
        let p: *i64 = _zag_malloc(24) as *i64;
        p[0] = 9; p[1] = 2; p[2] = 5;
        qsort(p, 3, 8, compare);
        let ok: i32 = ((p[0] == 2) && (p[1] == 5) && (p[2] == 9)) as i32;
        _zag_free(p);
        if (ok == 1) { return 42; }
    }
    return 1;
}
EOF
"$test_compiler" "$tmpdir/v2-dyld/callback.zag" --target macos-arm64 \
    --dynamic --no-zagd --no-analyze -o "$tmpdir/v2-dyld/callback"
require_macho_arm64 "$tmpdir/v2-dyld/callback"
require_signed "$tmpdir/v2-dyld/callback"
set +e
"$tmpdir/v2-dyld/callback"
v2_callback_status=$?
set -e
[ "$v2_callback_status" -eq 42 ]
echo "  ok  edition-2027 @cabi direct captureless callback through libSystem qsort"; pass=$((pass + 1))

# The dyld writer is deliberately not a general linker. Unknown names and a
# known symbol declared with the wrong ABI must fail before any artifact exists.
if "$test_compiler" tests/macos_import_allowlist_negative.zag --target macos-arm64 --dynamic --no-zagd --no-analyze -o "$tmpdir/import-invalid" >"$tmpdir/import-invalid.log" 2>&1; then
    echo "XX  macOS target accepted imports outside its audited ABI allowlist" >&2
    exit 1
fi
test ! -e "$tmpdir/import-invalid"
grep -q 'unsupported external symbol or ABI: getpdi' "$tmpdir/import-invalid.log"
grep -q 'unsupported external symbol or ABI: getpid' "$tmpdir/import-invalid.log"
grep -q 'unsupported external symbol or ABI: sys_icache_invalidate' "$tmpdir/import-invalid.log"
grep -q 'unsupported external symbol or ABI: cosf' "$tmpdir/import-invalid.log"
echo "  ok  dyld import allowlist rejects unknown symbols and ABI mismatches"; pass=$((pass + 1))

"$test_compiler" tests/macos_objc_selector_u8.zag --target macos-arm64 --dynamic --no-zagd --no-analyze -o "$tmpdir/objc-selector-u8"
require_macho_arm64 "$tmpdir/objc-selector-u8"
require_signed "$tmpdir/objc-selector-u8"
set +e
"$tmpdir/objc-selector-u8"
selector_status=$?
set -e
[ "$selector_status" -eq 42 ]
echo "  ok  Objective-C char-pointer ABI admits audited u8 spelling"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_macos_hot_reload.sh
echo "  ok  Apple Silicon live text replacement and layout guard"; pass=$((pass + 1))

if "$test_compiler" examples/numeric.zag --target macos-arm64 --emit-obj --no-zagd --no-analyze -o "$tmpdir/not-an-object" >/dev/null 2>&1; then
    echo "XX  macOS target substituted an executable for an object request" >&2
    exit 1
fi
test ! -e "$tmpdir/not-an-object"
echo "  ok  legacy object request rejects without executable substitution"; pass=$((pass + 1))
env ZNC="$test_compiler" bash tests/run_macos_object.sh
env ZNC="$test_compiler" bash tests/run_macos_object_encoder.sh
echo "  ok  native Mach-O object/archive and bidirectional Apple C ABI"; pass=$((pass + 1))

env ZNC="$test_compiler" ZNC_TARGET=macos-arm64 bash tests/run_repr_c_layout.sh
echo "  ok  edition-2027 @repr(C) pointer layout and exact-width Apple-Silicon field access"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_macos_dylib.sh
echo "  ok  native dylib and custom dynamic executable production CLI"; pass=$((pass + 1))
env ZNC="$test_compiler" bash tests/run_macos_dylib_format.sh
echo "  ok  native dylib format, 305 exports, relocations and bounded dependency metadata"; pass=$((pass + 1))
env ZNC="$test_compiler" bash tests/run_macos_static_link.sh
echo "  ok  native ARM64 Mach-O object/archive input linking and static/dynamic composition"; pass=$((pass + 1))

# Inspect and execute debug images. Metadata-only inspection previously missed
# a Darwin segment-layout failure that killed an otherwise signed executable.
ZNC="$test_compiler" bash tests/run_macos_debug.sh
echo "  ok  native DWARF execution, dyld imports, and cache equivalence"; pass=$((pass + 1))

# GPU policy must preserve the platform boundary on macOS: Metal is identified
# explicitly and native physical execution must never select Linux DRM.
"$test_compiler" tests/gpu_platform.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/gpu-platform"
require_macho_arm64 "$tmpdir/gpu-platform"
require_signed "$tmpdir/gpu-platform"
"$tmpdir/gpu-platform" | grep -q 'GPU PLATFORM: ALL PASS'
"$test_compiler" tests/gfx1010_vm_fill.zag --target gpu-metal --no-zagd --no-analyze \
    -o "$tmpdir/gpu-metal-fill.metal"
grep -q 'kernel void fillKernel' "$tmpdir/gpu-metal-fill.metal"
test ! -e "$tmpdir/gpu_platform.mlir"
echo "  ok  Apple Silicon GPU policy: first-class native Metal target, no DRM fallback"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_compat_metal.sh
echo "  ok  Metal compatibility encoder and fail-closed kernel validation"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_macos_metal_native_profiles.sh
echo "  ok  first-class gpu-metal fill/depth/blend compiler and physical runtime parity"; pass=$((pass + 1))

# Physical Metal witnesses cross the public C/Objective-C ABI into
# Metal.framework and libobjc, then execute on the machine's actual GPU.  The
# final readback test submits a compute command and verifies that GPU-written
# shared-buffer data reaches the CPU.  An exit status of 42 is the fixture's
# success sentinel, not a generic process-success substitute.
for metal_test in macos_metal_device macos_metal_queue macos_metal_shader macos_metal_readback; do
    "$test_compiler" "$repo_root/tests/$metal_test.zag" --target macos-arm64 --dynamic --no-zagd --no-analyze -o "$tmpdir/$metal_test"
    require_macho_arm64 "$tmpdir/$metal_test"
    require_signed "$tmpdir/$metal_test"
    set +e
    "$tmpdir/$metal_test"
    metal_status=$?
    set -e
    if [ "$metal_status" -ne 42 ]; then
        echo "XX  physical Metal witness failed: $metal_test (exit $metal_status)" >&2
        exit 1
    fi
done
echo "  ok  physical Metal: device, queue, shader, compute/readback"; pass=$((pass + 1))

# Edition-2027 unsafe atomic fences lower directly to ARM64 DMB. This is a
# native memory-order witness, separate from Linux futex/thread adapters.
"$test_compiler" "$repo_root/tests/macos_v2/atomic_fence.zag" --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/atomic-fence"
require_macho_arm64 "$tmpdir/atomic-fence"
require_signed "$tmpdir/atomic-fence"
set +e
"$tmpdir/atomic-fence"
atomic_status=$?
set -e
[ "$atomic_status" -eq 42 ]
otool -tvV "$tmpdir/atomic-fence" | grep -q 'dmb'
echo "  ok  ARM64 native atomic and memory fences"; pass=$((pass + 1))

# RMW uses ARMv8 baseline LL/SC (not optional LSE): exchange, arithmetic,
# bitwise, CAS, ordered load/store, and seq_cst DMB boundaries all execute.
"$test_compiler" "$repo_root/tests/macos_v2/atomic_rmw.zag" --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/atomic-rmw"
require_macho_arm64 "$tmpdir/atomic-rmw"
require_signed "$tmpdir/atomic-rmw"
set +e
"$tmpdir/atomic-rmw"
atomic_rmw_status=$?
set -e
[ "$atomic_rmw_status" -eq 42 ]

# The public join-only thread surface is capability-equivalent to Linux on
# macOS, with compiler-owned pthread imports and an ARM64 callback trampoline.
# The gate also exercises checked-mode atomics from real worker threads.
env ZNC="$test_compiler" bash tests/run_macos_thread_spawn.sh
echo "  ok  pthread-backed thread spawn/join + checked atomic workers"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_macos_atomic_wait_wake.sh
echo "  ok  pthread-backed atomic wait/wake + exact wake counts"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_macos_machine_control.sh
echo "  ok  ARM64 volatile/MMIO, PRFM, and NEON i32x4 machine control"; pass=$((pass + 1))
env ZNC="$test_compiler" bash tests/run_macos_scalar_intrinsics.sh
echo "  ok  ARM64 scalar CPU intrinsics: popcount, andn, leading/trailing zeros, byte swap"; pass=$((pass + 1))
atomic_rmw_disasm="$(otool -tvV "$tmpdir/atomic-rmw")"
grep -q 'ldaxr' <<< "$atomic_rmw_disasm"
grep -q 'stlxr' <<< "$atomic_rmw_disasm"
grep -q 'ldar' <<< "$atomic_rmw_disasm"
grep -q 'stlr' <<< "$atomic_rmw_disasm"
echo "  ok  ARM64 native atomic RMW/CAS (LL/SC)"; pass=$((pass + 1))

# This fixture covers Darwin entry arguments, PIE data addresses, heap,
# write/read/exists, process execution, stdout, and exit status.
"$test_compiler" tests/macos_arm64_runtime.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/runtime"
require_macho_arm64 "$tmpdir/runtime"
require_signed "$tmpdir/runtime"
runtime_file="$tmpdir/runtime-roundtrip.txt"
output="$("$tmpdir/runtime" alpha beta "$runtime_file")"
[ "$output" = "macos-arm64-ok" ]
[ "$(cat "$runtime_file")" = "darwin-roundtrip" ]
echo "  ok  Darwin runtime: argv, heap, file I/O, process, stdout"; pass=$((pass + 1))

# XNU requires a non-null envp for execve. Exercise the bounded stdlib path,
# including its raw fork/pipe/exec/wait adapter, rather than only _zag_exec_cmd.
"$test_compiler" tests/macos_process_bounded_probe.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/process-bounded"
require_macho_arm64 "$tmpdir/process-bounded"
require_signed "$tmpdir/process-bounded"
set +e
"$tmpdir/process-bounded"
process_status=$?
set -e
[ "$process_status" -eq 42 ]
echo "  ok  Darwin bounded process: non-null envp and captured output"; pass=$((pass + 1))

"$test_compiler" script examples/script_hello.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/script-hello"
require_macho_arm64 "$tmpdir/script-hello"
require_signed "$tmpdir/script-hello"
[ "$("$tmpdir/script-hello")" = "Hello from Zag Script" ]
"$test_compiler" tests/macos_v2/script_context_policies.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/script-context"
require_macho_arm64 "$tmpdir/script-context"
require_signed "$tmpdir/script-context"
set +e
"$tmpdir/script-context"
script_context_status=$?
set -e
[ "$script_context_status" -eq 42 ]
echo "  ok  ARM64 Script context ABI: root wrapper, arena, bounded heap"; pass=$((pass + 1))

# Exercise every raw process primitive as a native Darwin witness. The final
# two cases prove unsupported fcntl tuples and oversized IDs return ENOSYS
# instead of wrapping into or aliasing a real XNU operation.
for raw_case in \
    macos_raw_pipe_probe:42 \
    macos_raw_pipe_exec_probe:42 \
    macos_raw_poll_probe:42 \
    macos_raw_nonblock_read_probe:35 \
    macos_raw_exec_probe:7 \
    macos_cache_raw_abi_negative:42 \
    macos_raw_fcntl_getfd:42 \
    macos_raw_fcntl_reject:42 \
    macos_raw_oversized_reject:42; do
    raw_name=${raw_case%:*}
    raw_expected=${raw_case#*:}
    "$test_compiler" "tests/$raw_name.zag" --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/$raw_name"
    require_macho_arm64 "$tmpdir/$raw_name"
    require_signed "$tmpdir/$raw_name"
    set +e
    "$tmpdir/$raw_name"
    raw_status=$?
    set -e
    [ "$raw_status" -eq "$raw_expected" ]
done
echo "  ok  Darwin raw process subset and fail-closed syscall IDs"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_macos_filesystem_abi.sh
echo "  ok  Darwin filesystem layouts, no-follow reads, executable identity"; pass=$((pass + 1))

if "$test_compiler" tests/macos_darwin_syscall_invalid.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/darwin-invalid" >"$tmpdir/darwin-invalid.log" 2>&1; then
    echo "XX  macOS target accepted an out-of-range Darwin syscall literal" >&2
    exit 1
fi
test ! -e "$tmpdir/darwin-invalid"
grep -q 'requires a non-negative integer literal number' "$tmpdir/darwin-invalid.log"
echo "  ok  explicit Darwin syscall boundary rejects negative and oversized IDs"; pass=$((pass + 1))

# Compiler-owned filesystem operations must not fall through to Linux syscall
# numbers merely because the compiler itself was self-hosted on Darwin.
cli_project="$tmpdir/znc-portability"
mkdir -p "$cli_project/.zag-cache/zagd/nested" "$cli_project/.zag-cache/foreground"
printf 'name = "znc-portability"\nversion = "0"\nedition = "2027"\n' >"$cli_project/zag.mod"
cp examples/script_hello.zag "$cli_project/app.zag"
printf 'zagd-cache\n' >"$cli_project/.zag-cache/zagd/nested/semantic.record"
printf 'foreground-cache\n' >"$cli_project/.zag-cache/foreground/machine.record"
printf 'profile\n' >"$cli_project/.zagd.profile"
printf 'keep\n' >"$cli_project/unrelated-sentinel"
"$test_compiler" clean-cache "$cli_project" >"$tmpdir/clean-cache.log" 2>&1
grep -q '^znc: cache purged$' "$tmpdir/clean-cache.log"
test ! -e "$cli_project/.zag-cache/zagd"
test ! -e "$cli_project/.zag-cache/foreground"
test ! -e "$cli_project/.zagd.profile"
test -f "$cli_project/unrelated-sentinel"

# Explicit expansion uses the module roots installed beside every generation.
published="$cli_project/output with ' quote.zag"
"$test_compiler" expand "$cli_project/app.zag" --to explicit --output "$published" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmpdir/expand-create.log" 2>&1
test -s "$published"
test -z "$(find "$cli_project" -maxdepth 1 -name '*.tmp.*' -print -quit)"

printf 'foreign-content\n' >"$cli_project/existing.zag"
if "$test_compiler" expand "$cli_project/app.zag" --to explicit \
    --output "$cli_project/existing.zag" --no-zagd --no-analyze --no-foreground-cache \
    >"$tmpdir/expand-existing.log" 2>&1; then
    echo "XX  Darwin explicit expansion replaced an existing output" >&2
    exit 1
fi
grep -q 'output already exists or is not safe' "$tmpdir/expand-existing.log"
test "$(cat "$cli_project/existing.zag")" = 'foreign-content'

dangling_target="$cli_project/dangling-target-must-not-exist"
ln -s "$dangling_target" "$cli_project/dangling-output.zag"
if "$test_compiler" expand "$cli_project/app.zag" --to explicit \
    --output "$cli_project/dangling-output.zag" --no-zagd --no-analyze --no-foreground-cache \
    >"$tmpdir/expand-dangling.log" 2>&1; then
    echo "XX  Darwin explicit expansion replaced a dangling symlink" >&2
    exit 1
fi
test -L "$cli_project/dangling-output.zag"
test "$(readlink "$cli_project/dangling-output.zag")" = "$dangling_target"
test ! -e "$dangling_target"

printf 'advisory=true\ntarget=macos-arm64\npid=999999999\nstate=idle\n' >"$cli_project/.zagd.status"
printf '999999999\n' >"$cli_project/.zagd.lock"
set +e
stale_status="$(cd "$cli_project" && "$test_compiler" status --format json 2>&1)"
stale_rc=$?
set -e
test "$stale_rc" -eq 1
[[ "$stale_status" == *'"running":false'* ]]
echo "  ok  Darwin compiler file adapters: purge, create-only output, stale status"; pass=$((pass + 1))

# zagd uses a Darwin-specific kqueue vnode adapter, with a bounded polling
# fallback only if native event setup fails. Exercise the same sibling-binary
# lifecycle a normal `znc watch` invocation uses: detached start, advisory
# status, and clean shutdown. The daemon is never part of foreground compiler
# correctness, but its platform adapter must not quietly regress to Linux
# inotify assumptions.
cp "$test_compiler" "$tmpdir/znc-macos-arm64"
"$tmpdir/znc-macos-arm64" selfhost/zagd_macos_daemon.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/zagd-macos-arm64"
require_macho_arm64 "$tmpdir/zagd-macos-arm64"
require_signed "$tmpdir/zagd-macos-arm64"
mkdir "$tmpdir/zagd-project"
# Keep watcher state inside this fixture even when the gate lives beneath
# the checkout; ancestor manifest discovery must not select the repository.
printf 'name = "macos-gate-watcher"\nversion = "0"\nedition = "2026"\n' \
    >"$tmpdir/zagd-project/zag.mod"
cp examples/numeric.zag "$tmpdir/zagd-project/main.zag"
(
    cd "$tmpdir/zagd-project"
    PATH="$tmpdir:$PATH" znc-macos-arm64 watch main.zag --mode light
    # Daemon startup includes the first foreground check and semantic-manifest
    # publication. A fixed sleep made this release gate depend on scheduler and
    # filesystem timing, so wait for the actual ready state instead.
    attempt=0
    status=""
    while [ "$attempt" -lt 200 ]; do
        status="$(PATH="$tmpdir:$PATH" znc-macos-arm64 status 2>&1 || true)"
        if [[ "$status" == *"state=idle"* ]] &&
           [[ "$status" == *"last_check_status=0"* ]] &&
           [[ "$status" == *"semantic_manifest=true"* ]]; then
            break
        fi
        sleep 0.05
        attempt=$((attempt + 1))
    done
    [[ "$status" == *"target=macos-arm64"* ]]
    [[ "$status" == *"watcher=kqueue-recursive"* ]]
    [[ "$status" == *"state=idle"* ]]
    [[ "$status" == *"last_check_status=0"* ]]
    [[ "$status" == *"semantic_manifest=true"* ]]
    [[ "$status" == *"trust_mode_scope=policy-only"* ]]
    [[ "$status" == *"optimizer_generation=bounded-finite-sandbox"* ]]

    # Prove that the suffixed daemon locates the suffixed compiler: one invalid
    # mutation must produce a failed check, then restoring the file must pass.
    printf '\nfn intentionally_broken(\n' >>main.zag
    attempt=0
    while [ "$attempt" -lt 100 ]; do
        status="$(PATH="$tmpdir:$PATH" znc-macos-arm64 status)"
        events=$(printf '%s\n' "$status" | awk -F= '$1 == "events" { print $2 }')
        check_status=$(printf '%s\n' "$status" | awk -F= '$1 == "last_check_status" { print $2 }')
        if [ "${events:-0}" -ge 1 ] && [ "${check_status:-0}" -ne 0 ]; then break; fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    [ "${events:-0}" -ge 1 ]
    [ "${check_status:-0}" -ne 0 ]
    [[ "$status" == *"semantic_manifest=false"* ]]

    cp "$repo_root/examples/numeric.zag" main.zag
    attempt=0
    while [ "$attempt" -lt 100 ]; do
        status="$(PATH="$tmpdir:$PATH" znc-macos-arm64 status)"
        events=$(printf '%s\n' "$status" | awk -F= '$1 == "events" { print $2 }')
        check_status=$(printf '%s\n' "$status" | awk -F= '$1 == "last_check_status" { print $2 }')
        if [ "${events:-0}" -ge 2 ] && [ "${check_status:-1}" -eq 0 ]; then break; fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    [ "${events:-0}" -ge 2 ]
    [ "${check_status:-1}" -eq 0 ]
    [[ "$status" == *"semantic_manifest=true"* ]]
    PATH="$tmpdir:$PATH" znc-macos-arm64 shutdown
)
[ "$(grep '^state=' "$tmpdir/zagd-project/.zagd.status")" = "state=stopped" ]
[ ! -e "$tmpdir/zagd-project/.zagd.lock" ]
echo "  ok  Darwin zagd lifecycle: PATH companions, mutation checks, shutdown"; pass=$((pass + 1))

# The protocol parsers are platform-neutral, but their release artifacts are
# not. Prove the same strict HTTP, WebSocket, and DNS corpora execute as signed
# native Mach-O rather than leaving this coverage behind a Linux-only gate.
env ZNC="$test_compiler" bash tests/run_protocol_codecs.sh
echo "  ok  Darwin native HTTP, WebSocket, and DNS protocol codecs"; pass=$((pass + 1))

# SQLite is a target-owned system import on Darwin rather than a Linux SONAME
# compatibility path. Exercise both the shared KV conformance and the two
# reference applications as signed Mach-O, including exact libSystem/sqlite3
# dependency metadata and fail-closed caller-selected dylib requests.
env ZNC="$test_compiler" bash tests/run_database_drivers.sh
env ZNC="$test_compiler" bash tests/run_reference_sqlite_kv.sh
env ZNC="$test_compiler" bash tests/run_reference_sqlite_http_service.sh
echo "  ok  Darwin native bounded SQLite KV and HTTP reference services"; pass=$((pass + 1))

# Configuration parsing is pure Zag and structured logging uses the audited
# cross-platform write contract. Exercise the exact stderr record on Darwin,
# including allocation accounting and signed-artifact validation.
env ZNC="$test_compiler" bash tests/run_config_log_services.sh
echo "  ok  Darwin native configuration and structured logging"; pass=$((pass + 1))

# The machine-code cache has the same checksum, bounded-read, no-follow,
# concurrent-publication, invalidation, and payload-substitution contract on
# Darwin. Its raw file adapter translates only the exact operations used here.
env ZNC="$test_compiler" bash tests/run_foreground_cache_integration.sh
echo "  ok  Darwin foreground cache: hits, invalidation, corruption, races"; pass=$((pass + 1))

env ZNC="$test_compiler" bash tests/run_macos_checked_safety.sh
echo "  ok  Darwin checked-pointer and bounded memory-sanitizer modes"; pass=$((pass + 1))

# The broad v1 ARM64 corpus is shared with Linux, but every row here is compiled
# by the fixed-point compiler as a signed native Mach-O and executes through the
# Darwin loader/runtime. ELF, Linux open-flag, and ET_REL checks remain in the
# Linux-only tail of the shared script.
env ZNC="$test_compiler" bash tests/run_native_arm64.sh
echo "  ok  broad portable ARM64 v1 corpus as signed native Mach-O"; pass=$((pass + 1))

# These claim-producing components must finish before the verified compiler
# can be published. Keep the same source-qualified compiler and installed
# module roots for every component; a separately passing old seed is not proof.
for component in \
    run_param_contracts \
    run_v2_aggregate_provenance \
    run_v2_try_borrow \
    run_resource_affine \
    run_macos_network_tls_probe \
    run_macos_network_tls_handshake \
    run_reference_tls_http_service_macos \
    run_os_macos_services \
    run_reference_dynamic_plugin_macos \
    run_macos_concurrency_services \
    run_abi_layout \
    run_arm64_memory_offsets \
    run_arm64_rt_builtins \
    run_arm64_allocator_reuse \
    run_arm64_allocator_arena_overlap \
    run_macos_metal_loader \
    run_macos_network_abi \
    run_macos_link_options \
    run_macos_hot_reload \
    run_zagd_macos_resource_stress \
    run_macos_zagscript_authority \
    run_release_package_layout; do
    if env ZNC="$test_compiler" ZAGD="$tmpdir/zagd-macos-arm64" \
        bash "tests/$component.sh" >"$tmpdir/$component.log" 2>&1; then
        tail -n 4 "$tmpdir/$component.log"
        echo "  ok  native product component: $component"; pass=$((pass + 1))
    else
        echo "XX  native product component failed: $component" >&2
        tail -n 160 "$tmpdir/$component.log" >&2
        exit 1
    fi
done

"$test_compiler" selfhost/lsp/zag-lsp.zag --target macos-arm64 \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/zag-lsp-macos-arm64"
require_macho_arm64 "$tmpdir/zag-lsp-macos-arm64"
require_signed "$tmpdir/zag-lsp-macos-arm64"
env ZNC="$test_compiler" ZAG_LSP="$tmpdir/zag-lsp-macos-arm64" bash tests/test_lsp.sh
echo "  ok  native macOS language-server protocol"; pass=$((pass + 1))

env ZNC="$test_compiler" ZAGD="$tmpdir/zagd-macos-arm64" \
    ZAG_LSP="$tmpdir/zag-lsp-macos-arm64" bash tests/run_zagscript_install_layout.sh
echo "  ok  production install recipe and installed native standard library"; pass=$((pass + 1))

# The clean-checkout intake must accept this gate's signed fixed-point compiler
# with its exact checksum and reject even a well-formed but mismatched digest,
# without modifying checkout tool paths in verification-only mode.
shasum -a 256 "$test_compiler" >"$tmpdir/verified-seed.sha256"
bash tools/bootstrap-macos-seed.sh --verify-only \
    "$test_compiler" "$tmpdir/verified-seed.sha256"
printf '%064d  znc-macos-arm64\n' 0 >"$tmpdir/wrong-seed.sha256"
if bash tools/bootstrap-macos-seed.sh --verify-only \
    "$test_compiler" "$tmpdir/wrong-seed.sha256" \
    >"$tmpdir/wrong-seed.log" 2>&1; then
    echo "XX  macOS seed intake accepted a mismatched checksum" >&2
    exit 1
fi
grep -q 'seed checksum mismatch' "$tmpdir/wrong-seed.log"
echo "  ok  clean-checkout seed intake verifies identity and rejects mismatch"; pass=$((pass + 1))

# CI may request the compiler that actually carried the complete native gate.
# Publish only here, after every positive, negative, fixed-point, runtime, GPU,
# daemon, and portable-service witness has passed. The cross-built input is a
# bootstrap precursor and must never be mislabeled as this verified output.
require_unchanged_source
if [ -n "${ZAG_MACOS_VERIFIED_COMPILER_OUTPUT:-}" ]; then
    verified_parent=$(dirname "$ZAG_MACOS_VERIFIED_COMPILER_OUTPUT")
    if [ ! -d "$verified_parent" ]; then
        echo "XX  verified compiler output directory does not exist: $verified_parent" >&2
        exit 1
    fi
    if [ -e "$ZAG_MACOS_VERIFIED_COMPILER_OUTPUT" ]; then
        echo "XX  refusing to replace verified compiler output: $ZAG_MACOS_VERIFIED_COMPILER_OUTPUT" >&2
        exit 1
    fi
    COPYFILE_DISABLE=1 cp "$test_compiler" "$ZAG_MACOS_VERIFIED_COMPILER_OUTPUT"
    chmod 755 "$ZAG_MACOS_VERIFIED_COMPILER_OUTPUT"
    cmp -s "$test_compiler" "$ZAG_MACOS_VERIFIED_COMPILER_OUTPUT"
    require_macho_arm64 "$ZAG_MACOS_VERIFIED_COMPILER_OUTPUT"
    require_signed "$ZAG_MACOS_VERIFIED_COMPILER_OUTPUT"
    echo "  ok  published full-gate compiler: $ZAG_MACOS_VERIFIED_COMPILER_OUTPUT"
fi

echo "════ macos-arm64-release pass=$pass fail=0 ════"
