# Zag v2 + ZagScript v1: Full-stack performance audit and parity program
**Audit snapshot:** 2026-10-27 (America/Los_Angeles)

**Zag v2 worktree:** `codex/v2-qualification-followup-20261026`, commit `a81c82a`

**ZagScript v1 worktree:** `codex/zagscript-linux-native-followup-20261026`, commit `aa0d2be`

**Status:** Engineering audit and proposed work program. Experimental proof checks and current microbenchmarks have been run; this is not evidence of broad C/Rust parity or a v2 release.

## Executive decision

The compiler has genuine self-hosting, executable native code, architecture-specific optimization passes, verified Zag IR construction, a limited vector path, and growing formal transformation checks. But competitive general-purpose optimized code needs a much stronger **production** loop/SSA optimization and machine-code pipeline, especially on AArch64. The highest-return immediate project is to close measured instruction-level gaps in representative kernels, while building and validating a complete typed/owned IR optimizer that both Zag and ZagScript use.

Owning the parser, language, IR, code generators, runtimes, and libraries is valuable because it permits whole-program optimization and explicit effect/ownership information across layers. It does not automatically confer performance superiority. C and Rust benefit from mature compiler backends, tuned standard libraries, decades of correctness testing, and ISA-specific lowering. A universal claim of beating *every* C/Rust program in speed, memory, safety, compile time, binary size, and portability is not technically falsifiable as a finite milestone; use per-target, per-workload Pareto comparisons with explicit tradeoffs.

## 1. Measurement evidence and limits

**Fresh measurement:** Apple M5 arm64, source `aa0d2be`, separately built host-native `znc` binary SHA-256 `e7d3f5bf9034dbc3a28643e4cf34c9eb795c1c6f15e3fa3f455a5bc3f0c95e09`, `RUNS=30 ITERATIONS=2000000`; exact results archived at `/private/tmp/zag-audit-20261027/20261028T011736.222386Z.cross-language.{raw.csv,summary.csv,meta.json}`. This binary's compiler-to-source provenance is recorded separately: it resides outside the Script worktree and is not itself proof of a compiler built from that exact commit.

| Kernel | ZagScript | Clang C | Rust | Python | ZagScript / C | ZagScript / Rust |
|---|---:|---:|---:|---:|---:|---:|
| Integer recurrence | 19.911 ms | 12.422 ms | 11.332 ms | 237.759 ms | 1.603× | 1.757× |
| Four-way branch | 22.164 ms | 11.428 ms | 12.485 ms | 357.576 ms | 1.939× | 1.775× |
| Helper calls | 23.858 ms | 9.817 ms | 11.200 ms | 322.610 ms | 2.430× | 2.130× |
| **Geometric-mean slowdown, 3 kernels** | — | — | — | — | **1.962×** | **1.880×** |

Method: each of 30 rounds rotates language and kernel order; three per-variant warmups; exact stdout, empty stderr, and exit zero verified against independent reference computation. Timings include process launch, initialization, computation, and output capture; compilation is excluded. The Python result validates a major performance advantage on these kernels only. C uses Apple Clang `-O2 -std=c11`; Rust uses `-C opt-level=2 -C target-cpu=generic`. Optimization and CPU-feature equivalence need stronger control before publishing marketing performance claims. The first run did not retain its temporary binaries; the replication below retained and inspected its exact timed binaries with checksums.

**Approximate uncertainty:** deterministic paired-round bootstrap resampling (3,000 resamples, seed 20261027) of median runtime ratios gives 95% percentile intervals for ZagScript/C: recurrence 1.433–1.759, branch 1.767–2.055, call 2.348–2.597. These are descriptive resampling intervals, not a formal guarantee under host load drift; rerun on dedicated machines for release gates.

### Retained-binary replication and direct AArch64 evidence

