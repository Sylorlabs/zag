# Zag manual hardware-control — status

Zag's pitch over Zig is manual control across the modern hardware matrix, not just
the CPU. Five areas, mapped to their implementation in the **Zig bootstrap compiler**
(`src/`). Status as of 2026-06-24.

## 1. Manual cache-line control — ✅ DONE (this is the genuinely-new tier)

All portable C — no platform asm in the bootstrap.

| Surface | Lowers to | Effect | Notes |
|---|---|---|---|
| `@prefetch(slice)` / `@prefetchWrite(slice)` | `__builtin_prefetch` (PREFETCHT0 / PLD / PRFM) | **none** | pure hint → legal in `@realtime`/`@noalloc` |
| `@prefetchI(slice)` | `__builtin_prefetch` | none | prefetch a `[]i32` |
| `@cacheLineSize()` | `ZAG_CACHE_LINE` const | none | target line width (compile-time) |
| `@cacheAlignedAlloc(n)` / `@cacheAlignedFree` | `aligned_alloc(64, ..)` | `{Alloc}` | honest — rejected in `@realtime` |
| `@cacheAlign(N) let x: T = ..` | C11 `_Alignas(N)` | — | pin a hot binding to its own line |
| `struct S { @cacheAlign(N) f: T, }` | `_Alignas(N)` on the field | — | kill false sharing |

The point: `@prefetch`/`@cacheAlign` are pure hints, so the audio render block can warm
L1 and pin a hot accumulator **without losing its `@realtime` proof**; `@cacheAlignedAlloc`
is honestly `{Alloc}` and is rejected on a realtime path.

Implementation: `src/types.zig` BUILTIN_TABLE (the 6 builtins); `src/codegen.zig`
`PRELUDE_CACHE` runtime + builtin C-name dispatch + `_Alignas` emission in `genLet`/
`genStructDecl`; `src/parse.zig` `cacheAlignOpt()` (power-of-two checked) wired into
`parseStmt` and struct fields; `src/ast.zig` `Let.cache_align` / `Param.cache_align`.
Examples: `examples/cache_control.zag` (→ `64 1 3 4`), `examples/cache_control_bad.zag`
(rejected: `renderBlock -> @cacheAlignedAlloc()`). Tests in `run_tests.sh`.

Scoped out (portable-C-only): no L1 pinning / `clflush` eviction (platform-specific);
prefetch covers `[]f32`/`[]i32` element slices.

## 3. Operator contracts for custom units — ✅ DONE

`operator T { + => addFn, - => subFn, * => mulFn, / => divFn }` maps arithmetic on a
user type to named decode functions. It is a **checked** mapping:
- each named fn must be `(T, T) -> T` (verified in `Sema.checkOperatorContracts`);
- the contracted op type-checks even for a fresh struct (`Sema.typeOfBin`);
- the op's effect **flows into the capability proof** — an allocating decoder breaks
  `@realtime` with a precise witness (`'+' on Big → big_add()`).

Implementation: `src/lex.zig` `operator` keyword; `src/ast.zig` `OperatorDecl`/`OpEntry`;
`src/parse.zig` `parseOperatorDecl`; `src/sema.zig` `operators` map + `opContractNode`/
`opContractFn` + `checkOperatorContracts` + `typeOfBin` dispatch + the `.bin` effect flow;
`src/codegen.zig` `genBin` dispatch to the decode fn. Examples: `examples/operator_contract.zag`
(custom Q16.16 `Fix` → `5 1 6 1 98304`), `examples/operator_contract_bad.zag` (rejected).

Scoped out: single-type `(T,T)->T` contracts only (no mixed-type, comparison, or generic
contracts yet).

## 2. Heterogeneous execution mapping — ✅ PRE-EXISTING (untouched)

MLIR/GPU backend: `@kernel`/`@device` fns, `gpu_buf<N>`, `@gpuThreadIdx`/`@gpuAlloc`/
`@gpuLaunch`, nvidia/amd/vulkan lowering. See `src/` GPU paths and `examples/gpu_*.zag`.
The vision's `gpu_fabric { .. }` block sugar would be new sugar over this.

## 4. VSA concurrency — ✅ PRE-EXISTING (untouched)

`vsa_b<N>` hypervector types + `@vsaBind`/`@vsaBundle`/`@vsaSim` (`src/types.zig`
BUILTIN_TABLE). The vision's `v64` single-thread concurrency primitive would build on this.

## 5. AST-level context windows — ✅ PRE-EXISTING

`zagc check --json` / `--ast` / `--deps` and the self-hosted `zag ast` (AST→JSON,
schema `zag.ast/v1`, `src/jsonout.zig` + `selfhost/astjson.zag`).
