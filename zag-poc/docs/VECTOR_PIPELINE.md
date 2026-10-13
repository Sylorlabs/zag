# The Vector Pipeline

Zag's vector story is five layers deep, and this document is the map. Each
layer owns exactly one decision, and none of them may guess at another's.

```
  source .zag
     │
     ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ vector IR          selfhost/zir_vector.zag                       │
  │   target-independent `vector.*` ops over `vector<ELEM,LANES>`     │
  │   verifier (11 fault classes) + DCE + MLIR printer + stats       │
  └──────────────────────────────────────────────────────────────────┘
     │  rewritten in place, only for loops whose equivalence is proven
     ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ auto-vectorizer   selfhost/vectorize.zag                         │
  │   loop analysis → induction-variable detection → alias/dependency │
  │   proof → vector main loop + untouched scalar epilogue           │
  └──────────────────────────────────────────────────────────────────┘
     │  machine ops carrying VIRTUAL vector registers
     ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ CPU-width lower   selfhost/native/vecwidth.zag                   │
  │   logical lanes → the target's widest register; splits when the   │
  │   CPU is narrower than the logical vector                         │
  └──────────────────────────────────────────────────────────────────┘
     │
     ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ vector regalloc   selfhost/native/vregalloc.zag                  │
  │   real backward liveness → live intervals → linear scan over a   │
  │   physical pool, with no spilling (it fails closed instead)      │
  └──────────────────────────────────────────────────────────────────┘
     │
     ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ machine encoders  native/x86.zag (VEX + EVEX) / native/aarch64.zag│
  │ ISA contracts    native/isa.zag / native/aisa.zag                │
  │ ladder + spellings  native/vector_contract.zag  ← single source  │
  └──────────────────────────────────────────────────────────────────┘
```

`selfhost/vector_contract.zag` is the shared vocabulary: the `vector<ELEM,LANES>`
spelling, the op-name set, the predicate set, the width-class ladder, the target
lane ceilings, and the cost model. Every other file imports it. That is why no
layer can quietly disagree with another about what a vector is.

## 1. Vector IR — the type and the op set

A vector value's type is the spelling `vector<elem,lanes>`, carried in the
existing `ZVal.ty` field. **Lane count is logical, not physical.** The IR never
mentions 256-bit, YMM, ZMM, or NEON; that is what makes the same module
meaningful on every target. A comparison result is `vector<i1,LANES>`.

Ops: `vector.splat`, `vector.broadcast`, `vector.extract`, `vector.insert`,
`vector.add`, `vector.sub`, `vector.mul`, `vector.bit_and`, `vector.bit_or`,
`vector.bit_xor`, `vector.shl`, `vector.shr`, `vector.icmp`, `vector.select`,
`vector.reduction_add`, `vector.shuffle`.

The verifier (`zvec_verify_op`, 11 fault classes) is the correctness gate. It
checks result/operand arity, operand shape agreement, element type packability,
lane index ranges, predicate/element agreement, select-mask width, shuffle mask
range and length, and that a *pure* op carries no memory effect. It is
**additive**: it returns 0 for every non-vector op, so adding it to the existing
def-before-use sweep cannot reject previously-valid IR. `vector.broadcast` is
deliberately *not* pure — it is the memory read.

`zvec_block_dce` removes dead pure vector ops to a fixpoint and never removes a
`vector.broadcast`.

## 2. The auto-vectorizer — why it is conservative

The recognized pattern is a **unit-stride accumulate**:

```zag
fn add_all(a: *i32, n: i32) i32 {
    let s: i32 = 0;
    let i: i32 = 0;
    while (i < n) { s = s + a[i]; i = i + 1; }
    return s;
}
```

Twelve reject codes gate it. The load-bearing ones are the alias rules:

* **ZR_ESCAPE (7)** — the accumulator's stack slot may appear only as an operand
  of `memref.load`/`memref.store`. Anything else (`zag.field`, `zag.cast`,
  `zag.slice`, `zag.index`, `func.call`) takes its *address*, so the value the
  vector loop writes could be observed by code expecting the scalar schedule.
* **ZR_BASEALIAS (8)** — the indexed base must be touched by exactly one
  unit-stride access, and no other op in the function may name it. Together with
  (7) that is the proof permitting a *wider* load: the `LANES`-element window is
  contiguous, inside one array, and overlaps no other access.

ZR_NOOP (5) refuses a **floating-point** accumulator outright. A lane-parallel
float carry plus a horizontal sum is not the scalar left-to-right sum, and the
accumulator is read after the loop, so the program would compute a different
number. Integer accumulation is accepted because wrapping integer addition is
associative — that is the whole reason the pattern is sound for `i32` and not
for `f32`.