A second, independent `RUNS=30 ITERATIONS=2000000 RETAIN_ARTIFACTS=1` pass completed with the same compiler and source revisions. All variants again produced exactly the oracle's stdout, zero stderr and exit status zero. The files and checksums are retained under `/private/tmp/zag-audit-retained-20261027/20261028T013032.049873Z.cross-language.artifacts/`, with raw CSV, summary and metadata next to that directory. Median process-inclusive results:

| Kernel | ZagScript | C | Rust | Python | Script / C | Script / Rust |
|---|---:|---:|---:|---:|---:|---:|
| Recurrence | 17.260 ms | 11.086 ms | 11.124 ms | 218.461 ms | 1.557× | 1.552× |
| Branch | 21.538 ms | 11.275 ms | 11.283 ms | 367.321 ms | 1.910× | 1.909× |
| Calls | 22.438 ms | 9.549 ms | 11.277 ms | 301.027 ms | 2.350× | 1.990× |
| **Three-kernel geometric mean** | — | — | — | — | **1.912× slower** | **1.806× slower** |

The exact timed Mach-O binaries were inspected with `/usr/bin/otool -tvV`. Each loop below is defined as the static instruction span from the outer-loop backward branch's destination through that branch, **not** as an execution-weighted or hardware-counter measurement. Memory counts include `ldr/ldur/str/stur/ldp/stp` within this span; `x28` is the Zag compiler's explicit expression-stack register. Static span counts include conditionally skipped instructions, especially in the branch kernel.

| Kernel | ZagScript span (instructions / memory operations / x28 mentions / calls) | Clang span (instructions / memory operations / calls) | Immediate conclusion |
|---|---|---|---|
| Recurrence | **85 / 20 / 27 / 0** (`0x100001914..0x100001a64`) | **14 / 0 / 0** (`0x1000004a4..0x1000004d8`) | Values repeatedly round-trip through the expression stack and frame. |
| Branch | **308 / 64 / 96 / 0** (`0x100001914..0x100001de0`) | **18 / 1 / 0** (`0x1000004fc..0x100000540`) | Duplicated `% 4` lowering, branch comparisons, stack shuffles and constant materialization dominate the *static* span. |
| Calls | **35 / 14 / 14 / 2** (`0x100001ad4..0x100001b5c`) | **15 / 0 / 0** (`0x10000049c..0x1000004d4`) | Two helper `bl` calls remain inside ZagScript's hot loop; Clang inlines equivalent helpers. The 35-instruction ZagScript loop excludes both callee bodies. |

**Updated root-cause ranking:** (1) scalar stack-to-register promotion / expression-stack elimination across loop bodies; (2) CFG-aware reuse and value range / constant specialization for repeated signed `%` and branches; (3) bounded, effect-safe inlining of small leaf functions. The current `aoptimize.zag` pass is local; a production cross-block def-use model and an inliner are needed to close these gaps broadly. This direct machine-code evidence supersedes the former purely historical suspicion of stack traffic, although the contribution of each factor to elapsed cycles still requires dedicated sampling and counters. Rust's broader runtime machine code was not similarly attributed; its timing is empirical but its generated loop's instruction count is **not audited** here. The binary sizes in this specific build were ZagScript 99,200 bytes, Clang C about 33,400 bytes, and Rust about 431,700 bytes; runtime/linkage differences make this insufficient for a general binary-size ranking.

**Historical compile-time profile** in `docs/PERFORMANCE.md`: on a 4.26 MB import closure (~4,150 functions), one macOS ARM64 `znc` build stage improved from 294.8 s to ~248 s after Mach-O bulk-copy/rotate fixes. A synthetic declaration-count experiment found superlinear compile-time scaling, while body statement count scaled roughly linearly. These measurements are historic, not today's compiler benchmark. The same doc records earlier AArch64 generated code with 42.3% memory operations and 21.8% uses of the stack pointer `x28`; adding `aoptimize.zag` showed ~1.36× on one compute loop and 9–10% smaller text on a specific sort benchmark. Re-profile *current* output before prioritizing each alleged remaining stack pattern.

