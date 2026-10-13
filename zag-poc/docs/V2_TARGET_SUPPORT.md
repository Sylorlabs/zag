# Zag v2 target support matrix

This is generated in principle from release evidence, not a marketing matrix.
The gate inventory is in `V2_SUPPORT_MATRIX.generated.md`; a row below is not
v2 support unless all required v2 categories are green.

| Target/path | Current evidence | v2 operational status |
|---|---|---|
| x86-64 Linux static native | self-hosting bootstrap plus native v1 execution; 38 bounded v2 release-gate checks execute, including checked allocation, raw-pointer, MMIO, atomic/futex, C-ABI, and SSE2 slices | v1 supported; bounded v2 machine-control slices execute, but v2 is **not a supported release target** while required memory-model, concurrency, ABI, sanitizer, and verification rows remain partial or unsupported |
| ARM64 Linux native | scoped supported v1 output plus qemu-user/native-ARM execution and separately gated edition-2027 static/object/dynamic/safety slices | ARM64 is a supported scoped target, but v2 is not a supported release on any target and unlisted x86-64 v2 features do not imply ARM parity |
| Apple Silicon macOS native | signed PIE Mach-O, scalar C-ABI objects/BSD archives/dylibs and custom dynamic executables, bounded ARM64 Mach-O object/archive input linking, native C/Zag/C execution, Darwin runtime/services, closed dyld imports with DWARF, native hot replacement/cache, scalar global and checked-pointer/sanitizer fixtures, edition-2027 integer/boolean/raw-pointer `@repr(C)` pointer layout with exact-width field access, first-class `gpu-metal`, ARMv8 atomic witnesses, pthread-backed join-only worker execution with checked atomic work, pthread-backed raw i32 wait/wake parity, exact-width volatile/MMIO transactions, the same five compiler-owned scalar CPU intrinsics as native x86-64, baseline `PRFM`, and bounded NEON i32x4 add/sub/and/or/xor with checked 16-byte raw accesses; a particular seed is release evidence only after its complete native self-host fixpoint and gate pass | scoped native development target, not a complete v2 release target — scalar globals use PIE-relative writable cells, but aggregate globals, complete safety instrumentation, general C ABI/arbitrary foreign objects, custom-linked hot/debug/exit-sanitizer combinations, broader SIMD/vector ABI, broader threading primitives, and whole-target verification remain outside the native contract |
| WebAssembly | v1 artifact-emission regression gate | artifact-only; no supported Zag-owned execution runtime and not a v2 supported target |
| GPU MLIR / gfx bundle | frontend output validation only | not a GPU execution backend |
| AMDGPU DRM native preflight | live AMDGPU render-node discovery, GFX10/IP and GPUVM queries, bounded 4 KiB map/unmap and CPU readback; display-bound opt-in refusal is regression-tested by `tests/run_linux_drm.sh` | **preflight verified; native CS submission and fence execution unsupported** |
| Vulkan compute (compat) | SPIR-V passes spirv-val; the C harness and `tests/run_gpu_zag_runtime.sh` pure-Zag adapter create a RADV device, submit, fence, and verify 1024/1024 output on the RX 5700 XT | **bounded runtime verified** on AMD RADV/Mesa 25.2.8; physical use remains explicit opt-in |
| OpenGL compute (compat) | GLSL 430 plus EGL/OpenGL harness and pure-Zag adapter create a Mesa 4.6 context, compile, dispatch, barrier/finish, and verify 1024/1024 output on the RX 5700 XT | **bounded runtime verified** on AMD Mesa 25.2.8; physical use remains explicit opt-in |
| OpenCL compute (compat) | OpenCL SPIR-V passes spirv-val; pure-Zag OpenCL-C fallback emitter, ICD harness, and pure-Zag adapter dispatch/read back 1024/1024 on the ROCm RX 5700 XT (local path: source fallback) | **bounded runtime verified** on AMD ROCm OpenCL 2.1; physical use remains explicit opt-in |
| CUDA compute (compat) | PTX structural checks; loader code written but `available()` returns false | **not verified** — needs contributor with NVIDIA GPU |
| Metal compute (`gpu-metal`; legacy `metal-compat`) | the compiler emits deterministic MSL for the same reviewed fill, depth-write, and depth-tested fixed-point RGB blend profiles used by the bounded GFX10.1 slice; `std:metal_loader` binds Metal.framework/libobjc, queries the default Apple GPU, verifies unified-memory/device limits, performs shared-memory roundtrips, compiles the emitted MSL, submits and waits, reads results back, and releases owned resources; `tests/run_macos_metal_loader.sh` and `tests/run_macos_metal_native_profiles.sh` execute signed native Mach-O witnesses | **bounded runtime verified** on physical Apple Silicon, including exact depth and alpha 0/128/256 blend outcomes; `gpu-metal` is the first-class target and `metal-compat` remains a compatibility alias |
| ROCm/HIP | no runtime implementation | unsupported |
| RISC-V | no executable backend evidence in this tree | unsupported |

Any new target must add target-specific lowering validation, executable corpus,
ABI/layout checks where relevant, and a support-matrix row sourced from those
tests.  Cross-compilation alone is not execution support.

## Contributing: GPU backends needing hardware

Vulkan, OpenGL, and OpenCL compute have both generated C harnesses in
`tests/run_gpu_runtime.sh` and a checked-in pure-Zag adapter gate in
`tests/run_gpu_zag_runtime.sh`. A physical run on this machine passed the
emitted fill kernel and checked readback on the AMD RX 5700 XT. Physical
dispatch is still deliberately explicit: run
`ZAG_RUN_PHYSICAL_GPU=1 bash tests/run_gpu_runtime.sh` only when the
display-bound card may be used for the tiny, externally timeout-bounded smoke
test. Metal is independently exercised by the first-class `gpu-metal` compiler
target and native Apple Silicon adapter, including the fill/depth/blend parity
gate. Only a recorded successful physical run counts as runtime verification; a
compile-only run does not.

We are asking for contributors with the right hardware to help verify these:

| Backend | What's done | What's needed | Hardware required |
|---|---|---|---|
| **OpenCL** | SPIR-V encoder passes spirv-val; pure-Zag `std/opencl_runtime.zag` supplies IL/source dispatch and local ROCm readback is verified | On another machine, run both runtime gates and verify the device-specific output; source fallback covers ICDs without IL upload | Any machine with a working OpenCL GPU ICD |
| **CUDA** | PTX encoder passes structural checks; loader FFI + dispatch logic written | Write C test harness, hook up `available()` to probe `libcuda.so.1`, run kernel, verify output | NVIDIA GPU + CUDA toolkit |

The Vulkan backend (the generated harness in `tests/run_gpu_runtime.sh`) is the
reference for what a verified backend looks like. If you have one of these
machines, please open an issue or pull request.