### The transform, and why it needs no phi and no peeling

The pass inserts a **vector main loop** before the original loop and leaves the
original loop in place as the **epilogue**:

```mlir
%vl = arith.constant 4 : i32
scf.while { %i = memref.load %iv[]; %e = arith.addi %i, %vl; %f = arith.cmpi sle, %e, %n; scf.condition(%f) }
        do {
  %i2    = memref.load %iv[]
  %acc   = memref.load %acc[] {splat = "1"}
  %vacc  = vector.splat %acc     {lanes = "4", elem = "i32"} : vector<i32,4>
  %vptr  = vector.splat %a, %i2  {lanes = "4", elem = "i32", stride = "unit"} : vector<*i32,4>
  %vval  = vector.broadcast %vptr[] {lanes = "4"} : vector<i32,4>
  %vres  = vector.add %vacc, %vval : vector<i32,4>
  memref.store %vres, %acc[] {reduce = "add"}
  %i3    = arith.addi %i2, %vl
  memref.store %i3, %iv[]
  scf.yield }
scf.while { ...the ORIGINAL loop, byte for byte... }
```

Two properties make this sound and cheap:

1. **The induction variable lives in memory.** The vector loop advances
   `%iv_slot`; the epilogue then reads the advanced value. Sequencing is
   automatic, so there is no phi to construct and no peel/peel-remainder
   bookkeeping for an unknown trip count.
2. **The `sle` guard cannot overrun.** The main loop runs only while
   `i + LANES <= n`, so it covers exactly `[0, LANES*floor(n/LANES))`. Every
   index in that range gets the identical per-lane operation in the identical
   order, and the untouched scalar loop handles the tail.

The generated MLIR is checked by the same def-before-use verifier as everything
else; fresh `%v<N>` names continue past the maximum already used in the function.

## 3. CPU-width lowering — the ladder

Machine vector ops are width-parameteric: the width class is in `Instr.imm`
bits 0-1.

| target | width class | bytes | logical lanes |
|---|---|---|---|
| AVX-512 (`ZT_AVX512`) | `VW_512` | 64 | 16 |
| AVX2 (`ZT_AVX2`) | `VW_256` | 32 | 8 |
| SSE2 (`ZT_SSE2`) | `VW_128` | 16 | 4 |
| AArch64 NEON (`ZT_NEON`) | `VW_128` | 16 | 4 |

`vecwidth_lower` walks the instruction list and, when a logical vector is wider
than the target's ceiling, emits `zvec_reg_count(lanes, width)` independent
per-piece operations and mints a distinct virtual register per piece, so chunks
can never alias. When a consumer has no defined recombination it **fails
closed**: the instruction is left untouched and counted in `rejected`.

The AVX-512 rung is only reachable through a real gate.
`x86_gate_avx` requires CPUID.7.0:ECX bit 16 (AVX512F) **and** XCR0 bits 5,6,7
(opmask, ZMM_Hi256, Hi16_ZMM). A CPU with AVX512F on an OS that only saved
XMM/YMM state would `#UD` on the first EVEX instruction, so the ZMM half of the
state is a hard requirement.

## 4. Vector register allocation

`regalloc.zag` originally carried three dead helpers with the comment *"until
vector liveness is wired in"*. They are gone, replaced by a real model.

* **Liveness** is a genuine backward dataflow per function. An instruction kind
  the classifier does not name **clobbers every vector register** and empties
  the pool, so the function is refused. A missed case here is a silent
  miscompile, so the pass fails toward "clobbers everything".
* **Allocation** is linear scan over live intervals, taking the lowest free
  physical register and reusing one whose value is provably dead.
* **The pool is not a constant.** It starts above the highest vector register
  any other instruction in the function writes, so the scalar float lowering's
  XMM scratch and the existing YMM0/YMM1 intrinsic scratch are never stolen.
* **It never spills.** If a program needs more simultaneously-live vector
  registers than the target has, it returns the program unchanged with
  `spilled=1` and the caller refuses to emit. A wrong spill is worse than no
  vectorization.

## 5. Machine encoders

x86 gains a generalized VEX emitter (L=0/1/2), a full **EVEX** emitter for
512-bit (P0/P1/P2 with the correct inverted `R̄/X̄/B̄/R̄'`/`V̄'`, `L'L`, and a
zero `aaa`), scaled-index SIB forms for `[base + index*scale + disp]`, and
width-parameteric forms of every packed op. A combination with no valid encoding
emits **nothing** and records an error — never a partial or wrong encoding.

