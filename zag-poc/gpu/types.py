"""
gpu/types.py — Zag GPU type system extension.

Registers the GPU-native types that are the reason Zag needs its own GPU backend
instead of routing through Vulkan:

  l32     — Logarithmic Number System (32-bit). Mul/div = integer add/sub of exponents.
             No IEEE equivalent; no Vulkan/SPIR-V opcode. Hardware LNS units in FPGAs,
             Akida, and research ASICs can execute these natively.

  bf16    — bfloat16. MLIR native type; maps to bf16. Tensor core instructions on A100+.

  mx_fp8  — MX Microscaling FP8 (E4M3). 32-element blocks share one f32 scale factor.
             Maps to MLIR f8E4M3FN. Blackwell B100 natively executes block-scaled GEMM.
             Zero-cost on compatible silicon; emulated on older hardware.

  mx_fp4  — MX Microscaling FP4 (E2M1). Maps to MLIR f4E2M1FN. Extreme density.

  vsa_b<N> — Binary VSA hypervector with N dimensions (N-bit wide boolean vector).
              Maps to MLIR vector<Nxi1>. Binding = XOR, Bundling = popcount+threshold,
              Similarity = Hamming distance (popcount of XNOR). GPU-friendly: all ops
              are bitwise on 32/64-bit words.

  gpu_buf<T> — A GPU-resident buffer of element type T. Distinct from host slices —
               the type system prevents mixing them without an explicit copy intrinsic.
               Maps to MLIR memref<?xT, 1> (address space 1 = GPU global memory).

Effect extension:
  DeviceAlloc — allocating a gpu_buf<T> on the device side (via @gpuAlloc)
  DeviceIO    — H2D/D2H transfers and kernel launches

These extend zagc's ALL_EFFECTS and FORBIDS when GPU types are present.
"""

# ── GPU scalar types ──────────────────────────────────────────────────────────

GPU_SCALAR_TYPES = {"l32", "l16", "bf16", "mx_fp8", "mx_fp4"}

# ── VSA types (vector<N×i1>) ──────────────────────────────────────────────────

def is_vsa_type(ty: str) -> bool:
    return isinstance(ty, str) and ty.startswith("vsa_b<") and ty.endswith(">")

def vsa_dim(ty: str) -> int:
    """'vsa_b<10000>' -> 10000"""
    return int(ty[6:-1])

# ── GPU buffer type ───────────────────────────────────────────────────────────

def is_gpu_buf(ty: str) -> bool:
    return isinstance(ty, str) and ty.startswith("gpu_buf<") and ty.endswith(">")

def gpu_buf_elem(ty: str) -> str:
    """'gpu_buf<f32>' -> 'f32'"""
    return ty[8:-1]

# ── MLIR type mapping ─────────────────────────────────────────────────────────

# Zag host types -> MLIR type strings
_BASE_MLIR = {
    "void": "",
    "bool": "i1",
    "i8": "i8",   "i16": "i16",  "i32": "i32",  "i64": "i64",
    "u8": "i8",   "u16": "i16",  "u32": "i32",  "u64": "i64",
    "usize": "index",
    "f32": "f32", "f64": "f64",
    "bf16": "bf16",
    # Posit: stored as unsigned bits, arithmetic via helper func calls
    "p8": "i8",  "p16": "i16",  "p32": "i32",  "p64": "i64",
    # LNS: stored as signed bits (the log-domain representation)
    "l16": "i16", "l32": "i32",
    # MX microscaling types (MLIR >= 18 has native support)
    "mx_fp8": "f8E4M3FN",
    "mx_fp4": "f4E2M1FN",
    # Quire: 512-bit = 8×i64 struct; represented as memref<8xi64> in MLIR
    "quire": "memref<8xi64>",
}

def zag_to_mlir(ty: str) -> str:
    """Map a Zag type string to its MLIR textual type string."""
    if ty in _BASE_MLIR:
        return _BASE_MLIR[ty]
    if ty.startswith("[]"):
        elem = zag_to_mlir(ty[2:])
        return f"memref<?x{elem}>"
    if is_vsa_type(ty):
        n = vsa_dim(ty)
        return f"vector<{n}xi1>"
    if is_gpu_buf(ty):
        elem = zag_to_mlir(gpu_buf_elem(ty))
        return f"memref<?x{elem}, 1>"   # address space 1 = GPU global
    # struct / enum / union names: lower to LLVM struct (emitter handles)
    mangled = ty.replace("[", "_").replace("]", "").replace(",", "_")
    return f"!llvm.struct<{mangled}>"

