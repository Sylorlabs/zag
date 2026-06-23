# Zag

**Zag is a systems language in the lineage of Zig — except the Zen of Zig stops being a convention you promise and becomes a property the compiler proves.**

In Zig, when someone annotates a function `// no allocations`, you trust them. In Zag, `@realtime` is a *compiler-verified capability*. The compiler walks the entire call graph and either produces a proof that no allocation, lock, or IO can reach your audio thread — or it rejects the program and shows you exactly which call three levels deep introduced the violation.

That's the single idea that justifies this language's existence. Everything else (the heterogeneous numeric types, the GPU backend, the bignum overflow safety) is the same idea applied further.

---

## What makes it Zag, not Zig

Zig's philosophy is "no hidden allocations, no hidden control flow." It enforces this by convention and code review. Zag enforces it by proof.

| | Zig | Zag |
|---|---|---|
| "No allocations here" | A comment you write | `@realtime` — compiler-proven |
| "This can't panic" | `catch unreachable` — crashes in release | `@total` — compiler proves it |
| "This is pure math" | Convention | `@pure` — effect system enforced |
| Integer overflow | Wraps (undefined) or traps | `sat_i16` never wraps; `u_any` never overflows |
| 11-bit ADC value | `u16` + manual `& 0x7FF` everywhere | `u11` — compiler inserts the mask |
| Audio DSP sample | `i16` that silently wraps on spike | `sat_i16` — clamps to ±32767, proven |
| GPU kernel correctness | No guarantee | `@kernel` — same effect proof as `@realtime` |
| Integer types | `u8`, `u16`, `u32`, `u64`, `i8`… | All of those **plus** any width from `u1` to `u127` |

### The three tiers Zig never touches

**Tier 1 — Proven capabilities.** The compiler is not a linter. It does not warn. It either proves the claim or the program does not compile. The proof is a call-graph reachability analysis over an effect lattice (`Alloc`, `Lock`, `IO`, `Panic`), backed by Z3 for the hard cases (division-by-zero over a path condition, index bounds). The witness it prints when something fails looks like:

```
✗ VIOLATION  renderBad @realtime
  renderBad → processBlock → fancyOp → zalloc()   [introduces Alloc]
```

Not "possible allocation." The exact chain.

**Tier 2 — The full numeric spectrum.** Zig has the standard integer widths and IEEE floats. The physical world has 11-bit ADCs, saturating 16-bit DSP, Q8.8 fixed-point filters, 128-bit residue arithmetic, and 8-bit microscaling floats. Zag makes all of these first-class:

```zag
let adc:    u11       = readSensor();    // 0..2047; mask emitted by compiler, 1 ANDI on RISC-V
let sample: sat_i16   = audioIn();      // clamps to ±32767; never wraps; no Panic effect
let coeff:  fixed_8_8 = 32;            // Q8.8 (0.125); mul does (a*b)>>8 in int32; exact
let budget: u_any     = items * price; // can't overflow; grows as needed; Alloc effect tracked
let poly:   rns_3     = coefficient;   // parallel mod-arithmetic over 3 coprime channels
```

**Tier 3 — GPU as just another target.** `@kernel` forbids the exact same effects as `@realtime`. The same proof that protects your audio thread protects your GPU kernel. GPU code emits directly to MLIR — not Vulkan, not SPIR-V — because Vulkan cannot represent any of the types in Tier 2.

---

## Install

**Requirements:** Python 3.10+, a C compiler (`cc` or `gcc`).

```bash
git clone https://github.com/Sylorlabs/zag.git
cd zag/zag-poc
python3 zagc.py
```

That's it. The bootstrap compiler has no Python dependencies. It lexes, parses, type-checks, proves capabilities, and emits C — all in one file. The system C compiler turns that into a native binary.

**Optional — Z3 prover (for `@total` division-by-zero proofs):**
```bash
pip install z3-solver
```
Without Z3, the compiler still proves all call-graph effects (`@realtime`, `@noalloc`, `@pure`). Z3 is only needed for arithmetic proofs inside `@total` functions.

**Optional — MLIR toolchain (for GPU targets):**
```bash
# Ubuntu / Debian
apt install mlir-tools llvm-18

# macOS
brew install llvm    # mlir-opt lives in $(brew --prefix llvm)/bin/
```
Without `mlir-opt`, `zagc` still writes the `.mlir` file for manual lowering.

---

## Quick start