AArch64 gains a packed width/element descriptor in `AInstr.imm` so the
arrangement suffix is derived instead of hardcoded `.4S`, plus the 90-112 op
range (mul, shifts, FP, compares, `bsl`/`bit` select, `dup`, lane
extract/insert, `movi`/`mvn`, and `ld1`/`st1` for element-scaled addressing).
A64 spends the whole `size` field on "128-bit" for `LDR/STR Qt`, so only
`LSL #0` and `LSL #4` exist; an i32 stride uses the `LD1/ST1` form instead.

## Lanes are elements, and an element is a word

**`zvec_elem_stride` is not `zvec_elem_bytes`.** Native layout gives every
non-byte scalar a full 8-byte word (`cg_elem_stride` -> `cg_type_size`), so
`p[i]` over a `*i32` advances **eight** bytes even though only four carry the
value. Every fact about a vector load follows from that:

* the SIB scale is the element's **address stride** (8), not its width (4);
* a 128-bit register therefore holds **two** `*i32` elements, not four;
* the arithmetic is a **64-bit word add** — for `i32` the low 32 bits come out
  right mod 2^32 whatever the high half held, so `vpaddq` is right for `i32`,
  `i64` and pointers alike, and needs no masked or narrowing form.

The width ladder already counts 32-bit-equivalent units, and a stride-8 element
is exactly two of them, so **the ladder itself is unchanged**: 2 elements is
4 units, 4 elements is 8, 8 elements is 16. `zvec_32bit_units` is the only new
vocabulary, and `zvec_is_word_elem` is the gate.

Scaling by the element width instead is a mistake that decodes perfectly and
reads the wrong memory — it gathers four bytes-packed words, none of which are
adjacent array elements.

Floats are **refused** (a word add on float bits is not a float add, and there is
no vector FP add in the ISA) and so are `u8`/`i8`/`i16` (a word add carries
between elements). Both are refused with a reject code, never mis-encoded.

## The accumulator is LANE-WISE, and folded once

Lane *k* of the accumulator vector sums the elements whose index is congruent to
*k*, so the `L` lanes hold `L` **disjoint** partial sums, and a single
horizontal fold after the loop totals them. This is the classic
multiple-accumulator reduction and it is the whole performance argument: the loop
body is one load and one add per `L` elements, with no fold, no accumulator
round trip, and no sign normalization inside the loop.

The alternative — broadcasting a *scalar* accumulator into every lane and folding
each iteration — counts the running total once **per lane**, so the total comes
out `L*acc + sum(e)`. That is exact on the first iteration and wrong from the
second on, which is why a one-iteration trip count still agrees and hides it.

Carrying the vector across the back edge needs no phi and no block argument: the
accumulator is a **vector-typed slot**, `memref<vector<ELEM,N>>`, which the loop
body reads and writes. `memref.alloca` allocates zeroed, so the slot needs no
initialisation store. It is also the *one* vector result that really does get
frame space, and it must be sized at the **full register width**: reserving one
word for a 16-byte slot puts the next value inside it, and the loop's step
constant then reads as zero and the loop never terminates.

## End to end: vector IR to encoded machine code

For a small enough function the whole chain runs. `tests/vectorize_machine.zag`
is the fixture; the shape for a 2-lane `i32` accumulate at the generic x86-64
baseline is:

```
%vacc = memref.alloca() {elem="vector<i32,2>"} : memref<vector<i32,2>>
  ... in the body ...
%p = memref.load  %vacc[] {elem="vector<i32,2>"} : vector<i32,2>
%a = vector.splat %a, %i   {elem="i32", lanes="2", stride="unit"} : vector<*i32,2>
%d = vector.broadcast %a   {elem="i32", lanes="2"} : vector<i32,2>
%s = vector.add %p, %d : vector<i32,2>
memref.store %s, %vacc[] {elem="vector<i32,2>"}     # NOT a reduce: not a fold
  ... after the loop ...
%f = memref.load %f, %vacc[] {elem="vector<i32,2>"} : vector<i32,2>
memref.store %f, %acc[] {elem="i32", reduce="add"}  # the ONE fold
```

