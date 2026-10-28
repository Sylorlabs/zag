# Zag and ZagScript: sibling language contract and execution roadmap

Zag and ZagScript are two user-facing languages in one ecosystem. Zag favors
explicit control, predictable costs, and systems programming. ZagScript favors
inference, concise syntax, managed defaults, and a fast path from prototype to
production. They deliberately share the parser/typed frontend, ABI and core
value semantics, optimization pipeline, native backends, libraries, and tooling.
Distinct language identities do **not** require two independent compilers.

## Migration contract

1. A ZagScript source uses the `script;` profile, the `znc script` command,
   or `.zs`. Strict Zag requires explicit types, entry points, effects, and
   resource policy where the selected edition requires them.
2. `znc expand source.zag --to explicit --output derived.zag` writes a separate
   inspectable strict-Zag candidate. The original source stays unchanged.
   Unsupported lowering must diagnose precisely instead of emitting a guessed
   conversion. `unexpand` is reserved and currently unavailable.
3. Migration tests must compare **stdout, stderr, process status, and intended
   program result**; comparing two equally wrong executables is insufficient.
   Bound the runtime so a common infinite loop fails the test.
4. Normalization must preserve updates to previously declared values across
   loops and inferred function definitions. An explicit `let name` and a
   Script-inferred initial assignment register the same binding for subsequent
   assignment lowering; a loop-body assignment must not shadow that binding.
5. Runtime policy, allocations, library calls, and implicit operations must
   become explicit and reviewable at the supported conversion boundary.

## Measured implementation gates

| Gate | Zag | ZagScript | Shared evidence |
| --- | --- | --- | --- |
| Meaning | Strict edition semantics, typed operations, ownership/effects | Inferred declarations, bounded defaults, defined conversion | Positive expected-output fixtures; differential and negative tests |
| Performance | Compare optimized native binaries against C and Rust | Compare Script binaries and expanded Zag; track runtime overhead | Same algorithm/input, correctness checks, warmups, alternating process-level medians, raw artifacts |
| Compiler | Prove local transformations with explicit preconditions | Reuse the same optimizer, preserve all Script lowering invariants | Z3/QF_BV for bounded cases, fuzz and native regression suites |
| Release | Memory safety, concurrency, ABI, platform, optimizer gates | Migration and Script policy gates in addition to shared gates | Green CI on supported hosts; no claim of universal superiority |

## Ordered engineering work

1. **Correctness and migration.** Fix explicit-declaration shadowing in Script
   loops, keep root bindings across functions, add bounded execution and exact
   expected-result assertions. Run both native and strict-expanded outputs.
2. **Measure gaps rather than assuming them.** Use the performance parity audit
   for a fixed benchmark corpus and environment; compare compiler revisions
   with the *same source revision* and identical flags and inputs. Do not infer
   causation from comparisons between different compiler branches.
3. **Cut redundant work.** Profile AArch64 loop-region stack slots, `x28`
   traffic, helper calls, and spills; prioritize register/value promotion and
   bounded, correctness-preserving inlining over benchmark-specialized rewrites.
   Preserve observable memory behavior and aliasing rules.
4. **Prove scoped transformations.** Encode integer overflow, shifts,
   signedness, register transfers, branch flags, and memory visibility as
   explicit proof obligations. Bounded bit-vector proofs require surrounding
   liveness/aliasing and memory-effect evidence before claiming whole-program
   equivalence.
5. **Iterate on competitive evidence.** Report per-workload ratios against
   Clang-optimized C and optimized Rust, binary sizes, peak memory, compiler
   wall time, variance, and regressions. Gate release separately for each
   language. Sharing one backend should make ZagScript convergence possible,
   but does not guarantee C/Rust parity on every workload.

The executable sibling boundary is `tests/run_zag_zagscript_separation.sh`.
The AST and compact-source boundary are covered by
`tests/run_script_cst.sh` and `tests/run_script_inference.sh`.

## Shared backend optimization, separately enforced language behavior

The ARM64 backend now uses the same exact unsigned power-of-two remainder
identity in both sibling compiler branches: `x % 2^k` becomes
`x & (2^k - 1)` for an explicitly unsigned left operand and a bare,
positive decimal divisor of at most 18 digits. The signed, dynamic,
non-power-of-two, oversized, and other unsupported literal forms retain their
original checks and lowerings. ZagScript also keeps its existing verified
high-half reciprocal division path for other bounded constant divisors.

The shared `tests/run_pow2_remainder_proof.sh` was executed using Z3:
seven QF_BV equality counterexample searches returned `unsat`, and an
intentional signed counterexample returned `sat`. The ZagScript final
compiler `/tmp/zag-script-pow2-final-znc-20261027` passed **321** exact
constant-remainder output cases and the Script/expanded Zag executable
migration parity gate. This proof is mandatory in the Linux Script release
preflight, while Zag v2 executes it in its opt-in QF_BV workflow.

A focused 10-million-iteration unsigned modulo-256 process-inclusive test
ran 30 alternating rounds after three warmups on Apple Silicon. The earlier
ZagScript compiler artifact produced a 35.256 ms median and the rebuilt
compiler a 18.804 ms median (0.533x), with exact checksum checks. The
comparison source and compiler hashes and raw timings are archived locally
at `/tmp/zag-pow2-benchmark-20261027.json`. The baseline artifacts were
not independently rebuilt as a strict one-change comparison, so this is
screening evidence for a single kernel, not a quantified pass-only speedup
or proof of general language parity.

## Benchmarking the migration boundary

The cross-language benchmark has an opt-in `COMPARE_EXPLICIT=1` profile that
compiles each benchmark's Script source through the ordinary Script frontend
and independently generates strict Zag using `znc expand --to explicit`. The
expanded source is then compiled using the **same** compiler, flags, workload,
and checksum oracle as the original. Both variants run in each alternating
measurement round alongside C, Rust, and Python. Run it with:

```sh
COMPARE_EXPLICIT=1 RETAIN_ARTIFACTS=1 RUNS=30 ITERATIONS=2000000 \
  ZNC=/path/to/host-native/znc python3 benchmarks/run_cross_language.py
```

The result metadata retains compiler hashes, separately hashed Script and
generated strict-Zag sources, native executable hashes, raw process-inclusive
times, and the independent expected stdout. The runner rejects an expansion
that leaves a Script directive and verifies each archived source hash against
the exact source compiled. A near-one runtime ratio on this limited benchmark
is evidence that the migration does not introduce a performance cliff **for
these workloads**; it does not certify equivalence of runtime policy,
allocation cost, diagnostics, or every language feature. The semantic release
gate remains `tests/run_zag_zagscript_separation.sh`, including nested loop
and conditional updates with independently specified output and exit status.
