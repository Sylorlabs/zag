# Zag v2 GPU model (draft)

GPU source is not supported merely because it parses or emits MLIR. `@kernel`
currently rejects every implemented host effect at the semantic boundary, so
direct I/O, raw atomics, C-ABI calls, and host GPU resource operations fail
before frontend emission. Device builtins carry a distinct `Device` effect
that propagates through direct helpers and is permitted by `@kernel`;
host allocation/launch operations carry `GPUHost`. A complete `@device`
capability and helper-invocation model is not yet implemented. Pointer
address spaces are host, device/global, workgroup, private, and
constant/uniform; implicit crossing is forbidden. Barriers and fences have
specified workgroup/device scope and cannot be used to synchronize host code.

The first native physical backend remains an opt-in direct Linux AMDGPU DRM
runtime for native `amdgpu-gfx1010` code. Its current boundary is a strict
preflight: an explicitly selected render node, GFX10/IP and GPUVM discovery, a
single 4 KiB GPUVM map/unmap, and a CPU memory roundtrip. It does not create a
submission context, issue `DRM_IOCTL_AMDGPU_CS`, wait on a driver fence, or
claim native execution. The display-bound RX 5700 XT requires both explicit
override and reset-risk acknowledgement even for that preflight, and the
preflight still reports native submission as unimplemented. The MLIR path
remains a development frontend, not a runtime API. Vulkan, OpenGL, and OpenCL
compat paths have bounded loader-backed runtime gates and a shared typed
launch/readback contract; they remain separate from native DRM. On this card,
tests use tiny buffers, external subprocess timeouts, and explicit opt-in.
Missing compatible hardware is an explicit skip; MLIR emission is reported
separately from target binary, load, launch, and correct output.

## Kernel and address-space contract

`@kernel` identifies a host-launchable entry and `@device` a helper callable
only from device code.  Kernel parameters are explicitly address-space
qualified.  Conversion between host and device pointers is forbidden; buffer
objects mediate transfer.  Workgroup variables have one instance per
workgroup, private variables one per invocation, and device/global storage has
a lifetime governed by its host handle.  Constant/uniform storage is read-only.
Native x86-64 lowering rejects `*device` and `*workgroup` dereference/indexing;
it must not reinterpret device addresses as host pointers while the GPU runtime
is unavailable.

Invocation, workgroup, and grid dimensions are validated against backend limits
before submission.  A kernel must include an explicit `id < len` guard unless
the dispatch API proves its exact domain.  A workgroup barrier is valid only
when every active invocation reaches the same dynamic instance; the frontend
rejects provable divergence and the backend validator rejects residual invalid
control flow.

## Synchronization and errors

Device fences carry storage scope and ordering; they do not synchronize the
host.  Queue completion/fence waiting is the host synchronization point for
readback.  Device loss, validation failure, timeout, compilation failure, and
transfer failure return structured errors, never plausible output.  A timeout
must not free storage still used by the driver; destroy the context if safe
cancellation is unavailable.

## Truthful milestones

The support matrix distinguishes syntax accepted, semantic validation, MLIR
emitted, MLIR verified, target binary produced, runtime loaded, kernel launched,
results checked, and performance measured.  Current GPU bundle/VM facilities
are not a physical GPU runtime.

### Compat tier runtime verification status (2026-08-04)

| Target | Encoder validated | Runtime loaded | Kernel launched | Output verified | Test machine |
|--------|:-:|:-:|:-:|:-:|---|
| **vulkan-compat** | spirv-val vulkan1.0; generated harness compiles | verified | verified | verified (1024/1024) | AMD RX 5700 XT, RADV, Mesa 25.2.8 |
| **opengl-compat** | GLSL structural checks; generated EGL harness compiles | verified | verified | verified (1024/1024) | AMD RX 5700 XT, Mesa 4.6 Core, EGL 1.5 |
| **opencl-compat** | spirv-val opencl2.0; pure-Zag source fallback and generated ICD probe compile | verified | verified | verified (1024/1024, source fallback) | AMD RX 5700 XT, ROCm OpenCL 2.1 |
| **cuda-compat** | structural checks | NO | NO | NO | Needs contributor with NVIDIA GPU |
| **metal-compat** | structural checks | NO | NO | NO | Needs contributor with macOS/Metal |