```asm
vpxor       %xmm15, %xmm15, %xmm15      # the slot starts zeroed
vmovdqu     %xmm15, -72(%rbp)
loop:                                    # ── vector main loop ──
  vmovdqu   -72(%rbp), %xmm0             #   the carried partial sums
  vmovdqu   (%rcx,%rdx,8), %xmm1         #   the window: base + index*8
  vpaddq    %xmm1, %xmm0, %xmm2          #   two word additions at once
  vmovdqu   %xmm2, -72(%rbp)             #   back to the slot
  ...
  jmp        loop
vmovdqu     -72(%rbp), %xmm0             # ── the single fold, AFTER the loop ──
vpshufd     $78, %xmm0, %xmm15           #   [2,3,0,1] swaps the word pair
vpaddq      %xmm0, %xmm15, %xmm15
vpextrq     $0, %xmm15, %rcx             #   one extraction per 128-bit chunk
```

`vpshufd $0x4E` is what makes the fold cheap: it permutes 32-bit lanes, but
`[2,3,0,1]` **within each 128-bit chunk** swaps the two 64-bit halves. One
existing shuffle opcode halves a word pair, so the fold is one shuffle, one add
and one extraction per chunk — 1/2/4 extractions at 128/256/512 bits. No second
shuffle family is needed.

A store of a vector into a **vector** slot and a store of a vector into a
**scalar** slot are different instructions with different meanings, and the
admission rules tell them apart by the destination. Writing a vector to a scalar
slot is the horizontal fold, and doing that per iteration is exactly the bug
above.

### Measured

A 2-lane `i32` sum at the generic x86-64 baseline (SSE2) — 3000 repetitions of a
30000-element accumulate, x86-64 under emulation:

| build | time |
|---|---|
| `--vectorize=off` | 4.6 – 4.8 s |
| `--vectorize=on`  | 2.7 – 2.8 s |

**≈1.7×**, reproducible across runs. Two lanes is the *worst* case for the width
ladder: the wider targets carry 4 and 8 elements per iteration and amortise the
same per-iteration overhead over more work.

One cost is visible in the numbers and is not an oversight. The `*i32` element
is a whole 8-byte word, so the same 30000 elements move twice the bytes they
would in a packed layout; that ceiling is the language's memory model, not this
pass. A packing change would double the lane count at every width, and is a
language-semantics decision rather than a vector-pipeline one.

### Runtime proof

`tests/run_vector_equiv_x86_64.sh` builds `tests/vectorize_equiv.zag` twice for
x86-64 and **runs both** under an amd64 emulator. Each build compares its own
vectorized sum against its own scalar reference over the same memory, across 18
trip counts chosen at the boundaries that matter (below one vector, exactly one,
one plus a tail, exact multiples, multiples plus a tail).

This is the only check in the suite that proves the emitted code *computes*
anything, and it is the check that found the bugs under **Fixed**. It also
asserts the fixture really was vectorized, because a silent fall back to the
scalar path would make every exit code 0 and prove nothing. It skips, rather than
fails, where no amd64 emulator is available.

A fixture that has fallen back is silent, and the fallback names its reason: a
`refusal=<op>` on the `lowering=` line says which op the ZIR-direct route would
not admit. This is worth reading before trusting any performance number — a
single `&` in the program's `main` puts the whole module outside the direct
subset, and every vector instruction in the binary silently disappears while the
vectorizer still reports success.

### The size bound, and why it exists

This only works for functions small enough for the **ZIR-direct** route, because
that route resolves every SSA name through `zir_native_disp`, a linear scan of the
function's slot table. Its cost is O(words²). `ZIR_NATIVE_MAX_WORDS` in
`ncodegen.zag` bounds the route by the module's total slot words; a larger module
falls back to the AST bridge exactly as it did before. Widening the route to
arbitrary programs needs a real slot map first, not a bigger constant.

A second, related limit: a vector value that is live across a `call` is refused,
because every vector register is caller-saved. There is no vector callee-saved
convention in this ABI yet.

## What is still not done

* **The accumulator still round-trips through the stack every iteration.** The
  lane-wise form is right — disjoint partial sums, one fold after the loop — but
  the partial sums live in a frame slot, so each iteration stores and reloads
  them, putting store-to-load forwarding on the accumulator's dependency chain.
  The fold is already hoisted out; only the carrier needs to change.

  The obvious next step — make the slot *register-resident*, so no store and no
  reload at all, leaving one load and one `vpaddq` per `L` elements — was built
  and reverted. The emitted sequence was right (`vpxor` to zero, `vmovdqu` load,
  `vpaddq`, a rename-eliminated `vpxor` move, and the fold reading the register
  directly), and it disassembled cleanly, and it still computed the wrong answer.
  The one part that is not obviously sound is that it needs the *vector register
  allocator* to keep one register live across the loop's back edge, which is a
  block-structured liveness question the current linear backward pass does not
  answer; building the lowering on an assumption about it, rather than proving
  it, is what produced the wrong result. Do it as a change to `vregalloc` with a
  test that fails without loop-carried intervals, not as an emitter shortcut.
