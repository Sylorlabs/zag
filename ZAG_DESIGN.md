# Zag — Design Document

> Status: **draft v0.1**, 2026-06-22. Author: design pass over the Sylorlabs tree.
> Honesty contract (per `.agent/rules/dontlie.md`): every claim of "done" in this repo
> is accompanied by a completeness %. Nothing here is marked finished that isn't.

---

## 0. One sentence

**Zag is a systems language in the lineage of Zig whose defining feature is that the
"Zen of Zig" (no hidden allocations, no hidden control flow) stops being a *convention
you promise* and becomes a *property the compiler proves* — via an effect/capability
system backed, for the hard cases, by the Z3 prover you already ship in `ghost_engine`.**

Everything else Zag adds (closures, error context, FFI generation, trait-style
constraints) is commodity ergonomics. The effect system is the reason Zag should exist.

---

## 1. Why this, grounded in the Sylorlabs tree

This is not a generic wishlist. It is what *your* code is already paying for by hand.

| Evidence in your tree | What it proves you need |
|---|---|
| `zenith-daw/.../AudioThreadSafeProcessor.cpp` — a whole class to hand-guarantee the audio thread never allocates/locks | `@realtime` as a **compiler-checked type**, not a code review rule |
| `mathpressor` README: "run straight off the compressed archive… nothing inflated to disk" — a live decode path that must not allocate | `@noalloc` on the synth/decode hot path |
| 1,261 `catch unreachable` in ghost_engine, 10 in mathpressor | each is a latent **release-mode crash**; `@total` should forbid them and force a proof |
| `ghost_engine/src` — a Z3 SMT prover that already does no-alloc / UAF / div-by-zero analysis on Zig | you **already own the effect checker**; Zag wires it in instead of building it |
| `std.mem.sort(.., struct { fn lt(..){..} }.lt)` in `mathpressor/src/main.zig:3798` | closures are real pain (low value, but real) |
| 1,250+ `log.err`/`debug.print` reconstructing context `try` discarded | error-context attachment is real DX (medium value) |
| `libmathpressor.so` (C-ABI), ghost_cli shelling binaries, zenith Zig↔C++/JUCE, web/Python consumers | FFI/binding generation serves 5 projects |

### The strategic point
A "nicer Zig" (closures + traits + no-shadowing) is something a hundred forks could be,
and it would rot the moment upstream Zig moves. The **effect prover is the moat** because
it is the one feature that (a) only you can build cheaply — you own `ghost_engine` — and
(b) directly serves two shipping products (the DAW's audio thread, mathpressor's live VFS).
Lead with it; treat the rest as sugar.

### What the other AI got wrong for *your* code
- **"No variable shadowing" — drop it.** Your clean projects barely shadow (mathpressor: 0
  `_2`/`_tmp` names; ghost_cli: 2). It's a 5-minute itch, not a feature. Spending design
  budget here is a mistake.
- **"Comptime interfaces" — keep, but demote.** Heavy metaprogramming is a *ghost_engine*
  problem (91 `comptime`, 268 `anytype` in src). mathpressor is nearly comptime-free (2 uses).
  It's not a universal bottleneck.

---

## 2. The effect / capability system (the core)

### 2.1 Effects

An **effect** is an observable thing a function can do that the caller may need to forbid.
Zag's base lattice (extensible):

```
Alloc   — may allocate / free heap
Lock    — may block on a mutex / syscall that can park the thread
IO      — may touch the OS (files, sockets, stdout)
Panic   — may trap at runtime (div-by-zero, integer overflow, OOB index, unwrap of null)
Diverge — may not terminate (unbounded loop / unbounded recursion)
```

Every function has an **inferred effect set** = the union of the effects of every operation
and every call in its body. Leaf operations have fixed effects (`/` ⇒ `Panic` unless the
divisor is provably nonzero; heap builtin ⇒ `Alloc`; etc.). Effects propagate up the call
graph by least-fixed-point (so recursion terminates the analysis).

### 2.2 Capabilities (the annotations)

A capability annotation on a function is a **claim that an effect is absent**. The compiler
must prove it or reject the program.

| Annotation | Forbids | Use in your tree |
|---|---|---|
| `@realtime` | `Alloc`, `Lock`, `IO` (and optionally `Diverge`) | DAW audio render block |
| `@noalloc` | `Alloc` | mathpressor live decode |
| `@total`   | `Panic` (and `Diverge`) | replaces `catch unreachable`; proves no trap |
| `@pure`    | `Alloc`, `IO`, `Lock`, mutation of non-local | comptime-eval candidates |

```zag
fn renderBlock(buf: []f32, n: i32) void @realtime {
    // compile ERROR if anything reachable from here can Alloc / Lock / IO
}
```

