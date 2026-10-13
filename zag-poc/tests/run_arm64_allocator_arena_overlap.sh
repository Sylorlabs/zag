#!/usr/bin/env bash
# Execute the emitted allocator's arena-overlap cleanup with deterministic
# registry contents; do not depend on mmap randomly reusing a particular hole.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
test -x "$compiler"
runner=(env)
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) platform=macos-arm64 ;;
    Linux:aarch64|Linux:arm64) platform=linux-arm64 ;;
    Linux:x86_64|Linux:amd64)
        platform=linux-arm64
        qemu=${QEMU:-qemu-aarch64-static}
        command -v "$qemu" >/dev/null
        runner=("$qemu")
        ;;
    *) echo 'ARM64 allocator arena overlap: unsupported host' >&2; exit 2 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-arm64-arena-overlap.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
zag_run_bounded 360 "$compiler" tests/arm64_allocator_arena_overlap.zag \
    --no-zagd --no-analyze --no-foreground-cache -o "$work/emitter"
zag_run_bounded 30 "$work/emitter" "$work/overlap" "$platform"
if [ "$platform" = macos-arm64 ]; then
    file "$work/overlap" | grep -q 'Mach-O 64-bit executable arm64'
    codesign --verify --deep --strict "$work/overlap"
else
    file "$work/overlap" | grep -q 'ELF 64-bit LSB executable, ARM aarch64'
fi
set +e
zag_run_bounded 30 "${runner[@]}" "$work/overlap"
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "ARM64 allocator arena overlap: failed (exit $status, expected 42)" >&2
    exit 1
fi
echo 'ARM64 allocator arena overlap: PASS base+interior+multiple+boundaries+live-preservation'