### Follow-up compiler and formal peephole qualification, October 27 (evening)

A fresh macOS ARM64 self-hosted compiler built successfully from the current Zag v2 worktree, including a narrowly scoped optimization of an **adjacent**, same-run `AK_PUSH`/`AK_POP` of an unknown GPR value into `AK_MOV_RR`. Both registers must be nonreserved. `tests/run_aarch64_optimizer.sh` passed with this rebuilt compiler (unit checks and smoke; its unoptimized-baseline differential is explicitly skipped). An independent nine-program old/new native executable differential passed with identical stdout, stderr and exit statuses. `tests/run_aopt_adjacent_push_pop_proof.sh` returned three expected `unsat` proof obligations and one expected `sat` witness demonstrating that the vacated expression-stack memory slot may differ: stack memory privacy is an essential precondition, **not** an unconditional whole-memory equivalence theorem. The proof has an opt-in GitHub CI hook.

The follow-up cross-language run used the new v2 compiler `/tmp/zag-v2-adjacent-transfer-20261027` and the separately built ZagScript compiler `/tmp/zag-script-review-fixes-znc-20261027` against the **same ZagScript benchmark sources** at Script commit `0451729`, on Apple M5 ARM64. For the host Clang link, `SDKROOT` was pinned to the installed `MacOSX26.5.sdk`; the default 27.0 SDK's `libSystem.tbd` was rejected by the current host linker. All five variants matched independent checksums; 30 rotating measured rounds and three warmups per variant were recorded, with executable/source SHA-256 and raw data in `/private/tmp/zag-v2-adjacent-bench-20261027/20261028T034414.697439Z.cross-language.*`.

| Kernel (process-inclusive median) | Rebuilt Zag v2 compiler | Separate ZagScript compiler | Clang C | Rust |
|---|---:|---:|---:|---:|
| Integer recurrence | 26.357 ms | 20.250 ms | 12.685 ms | 13.081 ms |
| Four-way branch | 32.346 ms | 27.043 ms | 14.677 ms | 13.995 ms |
| Helper calls | 32.091 ms | 26.937 ms | 11.251 ms | 13.554 ms |
| **Geometric-mean rebuilt compiler slowdown** | — | **1.229×** | **2.355×** | **2.226×** |

**Do not attribute this difference to the new adjacent-pair rewrite.** The compiler binaries came from **different compiler source branches** and were not built as a one-change control pair. The rewritten compiler does not yet meet the performance-promotion exit gate. A longest-backward-branch static span inspection of the retained binaries found rebuilt-v2 recurrence `90 instructions/28 memory operations/43 x28 mentions/2 bl`, branch `296/86/140/8`, calls `58/20/26/2`; the separate Script compiler yielded `85/20/27/0`, `308/64/96/0`, `35/14/14/2`. These are static code regions selected by an automated backward-branch heuristic, not execution-weighted hardware measurements. Rebuild an exact-source unpatched control compiler and investigate extra helper calls and x28 operations before any claim that this change improves speed. The scoped peephole remains a correctness-qualified candidate only.

**Missing coverage:** real application throughput; steady-state isolated kernels; allocation-intensive programs; large arrays and SIMD; hash maps/strings/Unicode; IO; syscalls; FFI; numeric/floating point; concurrency; allocator effects; memory footprint/RSS; binary size; cold/incremental compiler latency; Linux x86-64 parity. Three integer kernels cannot answer the full competitiveness question.

## 2. Production architecture audit

