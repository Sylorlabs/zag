# Zag v2 GPU guide (draft)

Zag has two compat-tier GPU execution paths for this Linux machine:
**Vulkan** (SPIR-V) and **OpenGL** (GLSL 430). Their generated runtime
harnesses compile against the installed RADV/Mesa loaders and perform a tiny,
bounded dispatch when explicitly enabled. Run
`ZAG_RUN_PHYSICAL_GPU=1 bash tests/run_gpu_runtime.sh` to perform the bounded
physical execution and checked readback; this machine has passed Vulkan,
OpenGL, and OpenCL on its AMD RX 5700 XT. Run
`bash tests/run_gpu_zag_runtime.sh` to exercise the same public loader
adapters from a pure-Zag driver. The default C gate compiles and validates
without submitting work to the display-bound GPU.

OpenCL has a SPIR-V encoder, a pure-Zag OpenCL-C fallback emitter, and a
capability-probed runtime harness. The ROCm OpenCL ICD is installed on this
machine and exposes the RX 5700 XT; its physical dispatch is verified but
still explicit and bounded. CUDA (NVIDIA hardware) and Metal
(macOS) remain artifact-emission paths only here. See
`docs/V2_TARGET_SUPPORT.md` for the exact matrix.

MLIR text, deterministic bundles, and the virtual GPU model remain
compilation/validation aids, not a device runtime. Do not use them to claim
device enumeration, allocation, dispatch, barriers, or checked readback.
The MLIR path does not currently execute a GPU kernel; the bounded runtime
evidence below belongs to the separate Vulkan/OpenGL/OpenCL compat gate.

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
