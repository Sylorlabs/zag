#!/usr/bin/env bash
# Scalar AArch64 memory-immediate boundary and large-frame runtime regression.
set -euo pipefail
cd "$(dirname "$0")/.."

native_compiler=./znc
native_target_args=()
program_target_args=(--target arm64)
runner=""
case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
        native_compiler=./znc-macos-arm64
        native_target_args=(--target macos-arm64)
        program_target_args=(--target macos-arm64)
        ;;
    Linux:aarch64|Linux:arm64)
        native_compiler=./znc-linux-arm64
        native_target_args=(--target arm64)
        ;;
    Linux:x86_64|Linux:amd64)
        arm_runner=${QEMU_AARCH64:-/usr/bin/qemu-aarch64-static}
        if [ ! -x "$arm_runner" ]; then
            echo "arm64 memory offsets: AArch64 runner unavailable: $arm_runner" >&2
            exit 1
        fi
        runner=$arm_runner
        ;;
    *)
        echo "arm64 memory offsets: unsupported host: $(uname -s) $(uname -m)" >&2
        exit 1
        ;;
esac

compiler=${ZNC:-$native_compiler}
test -x "$compiler"
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-arm64-memory-offsets.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

"$compiler" tests/aarch64_memory_offset_encoder.zag \
    "${native_target_args[@]}" -o "$work/encoder" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$work/encoder"
echo "  ok  scalar 64/32/16/8-bit encoder boundaries and scratch conflicts"

"$compiler" tests/arm64_large_frame_offsets.zag \
    "${program_target_args[@]}" -o "$work/large-frame" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
if [ -n "$runner" ]; then "$runner" "$work/large-frame"; else "$work/large-frame"; fi
large_frame_status=$?
set -e
if [ "$large_frame_status" -ne 42 ]; then
    echo "  XX  >32-word ARM64 frame (exit $large_frame_status, expected 42)" >&2
    exit 1
fi
echo "  ok  >32-word ARM64 frame loads and stores"
echo "arm64 memory offsets: pass"
