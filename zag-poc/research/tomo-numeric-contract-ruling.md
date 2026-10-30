# Numeric contract ruling

**UNCOMPILED / UNEXECUTED.** Static source review of `f8b287bad32d4f93d272c270cff772e59b858515`, not a test result.

## Ruling

**(b) Deliberate v1 implementation extension owned by the backend.** `selfhost/typed.zag` explicitly describes existing v1 numeric representation conversions as backend-owned and accepts numeric pairs without an edition parameter; `selfhost/native/ncodegen.zag` explicitly preserves backend widening and narrowing. The extension boundary is the implementation's existing v1 extensions under the default 2026 edition, not a v2/2027 feature; precise representation rules belong to the backend pending migration and differential tests. Crucially, this is an implementation-intent ruling, not a claim the extension is in the frozen normative core: `docs/V1_LANGUAGE_SPEC.md` explicitly excludes implicit conversion between different named numeric types from v1. A program relying on this extension is therefore outside that published core; the conflicting wording must not be presented as proof of core conformance. Neither the backend behavior in every context nor conformance was executed here.

## Evidence paths and quotations

* `zag-poc/docs/V1_LANGUAGE_SPEC.md`: “Status: frozen v1 core, 2026-06-29.” “This document is the normative boundary for Zag v1.” “Implicit conversion between different named numeric types is not part of v1.”
* `zag-poc/selfhost/v2_edition.zag`: the default project edition is `2026` absent a valid project edition; selected v2 syntax requires `2027`. This gate does not make numeric conversion a 2027-only feature.
* `zag-poc/selfhost/typed.zag`, `zt_compatible(expected: []u8, actual: ZTExpr) i32`: accepts identical types, numeric literals for numeric expectations and numeric-to-numeric pairs, with no edition argument. Its comment says: “Existing v1 extensions permit word-scalar and specialized-numeric representation conversions. Their precise rules remain backend-owned until the numeric typed-ZIR slice migrates them with differential tests.” Callers include typed locals, assignments, returns, arguments, record fields and map values.
* `zag-poc/selfhost/native/ncodegen.zag`, `cg_types_compatible`: “Known scalar numeric types retain the backend's existing widening and narrowing behavior.” For scalar local initialization and simple assignment, `cg_lower_stmt` calls `cg_emit_norm_scalar_for_ty`; i32 normalization sign-extends the low 32 bits. Reviewed scalar call and return paths did not show equivalent normalization, so do not extrapolate that detail to every conversion or backend.

## Concrete mixed-width sites

`zag-poc/tests/reference_apps/concurrent_file_indexer/main.zag` declares `IndexResult.bytes_read: i32` and `fn index_print_i64(value: i64, scratch: *u8) void`, then calls `index_print_i64(results[i].bytes_read, print_scratch);` without a cast: an actual i32-to-i64 argument site in source. The same file declares `let total_bytes: i64 = 0;` and later assigns `total_bytes = total_bytes + results[i].bytes_read;`, a mixed-width expression; its precise typed expression semantics have not been independently checked. No implicit i64-to-i32 site was confirmed in the inspected source/search results; this is not an exhaustive absence claim because GitHub's index omits some large files.

## Reproduction handoff — NOT RUN

In a disposable checkout, inspect source and resolve additional candidate sites before drawing conclusions about their types:

```sh
git checkout f8b287bad32d4f93d272c270cff772e59b858515
cd zag-poc
rg -n 'zt_compatible|Existing v1 extensions' selfhost/typed.zag
rg -n 'cg_types_compatible|cg_emit_norm_scalar_for_ty|Known scalar numeric' selfhost/native/ncodegen.zag
rg -n 'bytes_read|index_print_i64|total_bytes' tests/reference_apps/concurrent_file_indexer/main.zag
rg -n --glob '*.zag' ':[[:space:]]*i32|:[[:space:]]*i64' selfhost programs examples tests
```

Textual hits require type-flow review. Capture compiler hash, environment, command output and exit status for any later authorized test. No tests or compiler patch are claimed here.