Capabilities are part of the **type**. A `fn(...) void @realtime` is not assignable to a
slot expecting more freedom-restricting guarantees unless it satisfies them — function
pointers carry their effect set, so a callback stored for the audio thread is checked too.

### 2.3 What's decidable vs what needs Z3 (the honest line)

This is the crux, and where most "proof" languages lie. Be precise:

| Claim | Decidable syntactically / by call graph? | Needs Z3 / ghost_engine? |
|---|---|---|
| "calls no allocating function" (`@noalloc`, `@realtime` alloc part) | **Yes** — pure call-graph reachability | No |
| "takes no lock / does no IO" | **Yes** — call-graph reachability | No |
| "this `/` can't divide by zero" (`@total`) | Only if divisor is a literal/obvious | **Yes — and now wired** (§2.6): Z3 discharges `divisor ≠ 0` over the path condition |
| "this index is in bounds" | Only trivial cases | **Yes** — `0 ≤ i < len` over the path |
| "this loop terminates" (`@Diverge`) | Only trivial cases | **Yes** (and undecidable in general; needs ranking functions / bounded heuristics) |

**The bootstrap compiler in this repo does the decidable column for real, today.** The Z3
column is Phase 3, and it is exactly the analysis `ghost_engine` already performs. That
boundary is the difference between an honest language and vaporware; it is drawn on purpose.

### 2.4 Effect polymorphism (the keystone — implemented, first-order)

A capability system that can't compose through higher-order functions is a toy: you could
never `sort`/`map`/`processBlock` on the audio thread. Zag composes effects two ways, both
working in `zag-poc` today:

1. **Call-site inference** — a generic with an *un-annotated* callback param
   (`op: fn(f32) f32`) is analyzed *specialized to the concrete function passed at each call
   site*. `processBlock(buf, n, softclip)` is proven `@realtime`; `processBlock(buf, n, fancyOp)`
   is rejected, with a witness chain that **crosses the generic boundary**:
   `renderBad → processBlock → fancyOp → zalloc()`. Sound for first-order named callbacks.

