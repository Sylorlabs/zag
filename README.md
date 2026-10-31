# Zag

**Zag is a systems language in the lineage of Zig, except the Zen of Zig stops being a convention you promise and becomes a property the compiler proves.**

In Zig, when someone annotates a function `// no allocations`, you trust them. In Zag, `@realtime` is a *compiler-verified capability*. The compiler walks the call graph and either proves that no allocation, lock, or IO can reach your audio thread, or rejects the affected annotated functions with source diagnostics. Every rejected effect is accompanied by its complete rendered path from the constrained function to the source operation, including higher-order callback and closure bindings and imported source identity.

That's the single idea that justifies this language's existence. Everything else (the heterogeneous numeric types, GPU frontend emission, the bignum overflow safety) is the same idea applied further.

---

## What makes it Zag, not Zig

Zig's philosophy is "no hidden allocations, no hidden control flow." It enforces this by convention and code review. Zag enforces it by proof.

| | Zig | Zag |
|---|---|---|
| "No allocations here" | A comment you write | `@realtime`, compiler proven |
| "This can't panic" | `catch unreachable`, crashes in release | `@total`, compiler proves it |
| "This is pure math" | Convention | `@pure`, effect system enforced |
| Integer overflow | Wraps (undefined) or traps | `sat_i16` never wraps, `u_any` never overflows |
| 11-bit ADC value | `u16` + manual `& 0x7FF` everywhere | `u11`, compiler inserts the mask |
| Audio DSP sample | `i16` that silently wraps on spike | `sat_i16`, clamps to ±32767, proven |
| GPU kernel correctness | No guarantee | Bounded Vulkan/OpenGL/OpenCL compat fill dispatch/readback is verified locally; arbitrary-kernel/general GPU certification is not established |
| Integer types | `u8`, `u16`, `u32`, `u64`, `i8`… | All of those **plus** any width from `u1` to `u127` |

### The three tiers Zig never touches

**Tier 1: proven capabilities.** The compiler is not a linter. It does not warn. It either proves the claim or the program does not compile. The proof is a call-graph reachability analysis over an effect lattice (`Alloc`, `Lock`, `IO`, `Panic`). On the supported `./znc` path this covers call-graph effects today. Deeper `@total` arithmetic proofs are gated separately and must be checked with the native total gate; they are not a blanket claim that every arithmetic precondition is solved.

```
✗ VIOLATION  renderBad @realtime
  renderBad → processBlock → fancyOp → zalloc()   [introduces Alloc]
```

Not a warning: a failed capability proof stops the build. The diagnostic prints
one complete call-path witness for every forbidden effect that was reached.

**Tier 2: the full numeric spectrum.** Zig has the standard integer widths and IEEE floats. The physical world has 11-bit ADCs, saturating 16-bit DSP, Q8.8 fixed-point filters, 128-bit residue arithmetic, and 8-bit microscaling floats. Zag makes all of these first-class on the native backend:

```zag
let adc:    u11       = readSensor();    // 0..2047; mask emitted by compiler, 1 ANDI on RISC-V
let sample: sat_i16   = audioIn();      // clamps to ±32767; never wraps; no Panic effect
let coeff:  fixed_8_8 = 32;            // Q8.8 (0.125); mul does (a*b)>>8 in int32; exact
let budget: u_any     = items * price; // can't overflow; grows as needed; Alloc effect tracked
let poly:   rns_3     = coefficient;   // parallel mod-arithmetic over 3 coprime channels
```

**Tier 3: GPU compat execution.** Vulkan, OpenGL, and OpenCL compatibility
targets now have bounded C and pure-Zag runtime gates with checked readback on
the local AMD RX 5700 XT. MLIR remains a development frontend and is not the
runtime path; CUDA and Metal remain explicit artifact-only, fail-closed
targets here.
GPU MLIR output is not a GPU executable or dispatch runtime; GPU MLIR is not
physical GPU execution.