# ── Arithmetic helpers: which ops need a runtime function call ────────────────

# For custom types, arithmetic is not a direct MLIR arith.* op — it calls helpers.
# These are emitted as func.func declarations with @zag_* symbol names.

POSIT_MLIR_OPS = {
    "+": "zag_p32_add", "-": "zag_p32_sub",
    "*": "zag_p32_mul", "/": "zag_p32_div",
}

LNS_MLIR_OPS = {
    # LNS mul/div are exact integer add/sub of exponent words
    "*": "zag_l32_mul", "/": "zag_l32_div",
    # LNS add/sub require an antilog-add kernel (Mitchell approximation or lookup)
    "+": "zag_l32_add", "-": "zag_l32_sub",
}

VSA_MLIR_OPS = {
    "bind":    "zag_vsa_bind",    # XOR (binary VSA binding)
    "bundle":  "zag_vsa_bundle",  # OR + threshold (bundling)
    "similar": "zag_vsa_cosine",  # 1 - normalised Hamming distance
}

# ── Runtime function declarations (emitted at top of MLIR module) ─────────────

def runtime_decls(types_used: set) -> list:
    """Return MLIR func declarations for any runtime helpers needed."""
    decls = []
    if any(t in types_used for t in ("p8", "p16", "p32", "p64")):
        for sym in POSIT_MLIR_OPS.values():
            decls.append(f"  func.func private @{sym}(i32, i32) -> i32")
        decls.append("  func.func private @zag_p32_to_f64(i32) -> f64")
        decls.append("  func.func private @zag_f64_to_p32(f64) -> i32")
    if any(t in types_used for t in ("l16", "l32")):
        for sym in LNS_MLIR_OPS.values():
            decls.append(f"  func.func private @{sym}(i32, i32) -> i32")
        decls.append("  func.func private @zag_l32_to_f32(i32) -> f32")
        decls.append("  func.func private @zag_f32_to_l32(f32) -> i32")
    return decls

# ── GPU thread/block index intrinsic names (gpu dialect) ─────────────────────

GPU_THREAD_INTRINSICS = {
    "@gpuThreadIdx": "gpu.thread_id",
    "@gpuBlockIdx":  "gpu.block_id",
    "@gpuBlockDim":  "gpu.block_dim",
    "@gpuGridDim":   "gpu.grid_dim",
}

GPU_DIM_NAMES = {0: "x", 1: "y", 2: "z"}

# ── New Zag builtins exposed in GPU kernels ────────────────────────────────────

GPU_BUILTINS = {
    "@gpuThreadIdx": {"params": ["i32"], "ret": "i32", "eff": set()},
    "@gpuBlockIdx":  {"params": ["i32"], "ret": "i32", "eff": set()},
    "@gpuBlockDim":  {"params": ["i32"], "ret": "i32", "eff": set()},
    "@gpuGridIdx":   {"params": ["i32"], "ret": "i32", "eff": set()},
    "@gpuSyncThreads": {"params": [], "ret": "void", "eff": set()},
    # Host-side GPU memory management (has DeviceAlloc effect)
    "@gpuAlloc":      {"params": ["i64"], "ret": "gpu_buf<f32>", "eff": {"DeviceAlloc"}},
    "@gpuFree":       {"params": ["gpu_buf<f32>"], "ret": "void", "eff": {"DeviceAlloc"}},
    "@gpuLaunch":     {"params": [], "ret": "void", "eff": {"DeviceIO"}},
}

# ── Effects extension for GPU ─────────────────────────────────────────────────

GPU_EXTRA_EFFECTS = {"DeviceAlloc", "DeviceIO"}

# @kernel: no host Alloc/Lock/IO; device-side memory ops are fine
KERNEL_FORBIDS = {"Alloc", "Lock", "IO"}

# @device: callable from @kernel; same restrictions
DEVICE_FORBIDS = {"Alloc", "Lock", "IO"}