| Layer | Current observed state | Competitive performance gap | Risk / evidence |
|---|---|---|---|
| Source/type/front-end | Parser, typed checks and edition-gated contracts exist; script normalization lowers to shared compiler. | More efficient declarations, type/ownership/effect summaries, dedicated incremental dependency graph. | Compiler docs `docs/V2_AUDIT.md`, `selfhost/script_syntax.zag`, historical superlinear declaration scaling. |
| Zag IR authority | Production x86 constructs/verifies versioned `ZirAuthority` via `zir_prepare_production_with_origins`; ZIR operation coverage still uses AST bridge. | Full typed SSA coverage and dominance/CFG/value range facts consumed directly by native lowering. | `selfhost/native/znc.zag:7028-7056`, `selfhost/zir.zag:1261-1280`. |
| IR transformations | One narrowly checked const-i32-add source-policy transform in production under explicit flag/restrictions. `zopt.zag` fold/simplify/DCE/CSE remains test-only. | Safely promote common scalar and control-flow optimizations to verified production stages; avoid metadata/width/trap miscompiles. | `selfhost/native/znc.zag:7038-7058`, `selfhost/native/zopt.zag:4-7,683-695`. |
| x86-64 backend | ZIR lower/AST bridge → optional vector stage → regalloc → optimize → peephole → encoding. | Improve cost-based instruction selection, register pressure, strength reduction, loop transforms, inlining, SIMD and scheduling. | `selfhost/native/znc.zag:7188-7194`; only bounded x86 ZIR-vector path in `docs/SUPPORT.md:128`. |
| ARM64 backend | Native `AInstr` lowering with `aoptimize` stack traffic/fold/DCE; x86 vector stage is not consumed. | General SSA lowering/regalloc, vector parity, fused ops, addressing modes, fewer stack temporaries. | `selfhost/native/znc.zag:1966-1971,6690`; `docs/PERFORMANCE.md`; `docs/SUPPORT.md:128`. |
| Runtime/memory | ZagScript has selected 64 MiB default script-allocation budget, arena or bounded-heap policy and process-lifetime model. Some library allocations and allocator overhead bypass accounting. | Escape analysis, stack allocation, allocator specialization, predictable zero-copy slices, ownership-aware elimination; separately measure peak RSS. | `selfhost/script_runtime.zag:1-22,98-112`. |
| ABI/portability | Linux x86-64 primary; macOS ARM64 scoped; Linux ARM64 scoped; i686 limited; WASM artifact-only. C ABI/general linking and memory model incomplete. | More representative optimized workloads and ABI confidence before parity claims beyond core CPU programs. | `docs/SUPPORT.md:18-28,119-131`, `tests/run_v2_release_gate.sh`. |
| Correctness/security | Active semantic/native/proof tests, malformed-input corpus, optional Z3 QF_BV checks, fail-closed v2 gate. | Differential fuzzing and randomized safe/unsafe/compiler-mode equivalence; IR interpreter and end-to-end sanitizers. | `tests/run_zopt_*_test.sh`, `docs/V2_AUDIT.md`. |

**Clarification:** `ZIR` verification in the production x86 path does **not** mean the entire v2 optimizer operates on fully covered SSA. The comments and selector explicitly describe an incomplete AST bridge; optional transforms have much narrower valid domains. Conversely, experimental `zopt` is real code and its tests pass, but has not been qualified for general production use.

## 3. Correctness and qualification status

- **Zag v2:** commit `a81c82a` GitHub workflow runs `40610114421` (standard) and `40610178882` (Z3 opt-in) completed **success** on 2026-10-27. This proves their configured checks, not v2 general-release readiness.
- **Local, correct ARM64 compiler:** `ZNC=./znc-macos-arm64 bash tests/run_zopt_region_scope_test.sh`, `run_zopt_effect_contract_test.sh`, `run_zopt_signed_divmod_proof.sh`, and `run_zopt_reflexive_cmpi_proof.sh` all passed in the v2 worktree. The signed div/mod proof suite reported seven `unsat` obligations and one expected `sat` overflow witness; the compare suite reported twelve `unsat`. The initial attempt using Linux `./znc` on macOS exited 126; corrected using the existing ARM64 seed.
- **ZagScript:** commit `aa0d2be` CI run `40608984891` was still `in_progress` at this audit's check, with native fixed-point job running. Until the full Linux release shards finish successfully, Script release certification remains pending.
- **Zag v2 release gate** `tests/run_v2_release_gate.sh` intentionally reports required **UNSUPPORTED** categories (complete pointer/lifetime, allocators, MMIO, concurrency model, C ABI, general SIMD/inline assembly, GPU/runtime completeness, sanitizers, verification map), even though many bounded slices have executable coverage. Do not treat a CI success for a feature branch as an all-capabilities release gate.