The `tests/run_gpu_runtime.sh` gate generates transient C harnesses; the
checked-in `tests/run_gpu_zag_runtime.sh` links the public pure-Zag loaders
against `libvulkan.so.1`, `libEGL.so.1` + `libGL.so.1`, and `libOpenCL.so.1`.
Both gates dispatch the bounded fill kernel with 1024 work items and verify
every output slot equals 42; the pure-Zag gate also exercises a 17-item,
non-default value/size for each adapter and invalid-contract rejection.
Compilation and validation are the default for the C gate; physical
submission there requires the explicit
`ZAG_RUN_PHYSICAL_GPU=1` opt-in because the RX 5700 XT is display-bound. The
pure-Zag gate is a separate direct loader proof and uses an explicit bounded
test driver. OpenCL completion is process-scoped: the ICD's `clFinish` is used
for ordered cleanup, while the gate's external timeout is the watchdog. Hosts
that cannot afford worker threads after the generated Linux `exit` may call
the explicit shutdown-process helper, which closes the context then uses
`exit_group`.

**Vulkan, OpenGL, and OpenCL are runtime-verified on this machine; CUDA and
Metal are intentionally fail-closed here.** The public Vulkan, OpenGL, and
OpenCL loader names are thin imports of their compileable `*_runtime.zag`
adapters. CUDA and Metal remain artifact-only because this Linux machine has
neither the required NVIDIA driver/hardware nor Apple's Metal framework.

**We need contributors with the right hardware to help.** Specifically:

- **OpenCL:** The local ROCm ICD is installed and exposes the RX 5700 XT; the
  explicit C and pure-Zag bounded gates verify source fallback and correct
  output through the public `std/opencl_loader.zag` adapter.

- **CUDA:** Someone with an NVIDIA GPU and CUDA toolkit installed. The task
  is to write a C runtime test harness, hook up the loader's `available()`
  to actually probe for `libcuda.so.1`, and verify the PTX kernel runs and
  produces correct output.

- **Metal:** Someone with a Mac (M-series or Intel). The task is to
  implement the real Objective-C dispatch in `std/metal_loader.zag`
  (replacing the stub), run `tests/run_metal_mac.sh`, and verify the MSL
  kernel runs and produces correct output on the physical GPU.

If you have one of these machines and want to help, please open an issue or
pull request. The Vulkan and OpenGL backends serve as the reference
implementation for what a verified backend looks like.

## Compat tier known quirks and blockers

The compat fallback tier emits code for system GPU APIs (Vulkan, OpenCL, Metal,
OpenGL, CUDA) via pure-Zag encoders.  The emitted binaries are validated where
tooling is available, but several platform-level quirks affect runtime loading:

### SPIR-V (Vulkan)

* **Vulkan validation passes.** The emitted SPIR-V 1.0 binary passes
  `spirv-val --target-env vulkan1.0` with zero errors.  The module uses
  `OpCapability Shader`, `GLCompute` entry point, `BufferBlock`/`Uniform`
  storage for the output buffer, `Block`/`PushConstant` for parameters, and
  `ArrayStride 4` on the runtime array.

### SPIR-V (OpenCL)

* **OpenCL has a separate SPIR-V encoder.** The `opencl-compat` target uses
  a distinct SPIR-V emission path from `vulkan-compat`.  The OpenCL binary
  uses `OpCapability Kernel` (not `Shader`), `OpCapability Addresses`,
  `OpCapability Int64`, `OpMemoryModel Physical64 OpenCL` (not
  `Logical GLSL450`), `OpEntryPoint Kernel` (not `GLCompute`), and kernel
  parameters via `OpFunctionParameter` (not descriptor sets/push constants).
  All `OpTypeInt` have `Signedness=0` per the OpenCL convention.  The
  global invocation ID is `vec3(i64)` and requires `OpSConvert` to `i32`.
  Pointer arithmetic uses `OpPtrAccessChain` (not `OpAccessChain` on structs).

