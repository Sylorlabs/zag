# Consolidated compiler compatibility and reproducibility reference

**UNCOMPILED / UNEXECUTED — static source review only.** Starting branch HEAD: `d623f16c366a4ce3ef18912828fee0a538a635b0`; original compiler baseline `f8b287bad32d4f93d272c270cff772e59b858515`. This document is an index and a bounded update, not evidence of a successful build, run, release, or complete audit. All commands below are for an authorized executor in a disposable checkout; none were run here.

## Original artifacts

* [Version/edition claims matrix](tomo-zag-version-claims.md), commit `d623f16c366a4ce3ef18912828fee0a538a635b0`: frozen normative v1 core vs implemented edition-2026 extensions vs proposed v2/edition-2027. An individual v2 feature is not evidence of a v2 release.
* [Numeric contract ruling](tomo-numeric-contract-ruling.md), commit `28f29c5676677d373f051432065ededefb1676a6`: numeric compatibility is a documented backend-owned implementation extension, not part of the frozen v1 core. The ruling does not establish that every conversion path has identical semantics.
* [Pointer portability and ABI](tomo-pointer-portability-abi.md), commit `3916a493e6f235b8161acd4ea374c9859f34f72a`: distinguish documented byte-scaled pointer addition from element-scaled indexing; do not conflate them or assert a defect without a failing witness.
* [Foreground cache audit](tomo-foreground-cache-audit.md), commit `e69b9a43e3ac32b082b0ebf39cceea3c56a8e63f`: no defect found in the reviewed identities, not a proof that every output-affecting option is keyed.
* [Bitwise-NOT candidate patch](tomo-unsupported-bitwise-not.patch), [negative fixture](tomo_bitnot_negative.zag), [positive fixture](tomo_bitwise_positive.zag): research files only. Patch is NOT applied to compiler source; diagnostic category, exact output, positive syntax, context application, and test behavior are not verified. Do not deploy without the checks below.

## Parser diagnostic — unresolved

At the starting HEAD, `selfhost/lex.zag` emits an otherwise-unrecognized single character as `Tk.Op`; `~` therefore becomes an operator token. `selfhost/parse.zag`'s `parse_unary` handles `-`, `!`, and `&` but has no `~` branch; `parse_primary` instead falls back to treating an unknown token as an identifier. A fix should check `at_op(p, "~")` before parsing the operand and call the structured diagnostic with the captured token's `line`, `col`, and `val.len`, so the caret marks `~` rather than a following token. Keep valid unary paths unchanged.

Do not assume the existing patch's `E0001` is a suitable generic parse error: the observed parser uses it for unexpected end of input. `selfhost/diag.zag` describes `E0010` as unexpected token at top level and `E0017` as `#embed` errors; `E0030` is used for async diagnostics. No existing generic unsupported-operator category was established in this limited review. Confirm the appropriate scheme with the diagnostic owners/source before producing a deployable patch. The create-file-only publication restriction prevents a direct edit of the existing `selfhost/parse.zag`; no such edit was made.

`tests/run_diag.sh` discovers `tests/diag/*.expected` and diffs the expected text against normalized compiler output; research fixtures are not automatically picked up. It requires failure and no output artifact. The exact `.expected` text cannot responsibly be asserted without settling the category and executing or fully deriving the formatter. No exact expected file or verified-context replacement patch is supplied here. An authorized executor should rebuild the compiler per the repository's bootstrap instructions, then run `cd zag-poc && bash tests/run_diag.sh` and run the positive fixture through the rebuilt compiler and native test harness. Record exact command, compiler image hash, full output, exit code, and resulting `.expected`; do not use a stale compiler binary.

## Numeric evidence and tests to decide remaining questions

`selfhost/typed.zag` describes existing v1 numeric representation extensions as backend-owned. In `selfhost/native/ncodegen.zag`, reviewed scalar local declarations and identifier assignments normalize to the destination type; the observed `i32` path retains the low 32 bits and sign-extends. A value outside the `i32` range may therefore lose information silently in those reviewed paths. This does not prove that calls, returns, record fields, maps, or every architecture apply the same rule.

Real mixed-width source: `tests/reference_apps/concurrent_file_indexer/main.zag` passes `IndexResult.bytes_read: i32` to `index_print_i64(value: i64, ...)`; the same program adds that field to an `i64` total. No execution or independent expression-type resolution was performed. The compiler's own `tests/i686_i64.zag` includes explicit `(-7 as i32) as i64` and `(255 as u8) as u64`; the first asserts the result `-7`. These are explicit casts, not evidence that implicit narrowing is safe.

