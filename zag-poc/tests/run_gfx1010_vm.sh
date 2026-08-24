#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
ZNC="${ZNC:-$(zag_native_compiler "$PWD")}"
case "$ZNC" in
    /*) ;;
    *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-gfx1010-vm.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$ZNC" tests/gfx1010_vm_fill.zag --target amdgpu-gfx1010 \
    -o "$tmp/fill.zgk"
"$ZNC" tests/gfx1010_vm_depth.zag --target amdgpu-gfx1010 \
    -o "$tmp/depth.zgk"
"$ZNC" tests/gfx1010_vm_blend.zag --target amdgpu-gfx1010 \
    -o "$tmp/blend.zgk"
"$ZNC" tests/gfx1010_vm.zag -o "$tmp/test"
"$tmp/test" "$tmp/fill.zgk" "$tmp/depth.zgk" "$tmp/blend.zgk"
