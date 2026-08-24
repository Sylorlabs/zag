#!/usr/bin/env bash
# Pure-Zag loader gate.  This proves the public Vulkan/OpenGL/OpenCL adapters
# compile and execute through their real system loaders, not just through the
# C diagnostic harness.  The test is intentionally bounded to one 1024-item
# fill and uses exit_group because ROCm keeps worker threads alive after the
# native Zag main return syscall.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-pure-gpu-runtime.XXXXXX)
trap 'find "$tmp" -type f -delete 2>/dev/null || true; find "$tmp" -type l -delete 2>/dev/null || true; find "$tmp" -depth -type d -empty -delete 2>/dev/null || true' EXIT
mkdir "$tmp/std"
ln -s "$PWD/std/vulkan_loader.zag" "$tmp/std/vulkan_loader.zag"
ln -s "$PWD/std/vulkan_runtime.zag" "$tmp/std/vulkan_runtime.zag"
ln -s "$PWD/std/gpu_compat_contract.zag" "$tmp/std/gpu_compat_contract.zag"
ln -s "$PWD/std/opengl_loader.zag" "$tmp/std/opengl_loader.zag"
ln -s "$PWD/std/opengl_runtime.zag" "$tmp/std/opengl_runtime.zag"
ln -s "$PWD/std/opencl_loader.zag" "$tmp/std/opencl_loader.zag"
ln -s "$PWD/std/opencl_runtime.zag" "$tmp/std/opencl_runtime.zag"
cp "$PWD/tests/gpu_compat_runtime.zag" "$tmp/main.zag"
printf '%s\n' 'name = "gpucompat"' 'version = "0"' 'edition = "2027"' >"$tmp/zag.mod"
(cd "$tmp" && "$ZNC" main.zag --no-analyze --no-zagd -o gpu-compat-runtime \
    --dynamic --needed libpthread.so.0 --needed libvulkan.so.1 \
    --needed libEGL.so.1 --needed libGL.so.1 --needed libOpenCL.so.1 \
    --needed libc.so.6 >/dev/null)
if timeout "${ZAG_GPU_TIMEOUT_SECONDS:-30}s" "$tmp/gpu-compat-runtime"; then
    echo "Pure-Zag GPU runtime: ALL PASS (Vulkan/OpenGL/OpenCL)"
else
    rc=$?
    echo "Pure-Zag GPU runtime: FAIL (exit=$rc)" >&2
    exit "$rc"
fi
