# ZagScript 1.0 masterplan

ZagScript is Zag's compact prototyping surface. It must stay on the same parser,
AST, type/effect authorities, libraries, runtime contracts, and native backend
as explicit Zag. The product promise is that a prototype can become production
code by making selected behavior explicit instead of rewriting it in another
language.

## Product invariants

1. Compact source and explicit Zag share one semantic model. No Script VM,
   dynamic `any`, second package ecosystem, or Python compatibility layer.
2. Complexity is selectable. A project may remain mostly compact while a hot,
   safety-sensitive, or integration-heavy function becomes explicit Zag.
3. User-written explicit code is developer-owned. Automatic optimization may
   preserve semantics around it but must not silently replace its declared
   algorithm or contracts.
4. Compiler-owned `auto` regions are opt-in synthesis boundaries. Their
   objective, constraints, evidence, and generated implementation must be
   inspectable, reproducible, and exposable as ordinary Zag.
5. Unsupported proof or synthesis cases fail closed. "Best" is never claimed
   without a bounded objective and evidence.

## The explicitness continuum

The intended workflow is:

```text
compact -> explained -> explicit -> native
```

The unit of exposure should progress from function to type/module and finally
statement/region when source provenance is strong enough. `view` is read-only.
`expand` creates a derived projection. `promote` is the provenance-backed path
for human-owned expanded source once ledger runtime integration is release-ready.

Acceptance criteria for function-level exposure:

- `znc view app.zs --level explicit --symbol parse_users` prints only that
  function's ordinary Zag projection.
- missing and ambiguous symbols fail with no output artifact;
- `--output` remains create-only and never overwrites compact source;
- the selected declaration comes from the shared parsed compilation unit;
- whole-file compilation behavior is unchanged when `--symbol` is absent.

Current function selection is a text preview only: `--output` with `--symbol`
is rejected pending provenance-backed selective promotion. Imported functions
and compiler-generated wrappers are excluded from root selection.

The source-backed remaining-work audit is in `ZAGSCRIPT_REMAINING_AUDIT.md`.
Typed interpolation, map and record literals, bounded function inference,
checked `auto` lowering, and root JSON facade calls now have focused executable
authorities. Remaining work is tracked by the capability matrix rather than by
the audit's original source snapshot.

## ZagScript 1.0 surface

### Implement/current

- indentation blocks and optional line semicolons;
- assignment/reassignment, `if`/`elif`/`else`, `while`, `for`, `range`, `def`,
  `return`, `pass`, booleans, `None`, lists, append/index/length, print/input;
- bounded Script context, files, args, paths, subprocess boundary, string
  builder, typed JSON through ordinary Zag modules;
- typed interpolation, map and record literals, bounded function inference,
  root JSON conveniences, and structured async/cancellation;
- explain/view/expand/harden foundations and source-origin tracking;
- typed/effect analysis and one native compiler/backend authority.

### P0: prototype ergonomics

- Python-shaped `and`/`or` lowering; reject unsupported identity semantics;
- spacing-independent assignment, compound assignment, inline comments;
- concise Result/optional handling suitable for short scripts;
- normal list/map/string iteration and richer string operations.

### P1: production-shaped prototyping

- bounded HTTP client/server conveniences;
- tasks/async with structured cancellation and explicit isolation rules;
- tests/assertions and a REPL;
- deterministic `zag add`, `zag run`, `zag test`, lockfile and package cache;
- ergonomic database/serialization projections over ordinary Zag libraries.

## Developer-owned and compiler-owned code

Zag should make ownership of implementation intent explicit.

```text
developer-owned region
  exact source algorithm + explicit constraints
  optimizer may perform ordinary semantics-preserving backend optimization

compiler-owned auto region
  semantic contract + objective + resource constraints
  planner may synthesize/search implementations
  chosen implementation is checksum-bound and inspectable
```

The following is an incomplete design sketch, not accepted syntax:

```zag
fn dot(a: []f64, b: []f64) f64 {
    auto optimize(runtime);
}
```

The name `dot` and its signature do not specify the computation. A synthesis
request must additionally supply an executable reference or formal postcondition,
length rules, floating-point rounding/reassociation policy, and allowed effects.
This syntax must not ship before the compiler can represent that contract in the
shared AST/IR and reject unsupported cases. An `auto` region is not a TODO or
LLM text hole. It is a compiler-owned implementation boundary.

### Optimization objectives

Initial objectives should be finite and measurable: `runtime`, `memory`,
`binary_size`, `energy`, and `determinism`. Multi-objective optimization needs
an explicit priority order or budget. "Mathematically optimal" is only a valid
claim for a bounded search space with a proven optimum; otherwise reports must
say measured/derived best-known candidate.

### Synthesis acceptance criteria

- semantic contract and effect set are fixed before search;
- generated candidates cannot gain undeclared I/O, allocation, unsafe access,
  nondeterminism, or concurrency effects;
- candidate identity includes compiler image, source graph, target, objective,
  constraints, and benchmark/proof inputs;
- automatic verified replacement requires equivalence evidence accepted by a
  supported checker; differential/property tests can reject bad candidates but
  do not prove equivalence, and cannot silently satisfy a proof requirement;
- the result can be viewed at explained/explicit/native levels;
- exposing/editing a generated region transfers it to developer ownership;
- rebuilds are deterministic when inputs and measurement profile are fixed.

## Core Zag gap audit

| Reference | What it does well | Zag/ZagScript requirement |
| --- | --- | --- |
| Python | extremely low ceremony, strings/collections/JSON, REPL | match common prototype ergonomics while retaining static Zag semantics |
| Rust | ownership, borrowing, `Send`/`Sync`-style concurrency safety | finish language-wide ownership/provenance and race-safe transfer boundaries before aggressive automatic parallelization |
| Zig | compile-time specialization and explicit low-level control | add a principled compile-time/specialization model that `auto` can target without a separate metaprogramming language |
| Go | modules, deployment, simple tasks/channels | make package/build/test/deploy workflows boring and reproducible; keep structured concurrency small and explicit |
| Swift | isolation-aware concurrency and ergonomic high-level syntax | adopt explicit isolation/sendability concepts where they help automatic task placement |
| Julia | type specialization and prototype-to-numerical-performance workflow | strengthen specialization, vectorization, numerical kernels, and evidence-backed search for compiler-owned hot regions |

Core Zag changes are justified only when a ZagScript requirement cannot be
implemented as a thin projection without semantic duplication. Highest-value
core work is ownership/provenance completion, concurrency isolation,
compile-time specialization, package reproducibility, and a stronger typed IR
coverage path that removes checked-AST fallback ceilings.

## Implementation order

1. Finish compact syntax ergonomics with focused source-normalizer tests.
2. Add function-level selective explicit projection using the shared AST.
3. Make interpolation/maps/JSON/files/HTTP pleasant while preserving bounded
   Script allocation and capability accounting.
4. Finish reversible promotion ledger runtime integration.
5. Add package/test/REPL workflows and structured tasks.
6. Introduce `auto` as a shared-AST contract with one tiny proven synthesis
   domain first (for example pure fixed-width arithmetic), not general codegen.
7. Expand synthesis to SIMD/layout/tiling/parallel candidates only as typed IR,
   ownership, and effect authority can prove the relevant boundaries.

ZagScript 1.0 should be considered successful when a realistic CLI, data tool,
or small service can start compact, remain mostly compact in production, expose
only selected functions for control, and never require a language/runtime
rewrite to reach native Zag performance and deployment.