---

## Install

**Compiler host:** Linux x86-64 for the committed release seed. Linux AArch64
is a scoped supported output target and CI host, with exact boundaries in the
[support contract](zag-poc/docs/SUPPORT.md). No Python, Zig, `cc`, LLVM, or libc
build chain is required for the compiler.

```bash
git clone https://github.com/Sylorlabs/zag.git
cd zag/zag-poc
chmod +x znc bootstrap.sh
./bootstrap.sh    # optional: self-rebuild ./znc from the committed seed
./znc examples/numeric.zag -o numeric --run
```

`./znc` is the supported v1 compiler: it lexes, parses, type-checks, proves capabilities,
optimizes, and emits a static x86-64 ELF with no external tools. See
[`zag-poc/INSTALL.md`](zag-poc/INSTALL.md) and [`zag-poc/BOOTSTRAP.md`](zag-poc/BOOTSTRAP.md).

No C-emitting compiler or external prover is required for the supported path.
The retired bootstrap/oracle implementations are available only through Git
history. GPU MLIR targets are development/differential frontends; they are not
physical GPU execution and do not require an MLIR installation for ordinary
native builds.

### GitHub syntax highlighting

On github.com, `.zag` files are temporarily classified as **Zig** (via `.gitattributes`)
so they get syntax highlighting and show up sensibly in the repo language bar. Zag is not
Zig. This is a stand-in until [GitHub Linguist accepts Zag](https://github.com/github-linguist/linguist/pull/8041).
After that PR merges, we will switch the attribute to `linguist-language=Zag` and the
site will show the Zag name and blue color. Local editors use the Zag grammar in
`editors/vscode/` regardless.

---

## Start a project

```bash
mkdir my-zag-app && cd my-zag-app
znc init --name my-zag-app
znc src/main.zag -o app --run
znc tests/smoke.zag -o smoke --run
```

The scaffold includes a runnable source file, smoke test, project README, and
ignore rules. `znc --help` lists the compiler's supported commands.

To explore Zag's capability proofs from the compiler checkout:

```bash
cd zag/zag-poc
./znc examples/audio_render.zag -o audio_render --run

# Watch the prover reject a transitive allocation under @realtime
./znc examples/audio_render_bad.zag -o /tmp/bad   # exits non-zero with E0002 diagnostics

# Try the heterogeneous numeric types
./znc examples/embedded_sensor.zag -o embedded_sensor --run   # u11 + sat_i16 + fixed_8_8
./znc examples/hpc_rns.zag -o hpc_rns --run                   # rns_3 residue arithmetic
./znc examples/safe_bignum.zag -o safe_bignum --run           # u_any overflow-safe sums

# Run the v1 release gate
bash tests/run_native_authority.sh
```

**What the bad-program check reports:**
```
error[E0002]: capability violation — `@realtime` constraint broken in function `gain`
   = effect path [Alloc]: gain -> reverbScratch -> zalloc() [Alloc]
error[E0002]: capability violation — `@realtime` constraint broken in function `renderBlock`
   = effect path [Alloc]: renderBlock -> gain -> reverbScratch -> zalloc() [Alloc]
znc: capability check FAILED
```

The proof propagates effects through the call graph without annotations on
intermediate functions. Generic callbacks render their call-site binding,
closures render their source line, imported helpers render their module path,
and recursive cycles terminate without hiding a reachable source operation.

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
  Parser         recursive-descent, produces a typed AST
    │
    ▼
  Sema           type checker + effect prover
    │             ├─ infers types for every expression
    │             ├─ walks the call graph collecting effects (Alloc/Lock/IO/Panic)
    │             └─ checks every @annotation claim, emits E0002 on failure
    │
    └── native codegen ──► static x86-64 ELF (./znc)
```

The supported compiler is a self-hosted Zag program in `zag-poc/selfhost/native/`
(`znc.zag`). The Python prototype, Zig bootstrap, and C-emitting `zagc` path
live only in Git history. The supported tree emits x86-64 and experimental
ARM64 machine code, WASM output, and bounded GPU frontend/bundle artifacts
without Python, C, Zig, LLVM, or a host C toolchain.

### The effect system

Every function has an **inferred effect set**: the union of all effects in its body and all its callees, propagated up by least-fixed-point over the call graph.

```
Alloc        may allocate or free heap memory
Lock         may block on a mutex or syscall that parks the thread
IO           may touch the OS (files, sockets, stdout)
Panic        may trap at runtime (div-by-zero, overflow, OOB, null-unwrap)
DeviceAlloc  may allocate GPU memory (legacy GPU path)
DeviceIO     may launch a GPU kernel (legacy GPU path)
```

A capability annotation is a **claim** that a named effect is absent. The compiler proves or rejects:

```zag
fn renderBlock(buf: []f32, n: i32) void @realtime {
    // compiler proves: Alloc, Lock, IO cannot be reached from here
    // if it can't prove it, the program does not compile
}
```

**Effects flow through function types.** A function value carries its effect set as part of its type. A callback stored in a struct field, pulled out, and called on the audio thread is proven safe at compile time. Storing an allocating function in a `@realtime` bounded field is rejected at the store, before any call ever happens.

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
`i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `usize`, same idea as Zig.

#### Arbitrary-width integers: `u3`..`u127`, `i3`..`i127`
Any bit width. The compiler inserts the mask automatically after every arithmetic operation. No manual `& 0x7FF`, no forgotten masks, no silent truncation.

```zag
let reading: u11 = adcRead();         // 11-bit sensor value; fits in uint16_t
let centred: u11 = reading - 1024;    // (reading - 1024) & 0x7FF, emitted by compiler
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
Q-format fixed-point where `I` is integer bits and `F` is fractional bits. `fixed_8_8` is Q8.8, stored as `int16_t`. Multiply does `(a * b) >> F` in `int64_t` with no rounding error per step, unlike float.

```zag
let alpha: fixed_8_8 = 32;        // 0.125 in Q8.8 (0.125 * 256 = 32)
let result: fixed_8_8 = alpha * x; // (32 * x) >> 8 — exact, no float drift
```

#### Posits: `p8`, `p16`, `p32`, `p64` + `quire`
Gustafson's universal number format. More dynamic range than IEEE floats at the same bit width, with tapered precision. The `quire` is a 512-bit exact accumulator for fused multiply-add without rounding until you need the final result.

```zag
let q: quire = @quireZero();
q = @quireFMA(q, a, b);   // exact: no rounding between steps
let result: p32 = @quireToPosit(q);
```

#### Register-first bignum: `u_any`, `i_any`
Arbitrary-precision integers that start as register values. Arithmetic that might overflow introduces the `Alloc` effect, so you cannot accidentally use bignum math in a `@noalloc` or `@realtime` context.

```zag
fn allocSize(count: u_any, elem_size: u_any) u_any {
    return count * elem_size;   // Alloc effect: tracked, cannot sneak into @noalloc
}
```

Standard `count * size` in C overflows silently. In Zag the overflow is tracked by the type system and forbidden in any context that can't afford it.

#### Residue Number System: `rns_3`, `rns_4`, ...
Stores a value as N residues over coprime moduli. Add and multiply are channel-independent with no carry across lanes.

```zag
fn polyEval(x: rns_3, c0: rns_3, c1: rns_3, c2: rns_3) rns_3 @pure {
    return c0 + x * (c1 + x * c2);   // three independent mod-ops per step
}
```

`rns_3` arithmetic has no `Alloc` and no `Panic`, so functions using only RNS arithmetic can be annotated `@pure`.

#### GPU-native types (all GPU targets)
Types that map to hardware that Vulkan SPIR-V cannot represent:

| Type | What it is | MLIR type | Hardware |
|---|---|---|---|
| `l32` / `l16` | Logarithmic Number System | `i32` / `i16` | LNS ASIC, mul/div = integer add/sub |
| `bf16` | bfloat16 | `bf16` | A100/H100 tensor cores |
| `mx_fp8` | MX Microscaling FP8 E4M3 | `f8E4M3FN` | Blackwell B100 block-scaled GEMM |
| `mx_fp4` | MX Microscaling FP4 E2M1 | `f4E2M1FN` | Extreme-density speculative decoding |
| `vsa_b<N>` | N-dimensional binary hypervector | `vector<Nxi1>` | GPU bitwise SIMD |

### GPU frontend emission (legacy path)

MLIR emission for `@kernel` functions is implemented in `selfhost/mlir.zag` and
exercised through a legacy differential path. It is not a production backend:
no device is enumerated, no context/buffer is created, and no result is read
back or checked.

The supported self-hosted compiler ships the custom Zag-native
`amdgpu-gfx1010` target. It emits validated ZGK1 RDNA1 bundles without LLVM or
MLIR. Pure-Zag userspace runtimes consume them through the existing Linux
AMDGPU driver UAPI. Future portable targets use custom Zag SPIR-V or PTX
generators over installed Vulkan/CUDA drivers; Zag does not rewrite privileged
kernel drivers or firmware. The executable contract is `std:gpu_platform`; see
`zag-poc/docs/GPU_COMPILER_DRIVER_BOUNDARY.md`.

---

## The annotations

| Annotation | Forbids | Use case |
|---|---|---|
| `@realtime` | `Alloc`, `Lock`, `IO` | Audio thread, interrupt handler, hard-deadline path |
| `@noalloc` | `Alloc` | Hot decode path, embedded systems, stack-only code |
| `@total` | `Panic` (+ `Diverge`) | Replace every `catch unreachable`, prove no runtime crash |
| `@pure` | `Alloc`, `Lock`, `IO`, non-local mutation | Math functions, compile-time evaluation candidates |
| `@kernel` | `Alloc`, `Lock`, `IO` | GPU kernel function |
| `@device` | `Alloc`, `Lock`, `IO` | GPU device helper called from `@kernel` |

---

## Build targets

The supported v1 compiler emits **x86-64 Linux ELF** as its primary target and
supports a scoped **AArch64 Linux** target:

```bash
./znc file.zag -o program
./znc file.zag -o program --run
./znc file.zag -o program --debug
./znc file.zag --target arm64 -o program
```

Static AArch64 v1 output is verified through qemu-user and native ARM CI;
edition-2027 object and dynamic output have separate bounded gates. This does
not imply parity for every x86-64 v2 feature. WebAssembly is artifact-only and
GPU claims are limited to their exact compatibility gates. See the
[support contract](zag-poc/docs/SUPPORT.md).

---

## Examples

```
examples/
  audio_render.zag        @realtime audio render block, proven clean
  audio_render_bad.zag    transitive allocation rejected with E0002 diagnostics
  synth.zag               @noalloc synth + @total quantizer
  embedded_sensor.zag     u11 ADC + sat_i16 DSP + fixed_8_8 IIR
  hpc_rns.zag             rns_3 polynomial eval + fixed_16_16 dot product
  safe_bignum.zag         u_any overflow-safe arithmetic
  process_poly.zag        effect polymorphism through a generic callback
  closure_basic.zag       stack-captured closure
  generic_map.zag         generic map[T] with effect composition
  posit_multi.zag         p8/p16/p32/p64 family arithmetic
  quire.zag               512-bit exact accumulator
  gpu_matmul_mx.zag       MX-FP8 kernel (development GPU frontend path)
```

---

## Project status

Zag v1 is a self-hosted native compiler (`./znc`) that boots from a committed seed, rebuilds itself without a host C toolchain, and ships a growing stdlib under `selfhost/std/`.

### Readiness boundary

The current evidence supports a bounded Linux/x86-64 experimental release, not
a general C replacement. The first master-gate phase currently passes a
three-generation pure-Zag rebuild to a byte-identical fixpoint. A complete
release claim still requires the declared native, compatibility, Script, and
target gates to pass on the exact release tree.

The following remain explicitly outside a production-v2 claim: a complete
provenance/alignment/lifetime model, general portable atomics and concurrency,
complete C ABI and dynamic-library interoperability, whole-language memory
safety, async/await, RAII/destructors, and a general native direct-DRM GPU
backend. The compat gate is separate bounded evidence: it does
prove device dispatch/readback for the three supported local APIs, while GPU
MLIR and ZGK1/VM evidence must not be described as that proof. See
[`zag-poc/docs/V2_FINAL_VERIFICATION.md`](zag-poc/docs/V2_FINAL_VERIFICATION.md)
and [`zag-poc/docs/GPU_COMPILER_DRIVER_BOUNDARY.md`](zag-poc/docs/GPU_COMPILER_DRIVER_BOUNDARY.md).

C interoperability is an incremental-replacement bridge, not a Zag-to-C
translation path: Zag source is compiled directly by Zag's native compiler.

| Area | Current supported status |
|---|---|
| Call-graph effect proofs (`@realtime`, `@noalloc`, `@pure`) | Yes |
| Transitive effect rejection, effect polymorphism, closures | Yes; complete per-effect call-path witnesses are rendered |
| Posits, quire, saturating ints, `u11`, fixed-point, RNS | Yes |
| Native stdlib, LSP, formatter, DWARF | Yes |
| `@total` proofs | Gated (`run_native_total.sh`); bounded, not universal arithmetic proof |
| GPU compat execution | Vulkan/OpenGL/OpenCL bounded dispatch/readback verified on local RX 5700 XT (`run_gpu_runtime.sh`, `run_gpu_zag_runtime.sh`); native DRM remains separate |
| WebAssembly emission | Yes (`--target wasm`; `run_native_wasm.sh`); runtime scope is bounded |
| multi-arch CPU | AArch64: supported scoped target; i686: limited milestone; RISC-V: unsupported |

The complete platform, package, ownership, concurrency, ABI, and memory-safety
boundary is maintained in [`zag-poc/docs/SUPPORT.md`](zag-poc/docs/SUPPORT.md).
The current local/vendored dependency workflow is documented in
[`zag-poc/docs/DEPENDENCIES.md`](zag-poc/docs/DEPENDENCIES.md).

Release gates:

```bash
cd zag-poc
bash tests/run_native_authority.sh
bash tests/run_native.sh
bash tests/run_native_gpu.sh
bash tests/run_gpu_runtime.sh
bash tests/run_native_wasm.sh
bash tests/run_native_total.sh
bash tests/run_zagscript_release_gate.sh
```

The authoritative v2 gate is intentionally fail-closed and remains nonzero
while any required v2 capability is marked `UNSUPPORTED`:

```bash
bash tests/run_v2_release_gate.sh
```

`bash run_tests.sh` is a historical differential suite retained only for
archival comparison; it is not a supported compiler path or a release gate.

---

## Repository layout

```
README.md                          project overview (this file)
zag-poc/
  INSTALL.md                       install and test instructions
  BOOTSTRAP.md                       bootstrap history and seed chain
  docs/V1_LANGUAGE_SPEC.md         frozen v1 language boundary
  znc                              committed native seed compiler
  bootstrap.sh                     rebuild ./znc from selfhost/native/znc.zag
  selfhost/                        compiler sources (lexer, parser, sema, native codegen, LSP)
  tests/                           v1 release gates
  examples/                        small demonstration programs
  programs/                        larger acceptance programs + GAPS.md
  run_tests.sh                     historical differential suite (archival)
editors/vscode/                    VS Code extension
linguist/                          GitHub Linguist registration notes
```

---

## License

See [LICENSE](LICENSE).
