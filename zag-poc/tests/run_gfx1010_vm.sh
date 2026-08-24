#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
ZNC="${ZNC:-./znc}"
"$ZNC" tests/gfx1010_vm_fill.zag --target amdgpu-gfx1010 \
    -o /tmp/zag_gfx1010_vm_fill.zgk
"$ZNC" tests/gfx1010_vm_depth.zag --target amdgpu-gfx1010 \
    -o /tmp/zag_gfx1010_vm_depth.zgk
"$ZNC" tests/gfx1010_vm_blend.zag --target amdgpu-gfx1010 \
    -o /tmp/zag_gfx1010_vm_blend.zgk
"$ZNC" tests/gfx1010_vm.zag -o /tmp/zag_gfx1010_vm_test
/tmp/zag_gfx1010_vm_test
