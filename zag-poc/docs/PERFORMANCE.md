# Compiler performance

An offline Z3 search for native-width pure integer expressions is documented in
[ZagScript bit-vector superoptimization](ZAGSCRIPT_BV_SUPEROPT.md). It verifies
rewrite semantics; its node-count results are not machine speed measurements.

Measured on an Apple-Silicon host with `znc` compiling `selfhost/native/znc.zag`
(4.26 MB import closure, ~4150 top-level functions). Unless stated otherwise,
numbers are `--target macos-arm64 --no-analyze --no-zagd --no-foreground-cache`.

## Baseline and current state

| | wall | output |
| --- | --- | --- |
| before the byte-at-a-time removal | 294.8 s | byte-identical to current |
| after Mach-O/SHA-256 bulk copy | 248.1 s | — |
| after the arity index | 247.6 s | byte-identical to current |

`bootstrap.sh` runs three such stages plus `zagd`, so a full bootstrap is about
three times this figure.

## What actually mattered

**Output-size-proportional work dominated, and it was almost entirely
unnecessary.** The Mach-O writers appended with `push[u8]`, which is an
out-of-line call plus a capacity test and a length bump *per byte*, and
`macho_sha256` assembled its padded message block the same way. Two helpers
(`sh_constants`, and a 64-entry message schedule) were re-allocated per 64-byte
block — about 236,000 allocations and 30M `push` calls for a 15 MB image.

Cost scales with emitted image size, so the effect is easy to see in isolation.
Same source, same text section, only the data segment grows:

| data segment | before | after | speedup |
| --- | --- | --- | --- |
| 256 KB | 1.58 s | 0.26 s | 6.08x |
| 1 MB | 4.70 s | 0.94 s | 5.00x |
| 4 MB | 17.51 s | 3.72 s | 4.71x |

Every one of these outputs is byte-identical before and after.

**A 32-bit rotate was built from a divide.** `sh_ror` in `macho_arm64.zag` was
`(x / 2^n) + (x % 2^n) * 2^(32-n)` — two loops totalling 32 iterations plus a
64-bit divide and remainder, 181 ns per call. SHA-256 calls it 384 times per 64
bytes. It is now `(x >> n) | (x << (32 - n))`.

## Measured negative results

These are recorded because they cost time to establish and should not be
re-attempted on the strength of a plausible-sounding estimate.

- **The arity index was neutral, then broke the compiler. REJECTED.** Replacing
  the per-call-site rescan of the whole declaration list with a name→arity hash
  map changed the self-compile by 0.1 s (247.7 s → 247.6 s) — inside noise. A
  first measurement suggested 6.9 s, but that machine was running nine orphaned
  `zagd` daemons. The rescan is evidently short-circuited by `znc_arity_exempt`
  for nearly every callee, so the asymptotic argument does not apply to real
  inputs.

  It was then reverted, because it made the compiler **segfault** on
  `--safety=checked` programs. The index was the first thing to import
  `selfhost/std/hashmap.zag`, a module nothing in the repository had ever
  compiled, so adopting it meant being the first user of never-exercised code.
  The revert is byte-identical to the pre-attempt binary.

  Two lessons, both cheap the second time: dead code is not free to adopt, and a
  complexity argument is not a measurement.
- **Compile time does grow superlinearly in declaration count**, but not for the
  reason first assumed. Synthetic single-file programs of K trivial functions
  show the doubling ratio climbing 1.95 → 2.78 from K=100 to K=3200, so the
  quadratic term is real. It is *per declaration*, not per AST node: holding K
  fixed and varying statements per body gives a strictly linear 0.88–0.95 ms per
  statement, while struct-only declarations are nearly free. The arity index
  targets per-call-site cost and therefore did not touch this term.
- **`--vectorize=on` is a no-op for `--target macos-arm64`.** The flag parses, but
  `znc_apply_vectorize` is called from the x86 build path only, and
  `znc_machine_vector_stage` consumes the x86 `ArrayList[Instr]`. Turning it on
  is not an available speedup on this target.
- **The optimization passes do not run on the macOS path.** `regalloc`,
  `optimize`, `peephole` and the vector stage are invoked only from the x86
  build. `optimize.zag` exists specifically to delete the stack-machine
  push/pop traffic that `ncodegen.zag` emits, and the emitted AArch64 code is
  still a stack machine: 42.3% of its instructions are memory operations, and the
  hottest single pattern in a profile is `sub x28,x28,#8 / ldr x0,[x28] / str
  x0,[x28] / add x28,x28,#8` — a pop followed by pushing the identical value.
  Porting `optimize.zag` to `AInstr` is the largest remaining lever on
  *generated* code quality; it is a port, not an optimization pass.

## Generated code

Whole-binary analysis of the emitted `__text` (3,641,968 instructions):

| metric | value |
| --- | --- |
| memory operations (`ldr`/`str`/`ldur`/`stur`) | 42.3% |
| instructions naming the operand-stack pointer `x28` | 21.8% |
| `ldp` / `stp` (register pairs) | 0 / 0 |
| `csel` / `cset` (conditional moves) | 0 / 0 |
| `madd` / `msub` (fused multiply-add) | 0 / 0 |


