# Zag v2 GPU guide (draft)

Zag has runtime-verified compatibility paths on both supported desktop host
families. Linux uses **Vulkan** (SPIR-V), **OpenGL** (GLSL 430), and OpenCL;
Apple Silicon macOS uses **Metal** (MSL) through the public pure-Zag
`std:metal_loader` adapter. The Linux generated runtime harnesses compile
against the installed RADV/Mesa/ROCm loaders and perform a tiny, bounded
dispatch when explicitly enabled. Run
`ZAG_RUN_PHYSICAL_GPU=1 bash tests/run_gpu_runtime.sh` to perform the bounded
physical execution and checked readback; this machine has passed Vulkan,
OpenGL, and OpenCL on its AMD RX 5700 XT. Run
`bash tests/run_gpu_zag_runtime.sh` to exercise the same public loader
adapters from a pure-Zag driver. On Apple Silicon both generic runtime entry
points route to the native Metal adapter, which performs device/queue discovery,
a 4 KiB shared-memory roundtrip, runtime MSL compilation, bounded dispatch,
completion, and checked readback without requiring Xcode's offline compiler.

OpenCL has a SPIR-V encoder, a pure-Zag OpenCL-C fallback emitter, and a
capability-probed runtime harness. The ROCm OpenCL ICD is installed on this
machine and exposes the RX 5700 XT; its physical dispatch is verified but
still explicit and bounded. CUDA (NVIDIA hardware) remains artifact-only. Metal
is a verified runtime path on physical Apple Silicon. See
`docs/V2_TARGET_SUPPORT.md` for the exact matrix.

MLIR text, deterministic bundles, and the virtual GPU model remain
compilation/validation aids, not a device runtime. Do not use them to claim
device enumeration, allocation, dispatch, barriers, or checked readback.
The MLIR path does not currently execute a GPU kernel; the bounded runtime
evidence below belongs to the separate compatibility runtime gates, including
Metal on macOS.

The first native physical backend is planned as an opt-in direct Linux AMDGPU DRM
adapter for the native `amdgpu-gfx1010` target. The current `tests/run_linux_drm.sh`
boundary stops at a live render-node/IP query, bounded GPUVM map/unmap, and a
4 KiB CPU memory roundtrip. On the display-bound AMD RX 5700 XT it requires
explicit override plus reset-risk acknowledgement even for that preflight, and
it never emits a command submission. Direct CS/fence execution remains
fail-closed until implemented. Absence of a compatible device is an explicit
skip with the discovered reason; a compatible device requires checked
CPU-vs-GPU output before it is counted as operational.

Device code must use typed host/device/workgroup/private/constant address
spaces, a bounded kernel domain, and barrier-safe uniform control flow.  Host
allocation, OS I/O, dynamic loading, and arbitrary FFI remain invalid in device
code even inside `unsafe`.
