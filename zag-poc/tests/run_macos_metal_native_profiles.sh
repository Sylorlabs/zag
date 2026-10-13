#!/usr/bin/env bash
# First-class gpu-metal compiler + physical Apple-Silicon execution gate.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s):$(uname -m)" != "Darwin:arm64" ]; then
    echo 'macOS native Metal profiles: unsupported host (requires physical Apple Silicon macOS)' >&2
    exit 1
fi

compiler=${ZNC:-./znc-macos-arm64}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
if [ ! -x "$compiler" ]; then
    echo "XX  native macOS compiler not executable: $compiler" >&2
    exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/zag-metal-native.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

"$compiler" tests/gfx1010_vm_fill.zag --target gpu-metal --no-zagd --no-analyze -o "$tmpdir/fill-a.metal"
"$compiler" tests/gfx1010_vm_fill.zag --target gpu-metal --no-zagd --no-analyze -o "$tmpdir/fill-b.metal"
"$compiler" tests/gfx1010_vm_depth.zag --target gpu-metal --no-zagd --no-analyze -o "$tmpdir/depth.metal"
"$compiler" tests/gfx1010_vm_blend.zag --target gpu-metal --no-zagd --no-analyze -o "$tmpdir/blend.metal"

cmp -s "$tmpdir/fill-a.metal" "$tmpdir/fill-b.metal"
grep -q 'kernel void fillKernel' "$tmpdir/fill-a.metal"
grep -q 'kernel void depthWriteKernel' "$tmpdir/depth.metal"
grep -q 'device int\* depth \[\[buffer(1)\]\]' "$tmpdir/depth.metal"
grep -q 'kernel void blendDepthKernel' "$tmpdir/blend.metal"
grep -q 'constant int& alpha \[\[buffer(4)\]\]' "$tmpdir/blend.metal"
grep -q '256 - alpha' "$tmpdir/blend.metal"

# The compatibility spelling remains deterministic and semantically identical
# for the original fill profile, but gpu-metal is the first-class target.
"$compiler" tests/gfx1010_vm_fill.zag --target metal-compat --no-zagd --no-analyze -o "$tmpdir/fill-compat.metal"
cmp -s "$tmpdir/fill-a.metal" "$tmpdir/fill-compat.metal"

rm -f "$tmpdir/bad.metal"
if "$compiler" tests/gpu_metal_bad.zag --target gpu-metal --no-zagd --no-analyze -o "$tmpdir/bad.metal" >/dev/null 2>&1; then
    echo 'XX  gpu-metal accepted an unsupported kernel' >&2
    exit 1
fi
test ! -e "$tmpdir/bad.metal"

"$compiler" tests/macos_metal_native_profiles.zag --target macos-arm64 \
    --dynamic --no-zagd --no-analyze -o "$tmpdir/native-profiles"
file "$tmpdir/native-profiles" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict "$tmpdir/native-profiles"
otool -L "$tmpdir/native-profiles" | grep -q '/Metal.framework/'

set +e
"$tmpdir/native-profiles" "$tmpdir/depth.metal" "$tmpdir/blend.metal"
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "XX  native Metal fill/depth/blend profile witness exited $status" >&2
    exit 1
fi

echo '  ok  gpu-metal emits deterministic native MSL without a compatibility-only target'
echo '  ok  native Metal depth-write matches the reviewed Linux GFX10.1 profile'
echo '  ok  native Metal fixed-point RGB blend matches alpha 0/128/256 semantics and rejects alpha 257'
echo '════ macos-metal-native-profiles pass=3 fail=0 ════'
