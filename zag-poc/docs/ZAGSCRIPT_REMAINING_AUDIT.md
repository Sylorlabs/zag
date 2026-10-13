# ZagScript remaining implementation audit

Status refresh: interpolation, map literals, lightweight records, bounded
function inference, root JSON conveniences, and the first checked `auto` domain
now have focused executable suites. The findings below preserve the original
design review and acceptance boundaries; they are not a current claim that
those surfaces are absent. Remaining collection work includes deterministic
cleanup for Script-owned allocating collections, Unicode normalization, and
grapheme segmentation. Strict allocation-free scalar indexing and scalar-range
slicing now have native collection-suite coverage.

Source inspection: 2026-09-11, against the current dirty working tree, not
just HEAD. Scope: interpolation, maps, records, JSON convenience, function
inference, and compiler-owned `auto`. This audit changes no compiler code.
Paths below are relative to `zag-poc/`. Existing work and untracked files were
read as evidence, not treated as released or runtime-verified functionality.
The platform contract remains `docs/SUPPORT.md`.

## Findings and order

| Priority | Work | Current evidence | Completion boundary |
| --- | --- | --- | --- |
| P0 | Typed interpolation | Quoted content is copied by `zs_emit_expr`; AST strings are `StrLit`, without interpolation parts | Parse expressions, type conversions, single evaluation, bounded storage, source diagnostics |
| P0 | Map literals and access | Ordinary typed `StringMap[V]` / `HashMap[K,V]` exist; compact access binds to Script list helpers | Typed key/value policy, ownership/accounting, lookup and iteration semantics |
| P0 | Lightweight records | Named `StructLit` and `StructDecl` exist | Decide nominal versus structural identity; preserve field typing and lifetime rules |
| P0 | Function inference | Compact omitted parameters and returns default to `i64` | Solve constraints or request annotations; never describe defaults as inference |
| P0 | JSON convenience | Bounded typed document parser/encoder exists; no implicit JSON binding in `script_bind_expr` | Thin typed API with cleanup, errors and Script budget integration |
| P1 design, P2 implementation | `auto` | Existing IR transform authority is a foothold; no dedicated auto contract in inspected AST/parser | Semantic specification, restricted verified domain, explicit evidence and reproducible selection |

Implement a shared type/ownership design first. Interpolation can then land
independently; maps/records and function inference should agree on type identity
before JSON-to-record projection. Keep general synthesis behind these foundations.
Priorities here order this remaining work; they are not release status claims.

## Interpolation: expression semantics before text substitution

**Observed.** `selfhost/script_syntax.zag::zs_emit_expr` preserves double-quoted
text and rewrites tokens outside it. `selfhost/lex.zag::lex`,
`selfhost/parse.zag::parse_primary`, and `selfhost/ast.zag::StrLit` provide ordinary
string handling, not an interpolation expression model. Existing bounded helpers
are `selfhost/std/script_string.zag::script_string_concat` and
`selfhost/std/script_string_builder.zag::{script_string_builder_new,
string_builder_append,string_builder_output}`. These do not establish formatting
semantics or account for arbitrary conversion temporaries by themselves.

**Integration.** Specify delimiter/escape grammar, supported scalar formatting,
evaluation order, and errors. Extend lexical/CST handling and `parse_primary`
with expression parts and origins, then lower to ordinary typed helper calls.
Use `selfhost/typed.zag::zt_expr_type` / `zt_check_expressions` to choose supported
conversions; reject unknown types instead of adding dynamic stringification.
Connect context injection through `parse.zag::script_bind_expr` and the module
loading in `parse_compilation_unit_dir_with_script_limit`. Account for conversions,
intermediate buffers and output through `selfhost/script_runtime.zag::script_alloc`
and the native `_zag_script_alloc` path. Do not repeatedly concatenate a growing
prefix without specifying the resulting memory cost.