```bash
cd zag/zag-poc

# Prove this function's effects are clean, build it, and run it
python3 zagc.py build examples/audio_render.zag --run

# Watch the prover reject an allocation buried 3 calls deep inside @realtime
python3 zagc.py check examples/audio_render_bad.zag

# See the C that was generated instead of compiling it
python3 zagc.py build examples/audio_render.zag --emit-c

# Try the heterogeneous numeric types
python3 zagc.py build examples/embedded_sensor.zag --run   # u11 + sat_i16 + fixed_8_8
python3 zagc.py build examples/hpc_rns.zag --run           # rns_3 residue arithmetic
python3 zagc.py build examples/safe_bignum.zag --run       # u_any overflow-safe sums

# Run the full test suite
bash run_tests.sh
# ════ pass=35 fail=0 ════
```

**What the bad-program check output looks like:**
```
== effect/capability report for examples/audio_render_bad.zag ==
✗ VIOLATION  renderBad @realtime
    renderBad → gain → reverbScratch → zalloc()   [introduces Alloc]
```

The compiler found the chain — `gain` calls `reverbScratch` which calls `zalloc` — without any annotation on any intermediate function. The proof crosses the entire call graph automatically.

---

## How it works

### The pipeline

```
.zag source
    │
    ▼
  Lexer          handles all Zag syntax including u11, sat_i16, fixed_8_8, rns_3
    │
    ▼
  Parser         recursive-descent; produces a typed AST
    │
    ▼
  Sema           type checker + effect prover
    │             ├─ infers types for every expression
    │             ├─ walks the call graph collecting effects (Alloc/Lock/IO/Panic)
    │             ├─ checks every @annotation claim; emits witness chain on failure
    │             └─ for @total: emits SMT-LIB2 and calls Z3 / ghost_engine
    │
    ├── GPU targets ──► MLIR emitter → mlir-opt → PTX / GCN / SPIR-V
    │
    └── CPU targets ──► C codegen → cc → native binary
```

The compiler is a single Python file (`zagc.py`, ~2,800 lines). This is the Phase-0 bootstrap. Phase 1 will be a self-hosting Zag compiler written in Zag.

### The effect system

Every function has an **inferred effect set**: the union of all effects in its body and all its callees, propagated up by least-fixed-point over the call graph.

```
Alloc       — may allocate or free heap memory
Lock        — may block on a mutex or syscall that parks the thread
IO          — may touch the OS (files, sockets, stdout)
Panic       — may trap at runtime (div-by-zero, overflow, OOB, null-unwrap)
DeviceAlloc — may allocate GPU memory
DeviceIO    — may launch a GPU kernel
```

A capability annotation is a **claim** that a named effect is absent. The compiler proves or rejects:

```zag
fn renderBlock(buf: []f32, n: i32) void @realtime {
    // compiler proves: Alloc, Lock, IO cannot be reached from here
    // if it can't prove it, the program does not compile
}
```

**Effects flow through function types.** A function value carries its effect set as part of its type. A callback stored in a struct field, pulled out, and called on the audio thread is proven safe at compile time. Storing an allocating function in a `@realtime`-bounded field is rejected at the store — before any call ever happens.

```zag
fn processBlock(buf: []f32, op: fn(f32) f32 @realtime) void @realtime {
    // the @realtime bound on `op` is enforced at every call site
    // passing an allocating callback here is a compile error
}
```

**Effects are inferred, not declared.** You annotate what effects a function *claims to lack*. The checker infers what effects it *actually has* and verifies the claim.

### The numeric type system

Zag starts where Zig ends and keeps going across the full spectrum of real silicon.

