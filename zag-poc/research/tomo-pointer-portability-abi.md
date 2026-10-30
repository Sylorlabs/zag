# Pointer portability and ABI note

**UNCOMPILED / UNEXECUTED.** Static inspection only; no local compiler, tests, benchmarks or native execution. Source base: `f8b287bad32d4f93d272c270cff772e59b858515`. This research note changes neither compiler nor frozen studies.

## Contract and observed implementation

- `zag-poc/docs/V1_LANGUAGE_SPEC.md`: “Pointer arithmetic is unsupported.” Do not treat pointer addition as portable element arithmetic or a guaranteed source-language ABI.
- `zag-poc/selfhost/native/ncodegen.zag`, x86 `cg_lower_bin`, lowers ordinary `+` using `i_add(R_RAX(), R_RCX())`, without pointer-specific scaling in that branch. This does not establish that type checking accepts every pointer addition or that the behavior is guaranteed.
- In the same x86 file, `cg_lower_addr` uses `cg_elem_stride` and `cg_emit_raw_index_address` for pointer indexing. The latter multiplies the index by the stride when it is not 1, then adds it to the base. The full stride calculation and native behavior were not independently verified.
- AArch64 was not verified. Do not extrapolate x86 behavior across targets or claim an ABI guarantee from a codegen branch.

## Safe use

Use supported indexing on an appropriately typed pointer, slice or array rather than relying on `p + k` for element scaling. Ensure the object remains alive, the pointer is valid and aligned, and the index is within the valid object bounds; verify ABI requirements at foreign-function boundaries. Indexing does not establish these preconditions. This is a portability warning, **not a bug claim**.

## Static inspection commands (not run)

```sh
git checkout f8b287bad32d4f93d272c270cff772e59b858515
rg -n 'Pointer arithmetic is unsupported' zag-poc/docs/V1_LANGUAGE_SPEC.md
rg -n 'cg_lower_bin|cg_lower_addr|cg_elem_stride|cg_emit_raw_index_address|i_add\(R_RAX\(\), R_RCX\(\)\)' zag-poc/selfhost/native/ncodegen.zag
```

These inspect source only. They are not execution evidence; target-specific validation needs separate type-checking and native tests.
