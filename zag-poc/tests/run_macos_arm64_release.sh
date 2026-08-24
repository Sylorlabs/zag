#!/usr/bin/env bash
# Native macOS Apple-Silicon release gate.  This intentionally exercises the
# Darwin kernel, Mach-O loader, and embedded signature rather than assuming
# that the Linux/AArch64 ELF tests prove the macOS target.
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root=$PWD

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "XX  macos-arm64 release gate requires native Apple Silicon (got $(uname -s) $(uname -m))" >&2
    exit 2
fi

ZNC="${ZNC:-$PWD/znc-macos-arm64}"
if [ ! -x "$ZNC" ]; then
    echo "XX  compiler is not executable: $ZNC" >&2
    exit 2
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-arm64.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
pass=0

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
"$ZNC" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-gen1"
require_macho_arm64 "$tmpdir/znc-gen1"
require_signed "$tmpdir/znc-gen1"
echo "  ok  signed Mach-O arm64 self-host compiler"; pass=$((pass + 1))

# The first generated compiler incorporates the current source graph and can
# differ from the trusted seed.  The next two native stages must be identical:
# this is the same fixed-point criterion used by bootstrap.sh.
"$tmpdir/znc-gen1" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-gen2"
require_macho_arm64 "$tmpdir/znc-gen2"
require_signed "$tmpdir/znc-gen2"
"$tmpdir/znc-gen2" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-gen3"
require_macho_arm64 "$tmpdir/znc-gen3"
require_signed "$tmpdir/znc-gen3"
cmp -s "$tmpdir/znc-gen2" "$tmpdir/znc-gen3"
test_compiler="$tmpdir/znc-gen2"
echo "  ok  native Darwin self-host fixpoint"; pass=$((pass + 1))

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

# The dyld writer is deliberately not a general linker. Unknown names and a
# known symbol declared with the wrong ABI must fail before any artifact exists.
if "$test_compiler" tests/macos_import_allowlist_negative.zag --target macos-arm64 --dynamic --no-zagd --no-analyze -o "$tmpdir/import-invalid" >"$tmpdir/import-invalid.log" 2>&1; then
    echo "XX  macOS target accepted imports outside its audited ABI allowlist" >&2
    exit 1
fi
test ! -e "$tmpdir/import-invalid"
grep -q 'unsupported external symbol or ABI: getpdi' "$tmpdir/import-invalid.log"
grep -q 'unsupported external symbol or ABI: getpid' "$tmpdir/import-invalid.log"
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

if "$test_compiler" hot-patch examples/numeric.zag --target macos-arm64 >/dev/null 2>&1; then
    echo "XX  macOS target entered the Linux/x86 hot-patch path" >&2
    exit 1
fi
echo "  ok  Apple Silicon hot reload: unsupported native path rejects cleanly"; pass=$((pass + 1))

if "$test_compiler" examples/numeric.zag --target macos-arm64 --emit-obj --no-zagd --no-analyze -o "$tmpdir/not-an-object" >/dev/null 2>&1; then
    echo "XX  macOS target substituted an executable for an object request" >&2
    exit 1
fi
test ! -e "$tmpdir/not-an-object"
echo "  ok  Apple Silicon object/archive requests reject without substitution"; pass=$((pass + 1))

# Mach-O debug output carries the same self-hosted DWARF metadata in a native
# __DWARF segment and remains ad-hoc signed after debug bytes are appended.
"$test_compiler" examples/numeric.zag --target macos-arm64 --debug --no-zagd --no-analyze -o "$tmpdir/debug"
require_macho_arm64 "$tmpdir/debug"
require_signed "$tmpdir/debug"
otool -l "$tmpdir/debug" | grep -q '__DWARF'
dwarfdump "$tmpdir/debug" | grep -q 'DW_TAG_compile_unit'
echo "  ok  Mach-O native DWARF debug segment"; pass=$((pass + 1))

# GPU policy must preserve the platform boundary on macOS: Metal is identified
# explicitly and native physical execution must never select Linux DRM.
"$test_compiler" tests/gpu_platform.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/gpu-platform"
require_macho_arm64 "$tmpdir/gpu-platform"
require_signed "$tmpdir/gpu-platform"
"$tmpdir/gpu-platform" | grep -q 'GPU PLATFORM: ALL PASS'
if ( cd "$tmpdir" && "$test_compiler" "$repo_root/tests/gpu_platform.zag" --target gpu-metal --no-zagd --no-analyze ) >/dev/null 2>&1; then
    echo "XX  gpu-metal unexpectedly emitted a non-Metal artifact" >&2
    exit 1
fi
test ! -e "$tmpdir/gpu_platform.mlir"
echo "  ok  Apple Silicon GPU policy: explicit Metal, no DRM fallback"; pass=$((pass + 1))

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

# Explicit expansion imports the installed std surface relative to the compiler
# directory. Mirror that install layout for the self-hosted temporary compiler.
ln -s "$repo_root/std" "$tmpdir/std"
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
cp examples/numeric.zag "$tmpdir/zagd-project/main.zag"
(
    cd "$tmpdir/zagd-project"
    PATH="$tmpdir:$PATH" znc-macos-arm64 watch main.zag --mode light
    sleep 1
    status="$(PATH="$tmpdir:$PATH" znc-macos-arm64 status)"
    [[ "$status" == *"target=macos-arm64"* ]]
    [[ "$status" == *"watcher=kqueue-recursive"* ]]
    [[ "$status" == *"state=idle"* ]]
    [[ "$status" == *"last_check_status=0"* ]]
    [[ "$status" == *"semantic_manifest=true"* ]]
    [[ "$status" == *"trust_mode_scope=policy-only"* ]]
    [[ "$status" == *"optimizer_generation=unimplemented"* ]]

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

echo "════ macos-arm64-release pass=$pass fail=0 ════"