* **Only `vector.add` reductions are modelled.** `vector.mul` and the bitwise
  ops lower, but no reduction other than `add` is accepted, and a loop whose
  elementwise op is a multiply is refused rather than vectorized-then-reduced.
* **AArch64 does not consume ZIR.** The arm64 backend lowers the AST directly, so
  it never sees the vector IR. Its NEON encoders are verified against `as` but
  are not yet reached by this pass.
* **No AVX-512 compare-to-lane-mask path**: at 512 bits the EVEX forms of the
  compare opcodes write a *k* register, and no instruction widens a k mask into a
  lane mask, so those kinds are rejected at `VW_512`.
* `K_VSHUF32`/`K_VSHUFB` are per-128-bit-lane; a general cross-lane
  `vector.shuffle` at 256/512 bits needs VPERMI2/VPERMT2.
* The ZIR-direct route still does not lower a function whose *other* functions
  need the AST bridge, so a vectorizable loop inside a program that allocates
  memory is verified but not lowered. One `&` in `main` is enough to lose the
  whole module's direct lowering, and the vectorizer's own report still says
  "vectorized" — the `refusal=` field on the lowering line is what catches it.

Auto-vectorization is **off by default** and must be requested with
`--vectorize=on`. The CPU profile alone decides the width; the request only
decides whether the pass runs. The choice is part of the foreground cache key,
so a vectorized build can never be served a non-vectorized artifact.

## Width rungs and measured scaling

`x86-64-v2`, `v3`, and `v4` DECLARE a microarchitecture level rather than
detecting one, so the wider rungs build anywhere (see `X86_FEATURES.md` for why
that distinction is safe). Each selects a rung through `znc_vectorize_target`:

| Profile | Rung | Register | Lanes | `vectorize=` view |
| --- | --- | --- | --- | --- |
| `x86-64-v1` | `sse2` | `xmm` | 2 | `target=sse2 lanes=2` |
| `x86-64-v2` | `sse2` | `xmm` | 2 | `target=sse2 lanes=2` |
| `x86-64-v3` | `avx2` | `ymm` | 4 | `target=avx2 lanes=4` |
| `x86-64-v4` | `avx512` | `zmm` | 8 | `target=avx512 lanes=8` |

`v2` adds SSE4.2 and POPCNT but no vector width, so it shares `v1`'s rung.

Measured on the 90M-element reduction (`vec_sum`, 3000 x 30000 `*i32`),
best of two runs, executing the Linux x86-64 binary under amd64 emulation:

| Profile | Lanes | Scalar | Vectorized | Speedup |
| --- | --- | --- | --- | --- |
| `x86-64-v1` | 2 | 3.03 s | 1.28 s | 2.37x |
| `x86-64-v2` | 2 | 3.06 s | 1.28 s | 2.39x |
| `x86-64-v3` | 4 | 3.08 s | 0.73 s | 4.22x |
| `x86-64-v4` | 8 | — | — | not executable on this host |

The ratio roughly tracks lane count, which is the point: it is evidence that the
lane-wise accumulator is not silently collapsing to fewer lanes at width, not
just that the loop got shorter. Absolute times are inflated by emulation; the
scalars are unaffected because both builds run on the same emulator.

### The emulator ceiling

The amd64 emulator available on the Apple-Silicon test host implements **SSE2
only**. AVX2 and AVX-512 both raise `SIGILL`, which is why the `v4` row has no
time. This was established with standalone probes rather than assumed: a
hand-written SSE2 program exits 0 under the same harness, while AVX2 and AVX-512
probes exit 132 (`128 + SIGILL`). `QEMU_CPU=Haswell|Skylake-Server|Icelake-Server|max`
does not change it.

`tests/run_vector_equiv_x86_64.sh` therefore treats `#UD` as **BUILD-ONLY**, not
as a failure: the build is proven correct and the host simply lacks the ISA. A
machine without AVX-512 must not be able to turn a correct AVX-512 build red.
For the same reason the `vectorize=off` control at `v4` still runs — it needs no
AVX-512 — and passing there is what separates "the profile is broken" from "the
CPU lacks the instructions". On real AVX-512 hardware the same script measures
the rung with no change.

Two earlier probe results during this investigation were harness bugs, not
emulator limits, and are worth recording because the failure signature
(`SIGSEGV`) is indistinguishable from a missing ISA at a glance: a probe that
dereferenced an uninitialized `%rsi`, and an ELF wrapper whose entry point
mapped to the ELF header rather than past it. The SSE2 control is what caught
both.