**Acceptance gates.** Literal braces/quotes/backslashes, Unicode, nested calls,
empty parts, malformed delimiters and unsupported formatting get targeted cases.
An effectful expression executes exactly once in source order. Integer boundaries,
boolean spelling and any supported float format have explicit expected output.
Budget exhaustion and length overflow fail deterministically without partial
success. Compact and explicit projections preserve behavior and point errors to
the original expression; synthetic origins must not be labeled byte-exact.

## Maps: library availability is not Script literal support

**Observed.** `std/map.zag::{make,put,get,grow,free}` implement string-keyed maps;
`get` returns an optional, `put` replaces an existing value, keys are borrowed
slices, and table allocation uses `_zag_malloc`. `std/hashmap.zag` additionally
accepts typed hash/equality functions. Neither fact establishes Script-context
ownership. `zs_emit_expr` rewrites identifier indexing to `item_at`, and
`parse.zag::script_bind_expr` binds `item_at`/`len` to list-specific helpers.

**Integration.** Add literal parsing at `parse_primary` with an unambiguous map
versus block/record grammar. Resolve homogeneous key/value types in `zt_expr_type`;
start with string keys if broader hashing has no stable contract. Type-directed
index/length lowering must replace the unconditional list choice, including
compound expressions such as a map returned from a call. Extend
`parse.zag::parse_for` only after specifying keys/values/entries, iteration order,
and mutation during iteration. Reuse the ordinary map implementation through a
context-aware allocation/ownership adapter; direct calls to `map.make` do not
automatically charge the Script limit. Specify key copying or borrowing and
which container owns nested values and replaced entries.

**Acceptance gates.** Empty literals require contextual types or diagnostics;
mixed incompatible keys/values are rejected. Test duplicate keys, hash collisions,
growth, missing keys, dynamic keys whose source buffer is reused, nested values,
and mutation during iteration. Lookup must distinguish absence from valid zero,
false and empty values. Budget accounting includes growth and retained old arena
buffers; cleanup must respect the selected allocator. Verify collection dispatch
does not regress lists, strict generic calls, or user-defined helper shadowing.

## Records: choose identity and layout explicitly

**Observed.** `ast.zag::{StructDecl,StructLit,FieldInit}` and
`parse.zag::parse_struct_lit` already represent named typed aggregates.
`typed.zag::zt_expr_type` resolves field access through `zt_aggregate_field_type`.
There is no separate anonymous record variant in the inspected `Node` union.

**Integration.** Prefer an initial shorthand for a known named struct; anonymous
structural records require a deliberate extension, not a generated name chosen
independently in each backend. Define identity across modules, field order,
mutability, equality and optional/missing fields. Lower to canonical `StructLit`
after type resolution. Feed pointer-bearing records through
`zt_check_v2_aggregate_provenance` and `zt_check_resource_flows`; note the former's
edition-scoped entry point rather than assuming it covers every Script profile.
Any synthesized declarations need stable origins and names for projection/cache
identity. Do not imply ordinary records have `@repr(C)` ABI compatibility.

**Acceptance gates.** Duplicate/unknown/missing fields and incompatible field
types fail before emission. Test field order and side effects, nesting, returning
records from functions, cross-module identity, and borrowed/owned fields through
copy, mutation and escape. Explicit output must name concrete types and compile
with the same semantics on each claimed target.

## Function inference: remove defaults only with a replacement authority

**Observed.** `script_syntax.zag::zs_emit_def` emits `:i64` for each unannotated
parameter and initializes the omitted return type to `i64`. The regression in
`tests/run_script_python_shape.sh` even expects that signature in formatted output.
This loses the distinction between an omitted annotation and an explicit `i64`.
`parse.zag::parse_fn` stores concrete `Param.pty` / `FnDecl.ret`; local expression
typing in `typed.zag::zt_expr_type` is not a whole-function constraint solver.

