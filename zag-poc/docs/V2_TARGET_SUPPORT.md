# Zag v2 target support matrix

This is generated in principle from release evidence, not a marketing matrix.
The gate inventory is in `V2_SUPPORT_MATRIX.generated.md`; a row below is not
v2 support unless all required v2 categories are green.

| Target/path | Current evidence | v2 operational status |
|---|---|---|
| x86-64 Linux static native | self-hosting bootstrap plus native v1 execution; 37 bounded v2 release-gate checks execute, including checked allocation, raw-pointer, MMIO, atomic/futex, C-ABI, and SSE2 slices | v1 supported; bounded v2 machine-control slices execute, but v2 is **not a supported release target** while required memory-model, concurrency, ABI, sanitizer, and verification rows remain partial or unsupported |
| ARM64 native | experimental lowering and separate regression tests | not a v2 supported target |
| WebAssembly | v1 emission/execution regression gate | not a v2 supported target |
| GPU MLIR / gfx bundle | frontend output validation only | not a GPU execution backend |
| Vulkan compute (compat) | SPIR-V passes spirv-val; C runtime test verified on AMD RX 5700 XT (RADV) | **runtime-verified** — kernel launched, output checked |
| OpenGL compute (compat) | GLSL 430 structural checks; C runtime test verified on AMD RX 5700 XT (Mesa) | **runtime-verified** — kernel launched, output checked |
| OpenCL compute (compat) | SPIR-V passes spirv-val opencl2.0; loader code written but `available()` returns false | **not verified** — needs contributor with OpenCL hardware |
| CUDA compute (compat) | PTX structural checks; loader code written but `available()` returns false | **not verified** — needs contributor with NVIDIA GPU |
| Metal compute (compat) | MSL structural checks; loader dispatch is a stub (returns -201) | **not verified** — needs contributor with macOS/Metal |
| ROCm/HIP | no runtime implementation | unsupported |
| RISC-V | no executable backend evidence in this tree | unsupported |

Any new target must add target-specific lowering validation, executable corpus,
ABI/layout checks where relevant, and a support-matrix row sourced from those
tests.  Cross-compilation alone is not execution support.

## Contributing: GPU backends needing hardware

Vulkan and OpenGL compute are **runtime-verified** on an AMD RX 5700 XT.
The remaining three GPU backends have encoder and loader code written but
**cannot be tested on the current developer's machine** (Linux, AMD GPU only).

We are asking for contributors with the right hardware to help verify these:

| Backend | What's done | What's needed | Hardware required |
|---|---|---|---|
| **OpenCL** | SPIR-V encoder passes spirv-val; loader FFI + dispatch logic written | Write C test harness, hook up `available()` to probe `libOpenCL.so.1`, run kernel, verify output | Any machine with a working OpenCL ICD (AMD ROCm, Intel NEO, or NVIDIA) |
| **CUDA** | PTX encoder passes structural checks; loader FFI + dispatch logic written | Write C test harness, hook up `available()` to probe `libcuda.so.1`, run kernel, verify output | NVIDIA GPU + CUDA toolkit |
| **Metal** | MSL encoder passes structural checks; loader has stub dispatch (returns -201) | Implement real Objective-C dispatch, run `tests/run_metal_mac.sh`, verify output | Mac (M-series or Intel) with Metal framework |

The Vulkan backend (`tests/vulkan_runtime_test.c` + `tests/run_gpu_runtime.sh`)
is the reference for what a verified backend looks like. If you have one of
these machines, please open an issue or pull request.