**Release principle:** every optimization is subordinate to source semantics, integer-width/overflow rules, trap and effect preservation, SSA scope, ownership/provenance, target flags, data-race and memory-order contracts. An `unknown` or solver timeout means no proof. A fast wrong-code result is a failure.

## 4. Priority engineering backlog

| Priority | Owner / slice | Work package | Evidence or hypothesis | Exit gate |
|---|---|---|---|---|
| **P0** | Perf infrastructure (both) | Extend implemented SHA-256 artifact retention to compiler/source provenance, normalized assembly, process-subtracted inner-loop timing, 30+ runs and confidence intervals on both CPU targets. | Exact timed sources/binaries are retained in the replication; timings still include spawn and only three tiny integer kernels, with no hardware counters or x86 parity results. | Cross-language outputs match, verified artifact manifest, codegen diff per kernel, reproducible CI on both targets. |
| **P0** | Backend ARM64 | Eliminate verified expression-stack roundtrips, duplicate modulo lowering and unnecessary helper calls using liveness/effect-safe register promotion, CFG reuse and bounded inlining. | Current exact Mach-O inspection found 85 vs 14 instructions for recurrence, 308 vs 18 for branch (static spans), and 2 Script calls vs 0 C calls per outer iteration; elapsed-cycle attribution still needs profiling. | >10% median speedup on affected kernel without >3% geometric-mean regression, identical outputs on 2 targets. |
| **P0** | IR authority | Make integer widths, signedness, overflow and trap/effect/provenance metadata stable across ZIR transformations and codegen. Complete CFG dominance and SSA validation. | `zopt` currently explicitly lacks general integer-width semantic guarantees. | Fuzz/differential/Z3 checks plus recorded metadata and no-artifact on failed proof. |
| **P1** | Shared optimizer | Turn scoped SCCP/constant propagation, GVN/CSE, DCE, CFG simplify, copy propagation, value numbering into production on explicitly supported operations; proof-gate risky rewrites. | Existing test-only optimizations; production has explicit selector seam. | Every pass validated by IR equivalence, golden machine code, full native gates on x86 and ARM64. |
| **P1** | Mid-end / calls | Add interprocedural call graph, bounded inliner, devirtualization, escape analysis, stack promotion, loop-invariant code motion, induction strength reduction and range-based check elimination. | Needed to compete on branch/call/memory programs; concrete payoff currently hypothesis. | Per-pass before/after perf, compiled-size and memory deltas, sanitizer and wrong-code regression suite. |
| **P1** | Codegen both | Target aware lowering, better register allocation/spill coalescing, fused instruction patterns, verified fixed-divisor specialization and concrete fast paths for arrays/slices. | Backends have separate optimization pipelines and unsupported vector parity. | Analyze instructions per iteration, spills, total cycles, branch misses for representative cases. |
| **P2** | SIMD/arrays | Vector IR parity to AArch64 NEON; broaden x86 SIMD/vector ABI; alignment/tail handling, loop vectorizer cost model, runtime dispatch by hardware capabilities. | Currently bounded vector path, AArch64 does not consume it. | Randomized scalar/vector equality plus benchmark on both CPUs with forced feature variants. |
| **P2** | Script runtime/libs | Charge or explicitly scope all allocating Script conveniences; add benchmarked ergonomic collections, UTF-8/Unicode, JSON, string builder, and streaming paths; specialize ownership/layout to avoid allocations. | Script allocator limit excludes ordinary `make`, strict imports, size-class slack. | Same API semantics with bounded allocations and lower p95 latency/RSS across real application corpus. |
| **P2** | Toolchain | Profile compiler stage hot spots, fix declaration superlinearity, reduce repeated lowering/format passes, incremental rebuild caching with deterministic evidence. | Historic ~248 s one-stage self-compile; cause of K-scaling unresolved. | Median full / incremental compile time and peak RSS measured on same import closure and stable host. |
| **P3** | Verified search | Equality saturation, superoptimization, SMT bounded candidate search, profile-guided optimization and whole-program layout specialization. | Small QF_BV proofs exist; no global optimality established. | Proof checker and target cost calibration; candidate used only on confirmed win, rollback on unknown. |