**Integration.** Preserve missing-annotation metadata through normalization and
parsing. Add a bounded signature-resolution pass before consumers of concrete
signatures: expression checks, effect/ownership checks, generic specialization,
IR lowering and backend ABI decisions. Infer from body operations, return paths
and permitted call-site constraints; use a fixed point for recursive call groups
or explicitly reject unresolved recursion. Define monomorphic versus specialized
functions, numeric defaulting/widening, public/imported signature rules and
ambiguity diagnostics. Keep explicit annotations authoritative. Existing generic
backend machinery is an integration consumer, not a substitute for resolution.

**Acceptance gates.** Unannotated identity functions called with strings, booleans,
numbers and records either infer under the documented policy or clearly request
annotations. Cover inconsistent call sites, forward references, recursion,
unused parameters, closures, no-return functions, mixed return paths and optional/
error returns. Reordering declarations/calls must not change inferred signatures.
Unknowns must never silently become machine integers. Type/effect/ownership
diagnostics and explicit views must show the same resolved signature.

## JSON: build on the existing bounded document API

**Observed.** `std/json.zag::{json_parse_value_bounded,json_value_at,
json_value_child,json_object_find,json_stringify_value_bounded}` already handle
typed document traversal and encoding. `json_document_free` frees owned decoded
text and document storage; `json_encode_result_free` frees encoded output.
Parsing can return an unsuccessful partially built document, so error paths also
need cleanup. `docs/ZAGSCRIPT_GUIDE.md` explicitly describes ordinary `std:json`
and the lack of implicit bindings. Input/value/depth limits are not equivalent
to charging all heap storage against the Script context.

**Integration.** Add a thin ordinary-module facade and optional root bindings via
`parse.zag::script_bind_expr`, preserving user declaration precedence. Specify
Result/optional behavior, missing versus null versus wrong-type access, numeric
conversion/range rules, duplicate-key policy, and document/view lifetime. Reuse
the existing parser and encoder; avoid a second JSON implementation. For typed
record decoding, generate or call checked field conversions after record identity
is settled. Either integrate parser/encoder allocations into Script accounting or
retain explicit ownership and disclose that boundary; merely copying final output
into an arena does not account for temporary document storage.

**Acceptance gates.** Keep the existing JSON/CSV suites as regressions, then add
compact convenience cases for nested objects/arrays, empty values, missing/null,
wrong kinds, duplicate keys, integer overflow, preserved number spelling, escaped
Unicode, invalid UTF-8/surrogates, trailing data and depth/value/byte limits.
Exercise cleanup on parse failure, encode failure and early return, and reject or
prevent use of a view after its document is released. Round-trip tests must state
whether they compare semantic values or exact bytes; JSON encoding is not assumed
to canonicalize source spelling.

## `auto`: specification, correctness and optimization are separate obligations

**Correction to the masterplan example.** A function named `dot` containing only
`auto optimize(runtime)` does not specify a dot product. Its name, parameter and
return types, and speed objective cannot determine required behavior. An auto
region needs a reference computation or a formal relation with sufficient
preconditions/postconditions, effects, termination/error behavior and numeric
semantics. A floating-point dot contract must also define length mismatch, order
of accumulation, rounding, NaNs and permitted reassociation. Do not infer these
from a blank body or a suggestive name.

**Observed integration footholds, not an auto engine.**

- `ast.zag::Node` / `FnDecl` and `parse.zag::{parse_fn,parse_stmt}` need explicit
  region ownership and contract representation, or a comparably authoritative
  side table; a magic function name is insufficient.
- `typed.zag::zt_check_expressions`, ownership/resource checks, and
  `sema.zag::report_violations` must check both the contract and selected candidate.
  Candidate search must not acquire undeclared effects or weaken lifetime rules.
- `zir.zag::{build_module,verify_module,zir_select_foreground_transform_source_policy}`
  and `zir_contract.zag` provide lowering, structural verification and a scoped
  constant-i32-add transform/certificate vocabulary. Structural IR validity and
  an existing transform certificate are not general semantic equivalence proofs.
