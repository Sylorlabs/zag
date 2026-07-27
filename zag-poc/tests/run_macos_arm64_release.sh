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

ZNC="${ZNC:-$PWD/znc}"
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

# A compiler executing natively on Darwin must reproduce itself exactly.
"$tmpdir/znc-gen1" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-gen2"
require_macho_arm64 "$tmpdir/znc-gen2"
require_signed "$tmpdir/znc-gen2"
cmp -s "$tmpdir/znc-gen1" "$tmpdir/znc-gen2"
echo "  ok  native Darwin self-host fixpoint"; pass=$((pass + 1))

# Exercise the signer independently of the compiler-sized artifact.
"$tmpdir/znc-gen1" selfhost/native/macho_arm64_test.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/macho-sign-test"
require_macho_arm64 "$tmpdir/macho-sign-test"
require_signed "$tmpdir/macho-sign-test"
"$tmpdir/macho-sign-test"
echo "  ok  Mach-O SHA-256 signer regression"; pass=$((pass + 1))

# CPU selection on Apple Silicon must be native arm64 policy, not the Linux
# x86 /proc/CPUID path. Named Apple profiles currently share the proven arm64
# baseline; unrelated profiles fail before an artifact is produced.
"$tmpdir/znc-gen1" examples/numeric.zag --target macos-arm64 --cpu=native --no-zagd --no-analyze -o "$tmpdir/cpu-native"
require_macho_arm64 "$tmpdir/cpu-native"
if "$tmpdir/znc-gen1" examples/numeric.zag --target macos-arm64 --cpu=x86-64-v1 --no-zagd --no-analyze -o "$tmpdir/cpu-invalid" >/dev/null 2>&1; then
    echo "XX  macOS target accepted an x86 CPU profile" >&2
    exit 1
fi
test ! -e "$tmpdir/cpu-invalid"
echo "  ok  Apple Silicon CPU policy: native baseline and x86 rejection"; pass=$((pass + 1))

if "$tmpdir/znc-gen1" hot-patch examples/numeric.zag --target macos-arm64 >/dev/null 2>&1; then
    echo "XX  macOS target entered the Linux/x86 hot-patch path" >&2
    exit 1
fi
echo "  ok  Apple Silicon hot reload: unsupported native path rejects cleanly"; pass=$((pass + 1))

if "$tmpdir/znc-gen1" examples/numeric.zag --target macos-arm64 --emit-obj --no-zagd --no-analyze -o "$tmpdir/not-an-object" >/dev/null 2>&1; then
    echo "XX  macOS target substituted an executable for an object request" >&2
    exit 1
fi
test ! -e "$tmpdir/not-an-object"
echo "  ok  Apple Silicon object/archive requests reject without substitution"; pass=$((pass + 1))

# Mach-O debug output carries the same self-hosted DWARF metadata in a native
# __DWARF segment and remains ad-hoc signed after debug bytes are appended.
"$tmpdir/znc-gen1" examples/numeric.zag --target macos-arm64 --debug --no-zagd --no-analyze -o "$tmpdir/debug"
require_macho_arm64 "$tmpdir/debug"
require_signed "$tmpdir/debug"
otool -l "$tmpdir/debug" | grep -q '__DWARF'
dwarfdump "$tmpdir/debug" | grep -q 'DW_TAG_compile_unit'
echo "  ok  Mach-O native DWARF debug segment"; pass=$((pass + 1))

# GPU policy must preserve the platform boundary on macOS: Metal is identified
# explicitly, while physical execution stays unavailable until the native
# Metal compiler/queue/readback path exists. It must never select Linux DRM.
"$tmpdir/znc-gen1" tests/gpu_platform.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/gpu-platform"
require_macho_arm64 "$tmpdir/gpu-platform"
require_signed "$tmpdir/gpu-platform"
"$tmpdir/gpu-platform" | grep -q 'GPU PLATFORM: ALL PASS'
if ( cd "$tmpdir" && "$tmpdir/znc-gen1" "$repo_root/tests/gpu_platform.zag" --target gpu-metal --no-zagd --no-analyze ) >/dev/null 2>&1; then
    echo "XX  gpu-metal unexpectedly emitted a non-Metal artifact" >&2
    exit 1
fi
test ! -e "$tmpdir/gpu_platform.mlir"
echo "  ok  Apple Silicon GPU policy: explicit Metal, no DRM fallback"; pass=$((pass + 1))

# This fixture covers Darwin entry arguments, PIE data addresses, heap,
# write/read/exists, process execution, stdout, and exit status.
"$tmpdir/znc-gen1" tests/macos_arm64_runtime.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/runtime"
require_macho_arm64 "$tmpdir/runtime"
require_signed "$tmpdir/runtime"
output="$("$tmpdir/runtime" alpha beta)"
[ "$output" = "macos-arm64-ok" ]
[ "$(cat /tmp/zag_macos_arm64_runtime.txt)" = "darwin-roundtrip" ]
rm -f /tmp/zag_macos_arm64_runtime.txt
echo "  ok  Darwin runtime: argv, heap, file I/O, process, stdout"; pass=$((pass + 1))

# zagd uses a Darwin-specific kqueue vnode adapter, with a bounded polling
# fallback only if native event setup fails. Exercise the same sibling-binary
# lifecycle a normal `znc watch` invocation uses: detached start, advisory
# status, and clean shutdown. The daemon is never part of foreground compiler
# correctness, but its platform adapter must not quietly regress to Linux
# inotify assumptions.
"$tmpdir/znc-gen1" selfhost/zagd_macos_daemon.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/zagd"
require_macho_arm64 "$tmpdir/zagd"
require_signed "$tmpdir/zagd"
mkdir "$tmpdir/zagd-project"
cp examples/numeric.zag "$tmpdir/zagd-project/main.zag"
(
    cd "$tmpdir/zagd-project"
    "$tmpdir/znc-gen1" watch main.zag --mode light
    sleep 1
    status="$("$tmpdir/znc-gen1" status)"
    [[ "$status" == *"target=macos-arm64"* ]]
    [[ "$status" == *"watcher=kqueue-root"* ]]
    [[ "$status" == *"state=idle"* ]]
    "$tmpdir/znc-gen1" shutdown
)
[ "$(grep '^state=' "$tmpdir/zagd-project/.zagd.status")" = "state=stopped" ]
[ ! -e "$tmpdir/zagd-project/.zagd.lock" ]
echo "  ok  Darwin zagd lifecycle: watch, status, shutdown"; pass=$((pass + 1))

echo "════ macos-arm64-release pass=$pass fail=0 ════"