Avoid reimplementing an entire LLVM-scale optimizer as a blocking prerequisite. Start with targeted backend improvements and a shared correctness-first mid-end in parallel. Keep optional high-risk passes behind explicit per-target/profile flags until fully proven and fuzzed.

## 5. Formal and mathematical optimization: where it pays

1. Specify executable mathematical semantics for integer widths, signed division remainder, shift counts, overflow and traps, floating-point modes, memory effects and ownership. Proof claims must identify the domain and assumptions.
2. Generate rewrite candidates from e-graph algebraic identities, peephole peepholes and target instruction templates. For pure finite-width integer fragments, use QF_BV/Z3 to prove equality or a counterexample; for effects, require verified memory/effect models, not arithmetic-only proof.
3. Select among proven candidates with *measured target-specific* cycle/throughput, register pressure, code size and energy costs. Constant time, side-channel properties and memory-safety constraints take precedence in their declared profiles. A shortest algebraic expression may be slower on a particular CPU.
4. Budget candidate search by function and wall time; cache certified transformations under IR, semantics, target, CPU features, solver and cost-model identity. For timeouts or `unknown`, use the checked original.
5. Gate promotion with translated validation (e.g. independent symbolic checker), differential fuzzing on actual binaries, sanitizer runs and instruction trace comparison; use known incorrect candidates to test that the verifier rejects them.
6. State any optimality narrowly: optimum within a finite candidate grammar and given cost model, not universally fastest possible code.

The current QF_BV signed-div/mod and compare proofs support a few exact identities; they do not prove a broad optimizer fast or correct.

## 6. Benchmark contract required for competitive claims

**Targets:** Linux x86-64 (baseline/generic and native ISA tiers), Apple Silicon ARM64, and Linux ARM64 once scoped support qualifies. **Reference compilers:** Clang/GCC C and current Rust stable, with matched `-O2` and `-O3` profiles, defined target CPU/ISA, LTO and PGO comparison modes when available, ABI and runtime assumptions documented. All sources implement the same algorithm and valid overflow/FP contract; no dead-code elimination of test work. Make whole-command, pure-kernel, compile time, RAM and binary size separate columns.

**Suite:** integer recurrence/branch/calls plus fixed divisor, bit manipulation, sorting, hash/string/tokenization, typed JSON, array/linked data structures, allocation/deallocation, buffer copy, compression/crypto, floating point/reduction, matrix/SIMD, recursion, FFI, syscalls, concurrency, I/O. Include at least two realistic multi-file applications and more than one input size/distribution. Keep correctness oracle and checksum verification independent.

**Statistics:** 30+ interleaved stable-host samples with controlled CPU power/thermal/load, 95% confidence intervals and raw CSV; primary score geometric mean of per-workload runtime ratios, secondary no-regression/p95 gates. Clearly label warm/cold, CPU time vs wall and spawn-inclusive vs kernel-only. Retain compiler SHA, source SHA, emitted binary, map, assembly, and a process environment manifest. Hardware counters and annotated hot assembly are the attribution gate for every major optimization PR.

