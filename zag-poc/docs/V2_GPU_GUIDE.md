# Zag v2 GPU guide (draft)

Zag currently executes GPU kernels via two verified compat-tier backends:
**Vulkan** (SPIR-V) and **OpenGL** (GLSL 430). Both have been runtime-verified
on an AMD RX 5700 XT — the kernel is dispatched on the physical GPU and the
output is checked for correctness. See `tests/run_gpu_runtime.sh` for the
end-to-end test.

Three other compat backends (OpenCL, CUDA, Metal) have encoder and loader
code written but are **not runtime-verified** because the current developer's
machine (Linux, AMD GPU) does not have the required hardware/drivers. See
`docs/V2_TARGET_SUPPORT.md` for the contributor call for hardware testing.

MLIR text, deterministic bundles, and the virtual GPU model remain
compilation/validation aids, not a device runtime. Do not use them to claim
device enumeration, allocation, dispatch, barriers, or checked readback.

The first native physical backend is planned as an opt-in direct Linux AMDGPU
DRM adapter for the native `amdgpu-gfx1010` target. A test begins with an
explicitly selected render node, tiny buffers, a conservative one-workgroup
dispatch, a driver fence timeout, strict host bounds, and full cleanup. On the
display-bound AMD RX 5700 XT it must never submit an unbounded workload.
Absence of a compatible device is an explicit skip with the discovered reason;
a compatible device requires checked CPU-vs-GPU output before it is counted as
operational.

Device code must use typed host/device/workgroup/private/constant address
spaces, a bounded kernel domain, and barrier-safe uniform control flow.  Host
allocation, OS I/O, dynamic loading, and arbitrary FFI remain invalid in device
code even inside `unsafe`.