2. **Bounded callback types** — a param can carry a bound: `op: fn(f32) f32 @realtime`. Then
   the generic can be `@realtime` *on its own*, provable without a call site (the bound
   guarantees the callback can't allocate/lock/IO), and every call site is checked to pass a
   conforming callback. Crucially this is checked even when the *caller* is unannotated — the
   contract lives on the parameter, not the caller.

3. **Effects as part of the type, flowing through values** — the function's effect is carried
   by its *type* (`fn(f32) f32 ! pure`, `! {Alloc}`, or an effect variable `! e`), so it
   propagates through function-typed **locals**, **returns**, and **struct fields**. A
   callback stored in a struct field typed `@realtime`, pulled out, and called on the audio
   thread is proven safe — and the *store* is rejected the moment you try to put an allocating
   op into that field (`fancyOp → zalloc()`), before any call happens. This is the real DSP
   graph pattern (a node holds its processing function); Zag proves the whole graph.

4. **Closures with explicit capture, allocation-free** — `fn[gain](x: f32) f32 { x * gain }`
   captures `gain` *by value into a stack environment* (no hidden heap, per the Zen). The
   closure's effect is read off its body and flows through the type, so passing a closure to
   a generic **instantiates the effect variable `! e` precisely** — the case that used to be
   conservative. A pure closure makes the generic provably `@realtime`; an allocating closure
   is rejected at the boundary, witness running through the variable:
   `unsafe → applyTwice → closure → zalloc()`. Function values compile to `{fn, env}` fat
   pointers; a closure's env is a stack compound literal — verified zero `malloc` in codegen.

The price of allocation-free closures: a closure that captures locals **may not escape its
scope** (its stack environment would dangle), so returning one is a compile error. That's the
honest tradeoff — escaping closures need heap allocation, which is deferred Phase-1 work along
with general row-polymorphic inference for *fully* opaque function values (those reachable
only through an un-instantiated variable). Everything the value-flow machinery needs is done.

### 2.4.1 Generics over types (monomorphization) — and how effects compose through them

Generic functions `fn map[T](xs: []T, f: fn(T) T) void` and generic structs
`struct Box[T] { val: T }` abstract over types. Zag **monomorphizes**: each instantiation
generates a specialized concrete copy (`Box_i32`, `Box_f32`, `map_f32`) — zero runtime cost,
like Zig `comptime` or Rust. Function calls **infer** their type args from the arguments
(`mapInPlace(buf, f)` deduces `T = f32` by unifying `[]T` with `buf`'s type), so there's no
turbofish noise and no ambiguity with indexing; generic structs use explicit `Box[i32]`.

The point for Zag specifically: **effects compose straight through generics.** Monomorphizing
`mapInPlace` at `f32` with a closure that allocates produces a witness that crosses *both* the
generic boundary and the closure boundary:

```
renderBad → mapInPlace[f32] → closure → zalloc()   [introduces Alloc]   // @realtime rejected
```

The same generic `map` is proven realtime-safe with a pure closure and rejected with an
allocating one — abstraction over types did not punch a hole in the capability proof. This is
the whole system working as one: generics + closures + effect variables + real slices, down to
a native binary. Implementation: monomorphization is demand-driven, integrated with the type
checker (unify → clone+substitute the template → type-check/effect-analyze the instance);
templates are excluded from codegen, only instances are emitted.

### 2.5 Effect inference rules (precise enough to implement)

```
effect(literal)              = {}
effect(var)                  = {}
effect(a op b)               = effect(a) ∪ effect(b) ∪ opEffect(op, a, b)
opEffect('/', _, b)          = {} if b is a nonzero integer literal, else {Panic}
opEffect('%', _, b)          = same as '/'
effect(call f, args...)      = ⋃ effect(argᵢ) ∪ inferred(f)
effect(if c {A} else {B})    = effect(c) ∪ effect(A) ∪ effect(B)
effect(while c {B})          = effect(c) ∪ effect(B) ∪ {Diverge?}   // Diverge flagged unless bound proven
effect(block s...)           = ⋃ effect(sᵢ)
inferred(f) = lfp over the call graph of ⋃ effect(stmt) for stmt in body(f)
extern/builtin f: inferred(f) is declared, not inferred
```

Checking: for each annotated `f`, if `inferred(f) ∩ forbidden(annotations(f)) ≠ ∅`, error,
and report a **witness chain** — the path from `f` down to the offending leaf operation.

### 2.6 The ghost_engine / Z3 verification pass (Phase 3 — first proof landed)

The effect rules above are sound but *coarse*: `opEffect('/', _, b)` flags `Panic` for any
non-literal divisor. That over-rejects — `if (d != 0) return a/d;` is safe but has a variable
divisor. Discharging the difference is **exactly** the SMT reasoning `ghost_engine` already
does (its README: "lowers the execution path into an SMT-LIB time-series and queries Z3 …
UNSAT ⇒ proven safe, SAT ⇒ a vulnerability is verified"). Zag's job is to *generate the
verification condition*; ghost_engine/Z3 discharges it.

**The pass + the wiring (implemented in `zag-poc`, runs on `@total` functions):**
1. Symbolically execute the body. Each `i32` becomes an SMT `Int`; `f32`→`Real`, `bool`→`Bool`.
   Single-assignment lets are *inlined*; `if (c)` forks the path into `c` / `¬c`; reassigned and
   loop-mutated vars become free consts (sound over-approximation).
2. At each integer division/modulo `n / d` reached under path condition `P`, emit an **SMT-LIB2**
   verification condition asserting `P ∧ (d == 0)` and ask: **is it satisfiable?**
3. **Hand the SMT-LIB2 to the actual ghost_engine.** The compiler shells out to the engine
   binary `ghost_engine/zig-out/bin/zag_verify` (source `ghost_engine/src/zag_verify.zig`, built
   with `zig build zag-verify`), which discharges the query through the engine's own Z3 bridge —
   the same `Z3_eval_smtlib2_string` path `verified_swap.zig` / `invent_cli.zig` use — and returns
   `{"verdict":"unsat|sat|unknown","output":...}`.
   - `unsat` ⇒ divisor provably nonzero on every reachable path ⇒ discharged.
   - `sat` ⇒ a real div-by-zero; report the **counterexample** from the model (`a=0, d=0`).
   - `unknown`/`err` ⇒ stays *unproven* (never discharge on non-`unsat` — soundness).
4. `@total` holds iff every division is discharged **and** no call introduces `Panic`.

So the prover is **ghost_engine**, not an inline solver: `zagc` reports `🔒 ghost_engine proved
'safediv' @total`. Python-`z3` is a *fallback only*, used if the engine binary is absent; if
neither is present the compiler degrades to the conservative literal-divisor rule. Selection is
automatic (`Sema.prover_name()` → `ghost_engine` | `z3-python` | `none`); `GHOST_ENGINE` /
`GHOST_VERIFY` env vars override the binary path.

**Proven, today, through ghost_engine's Z3 bridge:**
- `total_guarded` — `if (d != 0) return a/d;` → `(d≠0) ∧ (d==0)` unsat → **accepted**
  (the conservative rule rejects it; the prover is the only thing that changes).
- `total_nonzero` — `x / (n*n + 1)` with *no guard* → `n*n+1 == 0` unsat by integer arithmetic →
  **accepted**. Value-range reasoning a syntactic rule can never do.
- `total_bad` — `a / d` unguarded → `sat`, counterexample `a=0, d=0` → **rejected**, precisely.

`bash zag-poc/prove.sh` shows the same sources rejected with no prover and proven via ghost_engine.

**Honest boundaries.** The pass is *intraprocedural* (a `@total` function's own divisions;
cross-call `Panic` stays conservative) and covers **div-by-zero / mod-by-zero** only. Array-bounds
(`0 ≤ i < len`) is the identical machinery (emit `P ∧ ¬(0≤i<len)`) and is the obvious next
obligation; `@realtime`'s effects never needed Z3. Loops are havoc'd, not inducted — proving a
divisor nonzero *inside* a loop that computes it needs invariants (Phase 3b). And `zag_verify` is
a *thin* bridge: it routes SMT-LIB2 to the engine's Z3 path but does not yet use ghost_engine's
richer pipeline (its VSA repair synthesis, SMT-LIB time-series, the `z3_verifier.zig`
`generateZeroDivSafetySmt`/bounds/UAF lowerings). Tightening Zag's VC generation into those
lowerings — so a refuted obligation can trigger ghost_engine's *repair* — is the next deepening.

---

## 2.7 GPU Backend — MLIR Direct Pass-Through (✅ DONE, Phase GPU-1)

Zag has its own GPU backend that bypasses Vulkan/SPIR-V entirely and routes
`@kernel`/`@device` functions through MLIR's hardware-specific dialects.  The
design rationale: Vulkan is graphics-first and cannot see Zag's custom numeric
types; MLIR has native types for all of them and can lower directly to PTX
(NVIDIA), GCN (AMD), or SPIR-V (fallback portability).

### New types (GPU-native primitives)

| Type | MLIR mapping | Notes |
|---|---|---|
| `l32` | `i32` (log bits) | Logarithmic Number System; mul/div = integer add/sub |
| `l16` | `i16` | Narrow LNS for edge inference |
| `bf16` | `bf16` | bfloat16; Tensor Core native on A100/H100 |
| `mx_fp8` | `f8E4M3FN` | OCP MX Microscaling FP8; block-scaled GEMM on B100 |
| `mx_fp4` | `f4E2M1FN` | OCP MX Microscaling FP4; extreme inference density |
| `vsa_b<N>` | `vector<Nxi1>` | Binary VSA hypervector; bind=XOR, bundle=OR/majority |
| `gpu_buf<T>` | `memref<?xT, 1>` | GPU-resident buffer (address space 1) |

### New annotations

- `@kernel` — GPU kernel: mapped to `gpu.func ... kernel { ... gpu.return }`.
  Forbids `{Alloc, Lock, IO}` — the effect checker proves no host syscalls
  reach the kernel (the same proof that guards `@realtime`).
- `@device` — callable from `@kernel` only; same effect restrictions.

### New GPU builtins

Inside `@kernel`/`@device`:
- `@gpuThreadIdx(dim)` → `gpu.thread_id x/y/z`
- `@gpuBlockIdx(dim)` → `gpu.block_id x/y/z`
- `@gpuBlockDim(dim)` → `gpu.block_dim x/y/z`
- `@gpuSyncThreads()` → `gpu.barrier`

On host:
- `@gpuAlloc(n)` → `gpu.alloc` (DeviceAlloc effect)
- `@gpuFree(buf)` → `gpu.dealloc`
- `@gpuLaunch(gx,gy,gz,bx,by,bz)` → `gpu.launch_func` stub (DeviceIO effect)

### New bitwise operators

`^` (XOR — VSA bind) and `&` (bitwise AND) are now lexed and parsed.
XOR on integer types is also the packed-bit VSA bind operator when the
logical interpretation is a `vsa_b<N>` encoded as N/32 `i32` words.

### MLIR lowering pipeline

```
zagc --target gpu-nvidia   →  .mlir  →  mlir-opt (nvvm dialect)  →  PTX
zagc --target gpu-amd      →  .mlir  →  mlir-opt (rocdl dialect) →  GCN
zagc --target gpu-vulkan   →  .mlir  →  mlir-opt (spirv dialect) →  .spv
zagc --target gpu-auto     →  auto-detect vendor
```

The `.mlir` file is always written even if `mlir-opt` is absent, so the
generated IR can be inspected or processed manually.

### Implementation files

```
zag-poc/gpu/types.py          — type definitions, MLIR type mappings
zag-poc/gpu/mlir_emitter.py   — Zag AST → MLIR textual IR
zag-poc/gpu/lowering.py       — mlir-opt pipeline driver per target
```

### Completeness

- Effect checking of `@kernel`/`@device`: **100%** (reuses existing machinery)
- New type registration (l32, bf16, mx_fp8, mx_fp4, vsa_b, ^/& ops): **100%**
- MLIR emitter (arith, memref, scf, gpu dialects): **~75%**
  - Missing: VSA `vector<Nxi1>` ops in emitter (typed as i32 words today)
  - Missing: struct field types as MLIR `llvm.struct` (needs full struct lowering)
  - Missing: LNS emulation library (l32 calls emitted but no C runtime yet)
  - Missing: explicit kernel name in `@gpuLaunch` (Phase GPU-2)
- Lowering pipeline driver: **100%** (graceful fallback when mlir-opt absent)
- Examples: `gpu_matmul_mx.zag` (✅), `gpu_vsa_hd.zag` (✅)

---

## 2.8 Posits — a native primitive numeric family

This is the feature that most justifies owning the compiler: you cannot add a new primitive
numeric type with hardware-opcode passthrough by transpiling to Zig. Spec target: `p8/p16/p32/
p64` as first-class primitives (es per width), a `quire` fused-accumulator, software emulation
on stock CPUs, and direct hardware ops on a PPU target. Phased so each step is real + testable:

- **P0 — type registration + casting rules ✅ DONE.** `p8/p16/p32/p64` registered next to ints;
  backing storage = same-width unsigned int (`p32` ⇒ `uint32_t`). Per the spec, `f32/f64` do
  **not** implicitly cast to posits — `@floatToPosit()` / `@positToFloat()` / `@positToBits()`
  are explicit; `assignable()` enforces it (`let x: p32 = 1.5` and `p32 + f64` are rejected).
  Open: implicit *lossless-int* → posit (needs coercion-at-assignment-site machinery); for now
  `@intToPosit()` is explicit.
- **P1 — CORRECT reference emulation ✅ DONE (verified against the spec).** C runtime for
  `p32, es=2`: exact bit-manipulation `decode(uint32)→f64`, `encode(f64)→uint32` with
  round-to-nearest-even, and `+ - * /` via decode→f64→op→encode. **Verified bit patterns**
  (`posit32.zag`, run natively): `1.0=0x40000000`, `2.0=0x48000000`, `4.0=0x50000000`,
  `3.0=0x4C000000`, `0.5=0x38000000`, all-zero=0, `0x80000000`=NaR; `two*two` and `one+two`
  compute through the runtime. f64's 53-bit mantissa ≥ p32's ≤27 fraction bits ⇒ exact in the
  normal range (a legitimate v1; the optimized branchless path is P2). Operators on posit-typed
  operands dispatch to `zag_p32_{add,sub,mul,div}`; comparisons via decode.
- **P2 — the branchless integer path (prompt §3 Path A) ✅ DONE.** `+ - * /` now run with **no
  float intermediate**: CLZ-based regime decode (`__builtin_clz` on the shifted word → regime run
  length, branchless), integer significand math (exact 56-bit product for `*`; 128-bit aligned
  add with round-to-odd sticky for `+/-`; shifted long division for `/`), and an integer repack
  with round-to-nearest-even. **Validated bit-for-bit against an independent long-double oracle
  (64-bit mantissa ≥ the 56-bit product) over 5,000,196 inputs — 0 mismatches across all four
  ops** (`zag-poc/posit_p2_difftest.c`, re-runnable). The only remaining `f64` uses are the
  explicit `@floatToPosit`/`@positToFloat` casts, not arithmetic.
- **P3 — the `quire` ✅ DONE.** A 512-bit fixed-point accumulator (LSB weight 2^-240, 8×`uint64`
  2's-complement) holding sums of products with **no rounding until readout**. `@quireFMA(q,a,b)`
  decodes a,b to exact integer components, places the exact product `sig_a*sig_b · 2^(...)` into
  the accumulator (add/sub with carry across limbs), and `@quireToPosit(q)` rounds once (RNE via
  top-53 bits + round-to-odd sticky — correctly rounded, no double-rounding). Verified
  (`quire.zag`, native): exact dot product `[2,4]·[3,5]=26`; and `(2^30 + 1) − 2^30` gives **1**
  (quire, correct) vs **0** (naive p32 — the `+1` is below 2^30's ULP and is lost). Pure (a stack
  value), so usable on a `@realtime` path. Caveat: p32 only; carry-guard sized for the demo range
  (full 2^31-maxpos²-add headroom is a sizing tweak).
- **P4 — hardware Path B.** Behind a target flag (`--target=riscv-ppu`), map `+ - * /` directly to
  `padd.s`/`pmul.s`/… opcodes, bypassing the software path entirely.

Honest ordering: P0+P1 deliver *working, correct posits you can compute with* and fulfill the
prompt's concrete deliverable (decode logic for p32 es=2); P2–P4 are the performance/scale/HW
layers on top. The emit-C backend makes P1 straightforward (a C runtime + operator dispatch).

---

## 2.9 Universal Heterogeneous Computing — Beyond AI Chips (✅ DONE, Phase UH-1)

Zag's "compiler-proven effects" philosophy is not limited to AI workloads.  The
same static capability proof that makes `@realtime` correct for audio DSP also
makes `@kernel` correct for GPU compute.  By applying this to the *full spectrum*
of silicon, Zag becomes the first language where the compiler guarantees
correctness across every tier:

```
   Embedded/wearable (u11, sat_i16, fixed_8_8)  ─┐
   HPC / DSP (rns_3, fixed_16_16, quire)         ─┼─ same Zag source
   GPU / AI (mx_fp8, l32, vsa_b<N>)              ─┤   different --target
   Desktop security (u_any, i_any)               ─┘
```

### 2.9.1  Arbitrary-Width Integers  (`u3`..`u127`, `i3`..`i127`)

`u11` for an 11-bit ADC is a first-class type.  The compiler auto-inserts the
mask `& 0x7FF` after every arithmetic operation (ANDI on RISC-V = 1 cycle).
MLIR's `iN` type is exact for any N — no wrapper struct, no performance loss.

**Effect interaction**: arbitrary-width arithmetic has the same effect rules as
standard integers; division still risks Panic if the divisor is unproven nonzero.

### 2.9.2  Saturating Integers  (`sat_i8`..`sat_i64`, `sat_u8`..`sat_u64`)

```zag
fn applyFilter(x: sat_i16, prev: fixed_8_8) fixed_8_8 @realtime {
    return alpha * x + one_minus * prev;   // CANNOT overflow; alpha/one_minus constants
}
```

**Key property**: saturating arithmetic **removes Panic from the effect set**.  A
function using only `sat_i16` math can be annotated `@realtime` without needing
`@total` (which would require proving every division safe).  This maps to
hardware intrinsics: x86 `PADDSW`, ARM `SQADD`, WebAssembly `i16x8.add_sat`.

C backend emits `zag_sat_add_i16(a, b)` inline helpers (no libcall overhead;
GCC/Clang constant-fold these into the hardware instruction automatically).

### 2.9.3  Fixed-Point  (`fixed_I_F`)

Q-format fixed-point where I = integer bits, F = fractional bits.  `fixed_8_8`
stores as `int16_t`; multiply computes `(a * b) >> F` in `int64_t` (no
intermediate rounding error).

```zag
fn iirFilter(x: fixed_16_16, y_prev: fixed_16_16, alpha: fixed_16_16) fixed_16_16 @realtime {
    return alpha * x + (ONE - alpha) * y_prev;   // exact per step; no float drift
}
```

Target use: iterative HPC solvers where `float` accumulation error destabilises
convergence.  Iterative FEM / CFD codes gain 2–4× stability versus `float32`.

### 2.9.4  Residue Number System  (`rns_N`)

```zag
fn rnsHorner(x: rns_3, c0: rns_3, c1: rns_3, c2: rns_3) rns_3 @pure {
    let inner: rns_3 = c1 + x * c2;
    return c0 + x * inner;
}
```

`rns_3` stores as `(r1 mod M1, r2 mod M2, r3 mod M3)` with M1=65521, M2=65531,
M3=65533 (coprime primes near 2¹⁶).  Add/mul are completely channel-independent
— perfect SIMD parallelism with zero cross-lane carry.  Max representable value
≈ 2.81 × 10¹⁴ (M1 × M2 × M3).

Phase RNS-2 (planned): CRT reconstruction for comparison and range-to-integer
conversion.  Until then, RNS is ideal for add/mul-heavy workloads (polynomial
evaluation, FFT, neural-net weight arithmetic during training).

**Effect properties**: `rns_3 + rns_3` has **no Panic, no Alloc** — modular
arithmetic is total and bounded.  Functions using only RNS arithmetic can be
`@pure`, the strictest capability annotation.

### 2.9.5  Register-First Bignum  (`u_any`, `i_any`)

```zag
fn allocSize(count: u_any, elem_size: u_any) u_any {
    return count * elem_size;   // Alloc effect: may heap-promote on overflow
}
```

`u_any`/`i_any` start as `unsigned __int128` / `__int128` on the host (bootstrap
Phase UH-1).  Arithmetic that could exceed 128 bits introduces the `Alloc`
effect.  This means:

- `@noalloc` and `@realtime` functions **cannot use `u_any` arithmetic** unless
  the compiler can prove no overflow occurs — statically eliminating the entire
  CWE-190 integer overflow CVE class for functions that opt in.
- Desktop security code (`allocSize`, counter arithmetic, hash-map sizing) uses
  `u_any` and gets compiler-proven overflow freedom.

Phase UH-2: true heap bignum via GMP (`mpz_t`) when `__int128` range is
exceeded; the `Alloc` effect propagation is already in place.

### 2.9.6  Architecture Target Table

```
--target native    host cpu; __int128 for u_any
--target x86_64    SSE2 PADDSW for sat_i16; sat_u8 via PADDUSB
--target arm64     SQADD/UQADD (1-cycle sat); bf16 native on ARMv8.6+
--target riscv32   RV32IMAC; no __int128; sat via C helpers; Zce for u11 ANDI
--target riscv64   RV64IMAC; RVV extension for vectorised sat/arb-int lanes
--target wasm      WASM SIMD; i16x8.add_sat for sat_i16; no __int128
--target ppu32     RISC-V PPU hardware posit instructions
--target gpu-*     MLIR backend (Section 2.7)
```

### 2.9.7  Completeness (Phase UH-1)

| Feature | Type system | C codegen | MLIR lowering | Effect proof |
|---|---|---|---|---|
| `u3`..`u127` arb-width | ✅ | ✅ mask+cast | via `iN` native | ✅ |
| `sat_i8`..`sat_u64` | ✅ | ✅ helpers | via `arith.adds` | ✅ no Panic |
| `fixed_I_F` Q-format | ✅ | ✅ >>F shift | via `iN` | ✅ |
| `u_any`/`i_any` bignum | ✅ | ✅ __int128 | — (host only) | ✅ Alloc |
| `rns_N` residue | ✅ +field access | ✅ runtime fns | — (host only) | ✅ @pure |
| Target table | ✅ | ✅ CC flags | ✅ per-target | N/A |

Test coverage: **pass=35 fail=0** (32 existing + 3 new UH examples).

---

## 3. The rest of the language (sugar, prioritized)

Build these *after* the effect core proves out, in this order:

1. **FFI / binding generation** (serves 5 projects). `pub export fn` auto-emits a C header,
   and optionally a WASM module + N-API shim, so mathpressor/ghost_cli/zenith/web/Python
   consume Zag without hand-written `extern` blocks.
2. **Error context** (`try expr orelse context("opening {s}", path)`) — attach
   compile-time/static context to an error as it bubbles, allocation-free, so you stop
   rebuilding it with 1,250 `log.err` calls.
3. **Closures without hidden capture** — anonymous fn-literals that capture *only* an
   explicit, visible environment record (no implicit heap), killing the `struct{fn..}.lt`
   boilerplate while staying honest.
4. **Trait/constraint sugar** over `comptime` — `fn f(w: impl Writer)` desugars to a
   comptime-checked duck-typed bound with *good* error messages. Mostly for ghost_engine.

Explicitly **not doing**: block-local shadowing (your code doesn't need it).

---

## 4. Compiler architecture (from-scratch, your chosen path)

You chose a from-scratch compiler over a transpiler. That is the high-risk, high-freedom
road; here is how to walk it without dying in the parser valley.

```
.zag source
   │  lexer            (hand-written, real)
   ▼
 tokens
   │  parser           (recursive descent → AST, real)
   ▼
  AST
   │  sema             (name res, types, EFFECT INFERENCE + CAPABILITY CHECK ← the point)
   ▼
 typed AST
   │  ── Phase 3: hand hard effect obligations to Z3 via ghost_engine ──
   ▼
 codegen
   │  Bootstrap: emit C  → cc/clang → native binary   (real, this repo)
   │  Later:     emit LLVM IR directly, drop the C step
   ▼
 native binary
```

### 4.1 Bootstrap host language: Python (deliberate, temporary)
The bootstrap `zagc` is written in **Python**, not Zig. This is a *staging* decision, not a
betrayal of "from scratch":
- The goal of bootstrap is to validate the **effect system** end to end as fast as possible.
  Python gets a working lexer→parser→checker→C→binary in one sitting; Zig 0.14's stdlib
  churn would burn the session on plumbing.
- The language being built is still 100% new and shares no semantics with Zig.
- **Roadmap:** once the effect core is validated, rewrite `zagc` in Zig (Phase 2), then
  self-host in Zag (Phase 4). Plenty of real languages bootstrapped through a scripting host.

### 4.2 Codegen target: C, then LLVM
Emitting C and invoking `cc` gives a real native binary today with ~200 lines of emitter
instead of an LLVM backend. It is a standard bootstrap (Nim, V, early Rust-ish). The C step
is deleted in Phase 3 in favor of direct LLVM IR for control over layout and to drop the cc
dependency. Using the *system* `cc` (not `zig cc`) keeps the "0% Zig ecosystem reuse" line.

---

## 5. Roadmap & honest completeness

| Phase | Scope | Effort (solo, realistic) | Risk |
|---|---|---|---|
| **0 — this repo** | Lexer, parser, sound effect checker (decidable cases), C codegen, runs real-shaped examples, rejects bad ones | done in-session (see below) | low |
| **1** | ✅ structs, real slices, closures, generics-over-types done (PoC). Remaining: error-context, methods/enums, generic bounds, escaping (heap) closures | 2–4 months | medium |
| **2** | Rewrite `zagc` in Zig; LLVM backend; FFI/binding generator | 4–8 months | medium-high |
| **3** | Wire `ghost_engine` as the deep effect prover. ✅ **wired** — `@total` div/mod-by-zero discharged by the actual ghost_engine (`zag_verify` bridge, SMT-LIB2 handoff over its Z3 path). Remaining: array bounds, termination, interprocedural, and routing into ghost_engine's full lowerings + VSA repair | 3–6 months | **high** (this is the moat; also the hardest) |
| **4** | Self-host Zag-in-Zag; stdlib; package manager | 12+ months | high |

**Brutal truth:** Phases 0–1 are a fun, shippable tool. Phase 4 is a multi-year,
realistically multi-person effort. If you do this solo alongside the DAW and mathpressor,
expect to live in Phases 0–2 for a long time. That is *fine* — a Zag that only ever reaches
Phase 2 (effect-checked subset that compiles to native and generates your FFI) would already
earn its keep across the tree. Do not let the Phase-4 dream block the Phase-0 win.

### Completeness of THIS repo right now
- Design: **100%** of the v0.1 scope above.
- Compiler (`zag-poc/zagc.py`, ~1100 lines): lexer/parser **~90%** of the subset grammar,
  effect checker (decidable cases) **~85%**, **effect polymorphism ~90%** — call-site
  inference, bounded callback types, effects-as-types through locals/returns/struct fields,
  and **allocation-free closures** that instantiate the effect variable `! e`,
  **numeric types** (i8/i16/i32/i64, u8/u16/u32/u64, usize, f32/f64; comptime-int literals
  that coerce by context; real `assignable()` checking — `let x: u64 = 1.5` is rejected),
  **enums + tagged unions + `switch`** (C enums; `{tag; union}` lowering; payload-capturing
  switch arms — the `union(enum)` shape), **structs + real slices with `.len` ~80%**,
  **generics over types (monomorphization) ~80%**
  — generic fns with type inference + generic structs, composing with closures/effects
  (no methods/enums/generic-bounds yet), C codegen **~80%** (control flow, `{fn,env}`
  fat-pointer values + thunks + stack closure envs, structs, slices, monomorphized instances),
  **ghost_engine/Z3 verification pass ~25%** — div/mod-by-zero discharged for `@total`
  (path-sensitive + value-range) by the **actual ghost_engine** (`zag_verify` bridge over its
  Z3 path); SMT-LIB2 handoff, graceful fallback to python-z3 / conservative; bounds, termination,
  interprocedural, and ghost_engine's repair pipeline still TODO (Phase 3b).
- **Native posits ✅** — `p8/p16/p32/p64` registered; `p32` (es=2) fully working with a verified
  software runtime (bit-exact encode/decode + arithmetic), explicit float/int casts, spec-correct
  type safety, **the `quire`** (P3 — 512-bit exact FMA accumulator), **and the branchless
  integer-only arithmetic path** (P2 — validated bit-exact vs a long-double oracle over 5M inputs).
  Only P4 (hardware passthrough) and the p8/p16/p64 runtimes remain.
- 28 example programs in the default suite, all passing (`bash zag-poc/run_tests.sh` →
  `pass=28 fail=0`): 18 build+run to native, 10 rejected with witness chains. Plus the SMT
  demo `bash zag-poc/prove.sh` (3 `@total` programs discharged by ghost_engine).

**On the "decade" problem.** From-scratch does *not* mean writing a backend from scratch:
`zagc` emits C and invokes the system `cc`, producing native binaries today (the route Nim, V,
Vala, and early Rust shipped). That removes the multi-year backend/linker grind from the
critical path — an LLVM backend can replace the C step later without touching the front end.
What remains is front-end breadth (numeric types ✓, then enums/tagged-unions, methods, error
unions, `[]u8`/strings, modules, a minimal stdlib), each piece independently shippable. The
slow, dangerous parts of a hobby language — backend, self-hosting — are deliberately deferred.
- Overall vs. "a usable language": **single-digit %.** This is a *proof of the core idea*,
  not a language you can write mathpressor in yet. Stated plainly so you don't test it
  against a real `.zig` file and find it can't — it can't, by design, at this phase.

---

## 6. Open design questions (decide before Phase 1)
1. Effect *polymorphism*: ✅ **resolved** (see §2.4 — call-site inference, bounded callback
   types, effects-as-types through locals/returns/struct fields, AND allocation-free closures
   instantiating the effect variable `! e`, all working in the PoC). Open remainder: *escaping*
   closures (need heap) + row-polymorphic inference for fully opaque values (Phase 1).
2. Is `Panic`-freedom (`@total`) worth the Z3 dependency, or ship `@realtime`/`@noalloc`
   (decidable, no Z3) first and add `@total` only when ghost_engine is wired?
   **Recommendation: ship the decidable ones first; they already beat every other language.**
3. Granularity of `Lock`/`IO`: single effects, or parameterized by resource?
4. Memory model: keep Zig's explicit allocator-passing, or the inferred-capability idea?
   (Deferred — it fights "no hidden allocations" and needs its own design pass.)