**Target score ladder (not schedule promises):** Stage A: all valid program outputs and reliable baseline; Stage B: geomean ≤1.50× C and Rust, no >2× critical workload; Stage C: ≤1.15×, no >1.50× critical workload; Stage D: ≤1.05× on both architectures, with documented workloads beating each reference by at least 10% at a non-overlapping confidence interval. Overall superiority requires also comparing compile latency, memory/RSS, binary size, correctness, safety, portability, and developer experience in distinct dimensions. A selected workload win does not constitute universal domination.

## 7. Execution program and decision gates

**0–2 weeks, evidence before optimization:** freeze compiler/profile definitions, retain benchmark artifacts, add realistic workloads, compare disassembly and counters, establish direct kernel-only ratios, build CI perf trend dashboard. Assign one owner each to ARM64, x86+IR, Script runtime, and independent correctness/benchmark review. Rank top three verified cycle sinks by actual cycles/iteration and attainable speedup.

**Weeks 2–6, targeted gains:** implement top two backend fixes on each affected target (for example redundant x28 traffic, constant modulo, unnecessary helper calls, spills), add regression tests and prove the critical rewrite rules. Measure every change with counterfactual clean builds, keeping speed and code size transparent.

**Weeks 6–12, shared mid-end:** complete typed CFG/SSA coverage for the kernel/array/string subset, add bounded production passes, inlining, range analysis and escape analysis. Differential-test Zag strict and ZagScript lowering through the same IR and machine-level oracles.

**Weeks 12–20, target parity and larger applications:** vector ARM64 parity and x86 widening, loop transforms, allocator fast paths, whole-program specialization, profile guided layout and representative workloads. Promote passes only when verified on both architecture profiles and the v2 release matrix explicitly supports their semantics.

**Beyond:** certified e-graph/superoptimizer search, FFI and concurrency throughput parity, broader platforms, comprehensive fuzz/sanitizer execution, measured compiler speed and tooling experience. Maintain parallel Zag v2 correctness and ZagScript v1 ergonomics work with explicit shared compiler performance ownership.

**Ship / PR policy:** draft PRs with source/benchmark evidence, fixed input/output checks, full relevant tests and reproducibility artifacts. Strict v2 release gate remains fail-closed until its required `UNSUPPORTED` rows are satisfied. No broad "faster than C/Rust" messaging before the score ladder is met on a diverse corpus.

## 8. Audit limitations

This review examines a large compiler through selective source inspection, existing project audits, local targeted tests, new cross-language measurements and CI statuses. It does **not** certify an exhaustive per-function code audit, prove the whole language safe, inspect every emitted instruction or test all supported target/feature combinations. Some historic documents were written against older or dirty trees and are used as hypotheses to remeasure. The separate host-native ZagScript compiler's build provenance should be independently established before publication. Future profiling is necessary to turn suspected hot spots into proven ones.

### Reproduction pointers

- `zag-poc/benchmarks/run_cross_language.py`: current 30-run cross-language process-inclusive experiment and metadata.
- `zag-poc/benchmarks/test_cross_language.py`: opt-in harness test; run as `python3 benchmarks/test_cross_language.py`, with native compiler specified.
- `zag-poc/selfhost/native/znc.zag:7038-7110` and `:7188-7194`: production ZIR bridge, x86 codegen and vector stages.
- `zag-poc/selfhost/native/zopt.zag:4-7,683-695`: experimental opt suite.
- `zag-poc/docs/PERFORMANCE.md`: historic compiler/ARM64 machine profiles, measured optimization wins and regressions.
- `zag-poc/docs/SUPPORT.md` and `zag-poc/tests/run_v2_release_gate.sh`: exact target and release boundaries.
- `zag-poc/selfhost/script_runtime.zag:1-22`: Script allocator accounting and limits.
- [Zag v2 draft PR #23](https://github.com/Sylorlabs/zag/pull/23) and [ZagScript v1 draft PR #21](https://github.com/Sylorlabs/zag/pull/21).