- `semantic_manifest_publish.zag::semantic_manifest_publish` is a reporting
  integration point; `native/znc.zag::{znc_view,znc_explicit_symbol}` and
  `script_projection.zag::script_projection` are exposure/projection integration
  points. They need contract/candidate identity and ownership-transfer evidence,
  not just generated source text.

**First domain and gates.** Start with a finite, pure fixed-width integer domain
with declared overflow/shift/division semantics, explicit reference expressions,
no pointers or external effects, and a bounded candidate grammar. Verify each
admitted rewrite or candidate against that contract with a sound checker under
stated assumptions. Unsupported constructs, incomplete IR coverage, timeouts and
unknown verifier results must reject synthesis or use the checked reference
implementation; they must not produce a verified label. Test deliberately wrong
candidates, tampered certificates, violated preconditions and undeclared effects.

**Evidence language.** Differential and property tests supply evidence for sampled
inputs, not a proof for all inputs. Exhaustive checks establish only the explicitly
finite domain actually exhausted, subject to the checker/model assumptions.
If an experimental mode accepts test-only candidates, label them unproven and keep
them outside a proof-required acceptance gate. A matching checksum establishes
identity, not correctness.

**Optimization language.** A global optimum is not generally provable over all
programs, machines or workloads. A proven optimum requires a specified candidate
space, objective/cost model and constraints plus complete search or a valid bound
with a matching candidate. Even exhaustive enumeration with noisy timings gives
measured best among those candidates under that measurement profile, not a
mathematical runtime optimum. Report “best measured candidate” or “best known”
when that is what the evidence supports. Multi-objective priorities and tradeoffs
must be explicit; energy requires an actual measurement/model contract.

**Reproducibility and exposure gates.** Bind source/contract, compiler image,
target features, candidate grammar, constraints, verifier version/results and
measurement inputs to the selection record. Separate deterministic replay of a
recorded choice from rerunning noisy benchmarks. Define tie-breaking, confidence
and invalidation rules. Rebuild a pinned choice identically; changed contracts or
target assumptions invalidate stale evidence. Explicit output must be ordinary
compilable Zag; editing/promoting it transfers implementation ownership and must
not silently retain proof labels for the old candidate.

## Validation handoff

This was a source-only documentation audit. This audit worker ran no compiler/
runtime suites or full bootstrap; it does not independently assert that a binary
matches this dirty source tree.
Only this new document was written. Its whitespace and referenced paths/functions
were checked after writing. The acceptance cases above are required future work,
not tests claimed to exist or pass.

The integration owner supplied these actual current validation results during
the audit (not rerun by this worker):

| Check | Reported result |
| --- | --- |
| Current release matrix | supported=7, partial=20, unavailable=5; exit 1 |
| `python_shape`, current native compiler | Passed |
| `script_cli`, current native compiler | Passed |
| `script_cst31`, current native compiler | Passed |

The release matrix is not passing. The three successful baselines establish
their tested scope, not completion of interpolation, maps, records, JSON
convenience, function inference or auto synthesis. No category breakdown or
failure cause beyond these supplied counts/statuses is inferred here.

For implementation owners, focused existing entry points are
`tests/run_script_ergonomics.sh`, `tests/run_script_python_shape.sh`,
`tests/run_collections_unicode.sh`, `tests/run_script_json.sh`,
`tests/run_script_json_csv.sh`, `tests/run_script_runtime_integration.sh`,
`tests/run_script_projection.sh`, `tests/run_zagscript_symbol_view.sh`, and
`tests/run_zir_authority.sh`. Select relevant suites and add the missing positive,
negative, accounting and exposure cases described above. The ergonomics unit test
currently checks five text-normalization cases, not the feature set in this audit.
Native execution must use an identified compiler built from the integrated source
and each target/mode actually claimed. The parent integration owner handles the
compiler bootstrap/fixpoint and release gates; this audit does not broaden support.