* **OpenCL validation passes.** The emitted SPIR-V binary passes
  `spirv-val --target-env opencl2.0` with zero errors.

* **NVIDIA OpenCL 3.0 `clCreateProgramWithIL` not implemented.** NVIDIA's
  OpenCL 3.0 driver (even on RTX 3060 Ti / 30-series) does not support
  `clCreateProgramWithIL`.  The function returns `CL_INVALID_OPERATION`.
  This is a driver-level blocker, not a spec issue — OpenCL 3.0 makes SPIR-V
  optional.  The `std/opencl_loader.zag` adapter tries IL and falls back to
  source compilation via `clCreateProgramWithSource` if the ICD rejects IL or
  its kernel entry point.
  The fallback OpenCL C source is emitted by `selfhost/opencl_c.zag`.

* **Address bits probing.** The OpenCL loader queries
  `CL_DEVICE_ADDRESS_BITS` to select `Physical32` vs `Physical64`
  addressing.  The encoder defaults to `Physical64` (most modern devices).

### Metal (MSL)

* **`thread_position_in_grid` semantics.** The MSL encoder uses
  `[[thread_position_in_grid]]` as a 1D scalar `uint` for the fill kernel.
  This is correct for 1D grids.  For 2D/3D grids, the attribute returns a
  `uint2`/`uint3`, and the encoder would need to select the `.x` component.
  The current fill-kernel-only encoder always uses 1D dispatch.

* **MSL version compatibility.** The encoder emits plain MSL without a
  `#pragma clang diagnostic` or language-version pragma.  Metal frameworks
  on macOS 10.11+ accept this.  `metal_stdlib` is included via
  `#include <metal_stdlib>`.

* **Device enumeration.** On macOS, `MTLCreateSystemDefaultDevice()` returns
  the default GPU.  For multi-GPU systems (e.g., MacBook Pro with integrated
  + discrete), `MTLCopyAllDevices()` enumerates all available Metal devices.
  The loader documents this in `std/metal_loader.zag`.

* **Runtime testing on Apple Silicon.** A test script
  (`tests/run_metal_mac.sh`) is provided for running on macOS with an M-series
  chip.  It compiles the emitted MSL with `xcrun -sdk macosx metal`, produces
  a `.metallib`, and runs the kernel via a Swift harness that verifies output
  correctness on the physical GPU. **This Linux checkout cannot run that
  path:** Metal remains an explicit fail-closed artifact-only target and its
  dispatch function returns -201 until a macOS implementation is supplied.

### OpenGL (GLSL)

* **Memory barriers required after SSBO writes.** GLSL 430 compute shaders
  using SSBOs require `glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT)` after
  dispatch to ensure host visibility.  The `std/opengl_loader.zag` adapter
  issues this barrier after `glDispatchCompute` and before
  `glGetBufferSubData` readback.

* **`std430` layout.** The encoder uses `layout(std430, binding = 0)` for
  the SSBO.  This is the correct layout for compute shaders and avoids the
  `std140` padding rules that would waste space for `int[]` arrays.

### CUDA (PTX)

* **PTX version lowered to 6.5 for broad compatibility.** The encoder
  emits `.version 6.5` (was 7.5).  PTX 6.5 requires NVIDIA driver >= 390.x,
  while PTX 7.5 requires driver >= 425.25.  Lowering the default version
  broadens driver compatibility.  The `std/cuda_loader.zag` adapter queries
  the driver version via `cuDriverGetVersion` and rejects PTX that the
  driver cannot JIT-compile, returning `CUDA_ERROR_UNSUPPORTED_PTX_VERSION`
  (218) if the driver is too old.

* **PTX is JIT-compiled to SASS.** GPUs do not execute PTX directly; the
  driver compiles PTX to SASS (Streaming Assembly) for the specific GPU.
  This means `.target sm_70` PTX will run on any sm_70+ GPU (Volta+), but
  the driver must support the PTX version.