Proposed differential test matrix, not yet written or run: exercise explicit `as` and implicit local declaration, identifier assignment, argument, return, and field assignment separately; check in-range signed widening and boundary values `2147483647`, `2147483648`, `-2147483648`, `-2147483649` and `4294967297`, plus signed/unsigned boundaries. For the observed local/assignment path, the hypothesis for `4294967297` into `i32` is `1`; for `-2147483649` it is `2147483647`. Compare each result across native targets and against explicit casts. Assert rejection, trapping, or wrap only after the relevant path and intended contract are established. Preserve in-range existing code; consider an opt-in warning or future-edition checked conversion rather than silently breaking existing edition-2026 programs.

## Cache coverage and executable invalidation witness

`selfhost/native/znc.zag` reads `--script-allocator`, `--device`, and `--layout` via `flag_value` into `PlannerChoices`; the choices are supplied to `planner_resolve`. In the reviewed macOS policy construction, the cache key receives a derived `script_execution` policy, not the three raw strings individually; no bypass based solely on these options was observed. The downstream configuration, other target paths, and imported lowering/optimizer options have not been traced fully, so equivalence of all flag choices is unproved. This is not a cache bug claim. The observed `src_arg()` paired-option skip list omits these three flags, suggesting a separate possible argument-order problem when a flag precedes the source; verify by running before reporting a defect. Put the source path first in the witness below.

The repository already contains a targeted source-change test. From an authorized checkout with its own rebuilt `zag-poc/znc`, run:

```sh
cd zag-poc
bash tests/run_foreground_cache_integration.sh
```

Its source creates `dep.zag` containing `fn cached_value() i32 { return 42; }` and `main.zag` containing `@import("dep.zag")` and `fn main() i32 { return cached_value(); }`. It expects cold `znc cache: MISS stored machine code and data`, then warm `znc cache: HIT revalidated machine code and data; codegen skipped`, both exiting `42`. It changes the dependency's `42` to `41`, expects `znc cache: MISS stored machine code and data; lowering_calls=1`, and expects the new executable to exit `41`. It also compares fresh/cached outputs and checks other cases; inspect its prerequisites and platform-specific skips. These are source-defined expectations, not observed output here. For script-flag coverage, run otherwise identical compilations under each valid distinct resolved allocator/device/layout selection, compare cache-enabled output and behavior against `--no-foreground-cache`, and capture the resolved configuration and cache key. Only differing output under an incorrectly reused key establishes a stale-result witness.

## Pointer indexing and safety

The source tree includes `tests/i686_pointer_index.zag` (indexing `*usize`) and `tests/i686_reject_pointer_index_signed.zag` (signed pointer index rejection); `tests/run_i686_minimal.sh` covers target tests. `tests/run_macos_checked_safety.sh` includes null, alignment, heap bounds, and raw pointer index overflow cases. These are test-source observations, not independent passes; read the individual fixture and harness assertions before interpreting platform or safety guarantees. `cd zag-poc && bash tests/run_i686_minimal.sh` and `cd zag-poc && bash tests/run_macos_checked_safety.sh` are candidate executor commands subject to their toolchain and platform prerequisites. A complete inventory of unsafe cases and missing diagnostics has not been made; no new pointer defect is asserted.

## Successor queue and evidence boundary

1. Decide the parser diagnostic category from the repository's actual scheme; create a context-checked diff, precise negative `.expected`, grammar-verified positive fixture, and validate them against a rebuilt compiler.
2. Add and run the numeric differential tests across all conversion sites and supported targets; determine whether warnings or a future edition should distinguish narrowing.
3. Trace the three Script choices through `znc_configure_script_unit`, `planner_resolve`, execution-policy construction, both cache paths, imported lowering and optimizer options. Compare enabled vs disabled cache before asserting a mismatch.
4. Read each pointer fixture and target-specific diagnostic; cover out-of-bounds, overflow, null, alignment, and element scaling without presuming raw pointers carry bounds.
5. Record compiler source revision, image hash, build command, machine/target, exact inputs, output, exit status and logs for every executed result. Source-only, repository-reported historical results, and independently reproduced runs must remain separate.