## The AArch64 backend was an unoptimized stack machine

`acodegen.zag` emits `ArrayList[AInstr]`, a flat list that encodes a stack
machine: expression temporaries are shuttled through a stack region via
`AK_PUSH`/`AK_POP` around `x28`. The x86-64 backend has had `optimize.zag` for
some time, but it operates on the x86 `Instr` type and was never run on the
macOS path.

Whole-binary analysis of the emitted `__text` before the port (3,641,968
instructions):

| metric | value |
| --- | --- |
| memory operations (`ldr`/`str`/`ldur`/`stur`) | 42.3% |
| instructions naming the operand-stack pointer `x28` | 21.8% |
| `ldp` / `stp` (register pairs) | 0 / 0 |

The single hottest pattern in a sampled profile was a four-instruction no-op:
`sub x28,x28,#8 / ldr x0,[x28] / str x0,[x28] / add x28,x28,#8` — a pop followed
by pushing the identical value straight back.

### What the port does

`selfhost/native/aoptimize.zag` is the AArch64 counterpart, run by
`znc_macos_lower_code` between `aload_program_macos_mode` and the encoder:

1. **Constant-stack elimination.** A push of a register holding a known constant
   is deleted and its matching pop becomes a `mov` of that constant, provided the
   pop is in the same breaker-free run and the gap touches `x28` only through
   balanced push/pop. An unknown value is never juggled through a scratch
   register.
2. **Constant folding**, including the immediate forms, gated on flag liveness.
3. **DCE** of dead `mov`s, backward and run-scoped.

### Results

| metric | result |
| --- | --- |
| emitted `__text` | 9–10% smaller (`sort_bench` 19688 → 17708 B) |
| compute-bound loop runtime | **1.36x faster** (0.38 s → 0.28 s) |
| `programs/*` behavior | 8/8 byte-identical stdout and exit codes |
| unit suite | `make test-aarch64-optimizer` |

Note the size metric is a poor proxy for the work done: the pass deletes stack
traffic and substitutes a `mov` of similar width, so code size barely moves while
the instruction mix improves. The gate therefore asserts the emitted image
*differs* from the unoptimized baseline rather than that it shrank.

### Where the x86 assumptions did not carry over

- **The stack pointer is `x28`, and acodegen also writes it outside push/pop.**
- **One register file.** `v0` is `x0`, so every float and vector kind clobbers the
  GPR it names. The x86 rule "an SSE write invalidates no GPR" is wrong here.
- **Immediates are imm12, not imm32.** `AK_ADD_IMM`/`AK_SUB_IMM` encode unsigned
  0–4095, and a negative immediate is not encodable at all.
- **`AK_AND_IMM` and a wide `AK_CMP_IMM` clobber `x9`/`x10`** as scratch.
- **`AK_MUL_RR`/`AK_SDIV` carry a third GPR in `imm`**, not `src`.
- **Flags cross label boundaries.** Control reaches a label by fall-through
  carrying the previous run's flags, so a label is treated as a breaker and the
  pass is more pessimistic than the x86 version in three places.

### The bug that mattered

The first version of the port marked only the destination live for the
read-modify-write forms. But `add x0, x1` encodes as `add xd, xd, xm` — dst is
destination *and* first source, and `src` is a real second source. The source
register therefore looked dead, a rematerialized `mov x1, 5000` in front of the
add was deleted, and the add read an unwritten `x1`.

It type-checked, assembled, and ran. `b = b + 5000` evaluated to `b`, and
`programs/sort_bench.zag` sorted incorrectly with no crash and no diagnostic.

Two things are worth recording about how it was caught:

- It was found by an agent **reviewing the wiring**, not by the agent that wrote
  the pass, and not by the pass's own structural tests. Parallel independent
  review earned its keep.
- The obvious regression test did **not** have teeth: a short instruction
  sequence never gave DCE room to fire, so the test passed with the bug present.
  The test that works asserts the liveness predicate directly. Two of my own
  assertions were also wrong before the test meant anything — an inverted
  comparison, and an expectation that a legitimately-dead fold would survive.

The liveness model now splits the two families, because they are not the same
shape: the eight `_RR` forms read `src`, the three `_IMM` forms read `dst` only.
Marking `src` for the immediate forms would be the mirror-image error — it would
keep dead definitions alive and silently undo the optimization everywhere.

## Methodology notes

- **Check the output exists.** A first pass at these measurements reported a 10x
  *slowdown* that was really a compiler crashing immediately; the timing harness
  had swallowed the failure into `/usr/bin/time`. Exit status and the presence of
  the artifact are part of the measurement.
- **Reap stray daemons first.** `zagd` processes left behind by earlier test runs
  kept the machine at load 4–6 and turned a 6.9 s effect into 0.1 s. A sweep now
  reaps them around each target.
- **Interleave A/B runs.** Comparing two binaries in sequence is not enough when
  machine load drifts; the reported numbers alternate the binaries.