#### Standard integers
`i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `usize` — identical to Zig.

#### Arbitrary-width integers: `u3`..`u127`, `i3`..`i127`
Any bit width. The compiler inserts the mask automatically after every arithmetic operation. No manual `& 0x7FF`, no forgotten masks, no silent truncation.

```zag
let reading: u11 = adcRead();         // 11-bit sensor value; fits in uint16_t
let centred: u11 = reading - 1024;    // (reading - 1024) & 0x7FF — emitted by compiler
```

In C: `(uint16_t)((reading - 1024) & 0x7FFu)`. In MLIR: native `i11`. On RISC-V: a single `ANDI` instruction.

#### Saturating integers: `sat_i8`..`sat_u64`
Arithmetic that clamps instead of wrapping. The key compiler property: **saturating ops remove `Panic` from the effect set**. The compiler knows they cannot overflow-crash, so `@realtime` functions using saturating arithmetic are always provable without additional `@total` obligations.

```zag
fn mixSamples(a: sat_i16, b: sat_i16) sat_i16 @realtime {
    return a + b;   // 25000 + 20000 = 32767 (clamped, not -20536)
                    // compiler proves: no Panic possible here
}
```

Maps to `PADDSW` on x86, `SQADD` on ARM (1 cycle), `i16x8.add_sat` on WebAssembly.

#### Fixed-point: `fixed_I_F`
Q-format fixed-point where `I` is integer bits and `F` is fractional bits. `fixed_8_8` is Q8.8, stored as `int16_t`. Multiply does `(a * b) >> F` in `int64_t` — no rounding error per step, unlike float.

```zag
let alpha: fixed_8_8 = 32;        // 0.125 in Q8.8 (0.125 * 256 = 32)
let result: fixed_8_8 = alpha * x; // (32 * x) >> 8 — exact, no float drift
```

#### Posits: `p8`, `p16`, `p32`, `p64` + `quire`
Gustafson's universal number format. More dynamic range than IEEE floats at the same bit width; tapered precision. The `quire` is a 512-bit exact accumulator — you fused-multiply-add without rounding until you need the final result.

```zag
let q: quire = @quireZero();
q = @quireFMA(q, a, b);   // exact: no rounding between steps
let result: p32 = @quireToPosit(q);
```

#### Register-first bignum: `u_any`, `i_any`
Arbitrary-precision integers that start as register values (`__int128` in the Phase-0 bootstrap). Arithmetic that might overflow introduces the `Alloc` effect — meaning you cannot accidentally use bignum math in a `@noalloc` or `@realtime` context. The effect system statically eliminates the integer-overflow CVE class for opt-in code.

```zag
fn allocSize(count: u_any, elem_size: u_any) u_any {
    return count * elem_size;   // Alloc effect: tracked, cannot sneak into @noalloc
}
```

Standard `count * size` in C overflows silently. In Zag the overflow is tracked by the type system and forbidden in any context that can't afford it.

#### Residue Number System: `rns_3`, `rns_4`, ...
Stores a value as N residues over coprime moduli. Add and multiply are completely channel-independent — no carry, no data dependency across lanes. Natural SIMD parallelism.

```zag
fn polyEval(x: rns_3, c0: rns_3, c1: rns_3, c2: rns_3) rns_3 @pure {
    return c0 + x * (c1 + x * c2);   // three independent mod-ops per step
}
```

`rns_3` arithmetic has no `Alloc` and no `Panic` — it is mathematically total and bounded — so functions using only RNS arithmetic can be annotated `@pure`, the strictest capability.

#### GPU-native types (all GPU targets)
Types that map to hardware that Vulkan SPIR-V cannot represent:

| Type | What it is | MLIR type | Hardware |
|---|---|---|---|
| `l32` / `l16` | Logarithmic Number System | `i32` / `i16` | LNS ASIC; mul/div = integer add/sub |
| `bf16` | bfloat16 | `bf16` | A100/H100 tensor cores |
| `mx_fp8` | MX Microscaling FP8 E4M3 | `f8E4M3FN` | Blackwell B100 block-scaled GEMM |
| `mx_fp4` | MX Microscaling FP4 E2M1 | `f4E2M1FN` | Extreme-density speculative decoding |
| `vsa_b<N>` | N-dimensional binary hypervector | `vector<Nxi1>` | GPU bitwise SIMD |

### The GPU backend

The GPU backend emits MLIR and routes through vendor-specific dialects. It bypasses Vulkan entirely because Vulkan SPIR-V has no representation for `mx_fp8`, `l32`, or `vsa_b<N>`.

```
@kernel / @device functions
          │
          ▼
    MLIR textual IR
    (gpu + arith + memref + scf dialects)
          │
    mlir-opt
          ├──► nvvm dialect  → PTX  → CUDA binary   (--target gpu-nvidia)
          ├──► rocdl dialect → GCN  → ROCm binary   (--target gpu-amd)
          └──► spirv dialect → SPIR-V → Vulkan       (--target gpu-vulkan)
```

`@kernel` forbids `Alloc`, `Lock`, and `IO` — exactly the same proof obligation as `@realtime`. The effect system does not distinguish between threads and kernels.

```zag
fn matmulKernel(A: []mx_fp8, B: []mx_fp8, C: []f32, M: i32, K: i32, N: i32) void @kernel {
    // emits: gpu.func @matmulKernel(...) kernel { ... gpu.return }
    // mx_fp8 becomes f8E4M3FN — native Blackwell B100 tensor core type
    // compiler proves: no host Alloc, Lock, or IO can reach this kernel
}
```

---

## The annotations

| Annotation | Forbids | Use case |
|---|---|---|
| `@realtime` | `Alloc`, `Lock`, `IO` | Audio thread, interrupt handler, hard-deadline path |
| `@noalloc` | `Alloc` | Hot decode path, embedded systems, stack-only code |
| `@total` | `Panic` (+ `Diverge`) | Replace every `catch unreachable`; prove no runtime crash |
| `@pure` | `Alloc`, `Lock`, `IO`, non-local mutation | Math functions; compile-time evaluation candidates |
| `@kernel` | `Alloc`, `Lock`, `IO` | GPU kernel function |
| `@device` | `Alloc`, `Lock`, `IO` | GPU device helper called from `@kernel` |

---

## Build targets

```bash
# CPU targets
python3 zagc.py build file.zag --target native    # default; host CPU
python3 zagc.py build file.zag --target x86_64    # x86-64 v2; SSE2 saturating intrinsics
python3 zagc.py build file.zag --target arm64     # ARMv8-A; SQADD/UQADD; bf16 on ARMv8.6+
python3 zagc.py build file.zag --target riscv32   # RV32IMAC; single ANDI for u11 mask
python3 zagc.py build file.zag --target riscv64   # RV64IMAC + RVV vectorised sat/arb-int
python3 zagc.py build file.zag --target wasm      # WebAssembly SIMD; i16x8.add_sat
python3 zagc.py build file.zag --target ppu32     # RISC-V posit hardware (padd.s/psub.s)

# GPU targets (require mlir-opt)
python3 zagc.py build file.zag --target gpu-nvidia   # NVVM → PTX (CUDA)
python3 zagc.py build file.zag --target gpu-amd      # ROCDL → GCN (ROCm)
python3 zagc.py build file.zag --target gpu-vulkan   # SPIR-V (Vulkan portability fallback)
python3 zagc.py build file.zag --target gpu-auto     # detect from nvidia-smi / rocm-smi
```

---

## Examples

```
examples/
  audio_render.zag        @realtime audio render block — proven clean
  audio_render_bad.zag    allocation 3 calls deep — rejected with witness chain
  synth.zag               @noalloc synth + @total quantizer
  total_bad.zag           @total with unproven divisor — rejected with counterexample
  process_poly.zag        effect polymorphism: generic processBlock, callback-inferred
  process_bounded.zag     bounded callback type: fn(f32) f32 @realtime
  closure_basic.zag       stack-captured closure; zero malloc in codegen
  closure_effvar.zag      effect variable instantiated through a closure
  generic_map.zag         generic map[T]; effects compose through the generic boundary
  posit32.zag             p32 arithmetic (es=2 software emulation)
  posit_multi.zag         p8/p16/p32/p64 family arithmetic
  quire.zag               512-bit exact accumulator; fused multiply-add without rounding
  embedded_sensor.zag     u11 ADC + sat_i16 DSP + fixed_8_8 IIR — @realtime proven
  hpc_rns.zag             rns_3 polynomial eval + fixed_16_16 dot product — @pure proven
  safe_bignum.zag         u_any overflow-safe arithmetic; Alloc effect tracked by type
  gpu_matmul_mx.zag       MX-FP8 tiled matrix multiply — @kernel proven; emits MLIR
  gpu_vsa_hd.zag          Binary VSA hyperdimensional kernels on GPU
```

---

## Project status

This is the Phase-0 bootstrap compiler. It proves the core idea end-to-end.

| Feature | Status |
|---|---|
| Effect prover (`@realtime`, `@noalloc`, `@pure`, `@total`, `@kernel`) | Done |
| Effect polymorphism through generics, closures, struct fields | Done |
| Witness chains across call-graph boundaries | Done |
| Standard types + posits + quire | Done |
| Arbitrary-width integers (`u3`..`u127`, `i3`..`i127`) | Done |
| Saturating integers (`sat_i8`..`sat_u64`) | Done |
| Fixed-point (`fixed_I_F`) | Done |
| Bignum (`u_any`, `i_any`) — `__int128` bootstrap | Done |
| Residue Number System (`rns_N`) | Done |
| GPU / MLIR backend (nvidia, amd, vulkan) | Done |
| Z3 / ghost_engine integration for `@total` proofs | Done |
| Self-hosting Zag compiler | Phase 1 |
| Standard library | Phase 1 |
| True heap bignum (GMP-backed) | Phase 2 |
| Full MLIR GPU lowering pipeline | Phase 2 |
| RISC-V PPU hardware posit hardware | Phase 4 |

Test suite: **pass=35 fail=0** (`bash run_tests.sh`).

---

## Repository layout

```
README.md               this file
ZAG_DESIGN.md           full language design document with implementation notes
zag-poc/
  zagc.py               bootstrap compiler (~2,800 lines; no dependencies)
  run_tests.sh          full test suite (35 programs)
  prove.sh              Z3 / ghost_engine integration demo
  examples/             35 .zag programs (good ones that run + bad ones that are rejected)
  gpu/
    mlir_emitter.py     Zag AST → MLIR textual IR
    lowering.py         mlir-opt pass pipeline driver (nvidia / amd / vulkan)
    types.py            GPU type mappings (Zag type → MLIR type string)
```

---

## License

See [LICENSE](LICENSE).
