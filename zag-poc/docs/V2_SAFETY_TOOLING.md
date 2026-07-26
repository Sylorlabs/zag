# Zag v2 safety tooling (draft)

Status: `--safety=checked` and the partial `--sanitize=memory` mode are
implemented for edition-2027 native x86-64 output. They trap null and
misaligned raw-pointer dereferences/indexes, and check bounds and freed-state
for ordinary allocator regions tracked by the native runtime. Memory sanitizer
mode additionally fails process exit when the ordinary allocator's live-capacity
witness is nonzero. Both modes are rejected on every other target rather than
silently downgrading. Other sanitizer modes remain rejected.

## Modes

- `--safety=checked` preserves language traps and currently enables dynamic
  raw-pointer null/alignment checks plus bounds and freed-region checks for
  up to 3,072 ordinary `_zag_malloc`/`new`/`_zag_realloc` allocations on native x86-64.
  The table records allocator capacity (small blocks are class-rounded), so an
  access whose root and final address stay within that tracked live region is
  allowed; a one-past or wider access traps before the load/store. A tracked
  freed region traps before access until that exact address is reissued for a
  new allocation. Checked `_zag_free` and `_zag_realloc` additionally require
  an exact live allocation base before reading allocator headers, so a forged
  interior pointer traps rather than corrupting a small-block free list. Stack,
  static and foreign regions are intentionally not rejected merely because
  they are untracked. `zalloc` and cache-aligned raw-slice mappings now enter
  the same bounded registry and retire on their paired free. This is
  bounded runtime instrumentation, not universal pointer provenance: forged
  pointers, address reuse (ABA), and untracked allocator families remain unsafe
  programmer responsibility. Invalid shifts, division by zero, and invalid
  tags remain separate implementation work.
- `--safety=release` retains defined-language traps while allowing proven
  redundant checks to be removed.  It never converts a safe operation into
  ambient undefined behavior.
- `--sanitize=memory` currently enables the same bounded ordinary-allocation
  provenance checks as `--safety=checked` and fails process exit on a nonzero
  ordinary-allocation live witness. It does not yet provide red zones,
  poisoning, guard pages, allocation-site reports, custom-allocator tracking,
  or ABA-resistant identity.
- `--sanitize=undefined` instruments checked integer conversion/overflow,
  shifts, null/misalignment, invalid enum/union tags, and other specified
  dynamic preconditions.
- `--sanitize=thread` records synchronization and reports detected conflicting
  non-atomic accesses.  It is diagnostic tooling, not a proof of race freedom.

These are selected build modes, not source-level promises.  They compose with
the effect system: instrumentation itself must not make an `@realtime` or
`@noalloc` program falsely appear compliant.  A build may reject a requested
sanitizer on an unsupported target, but it may not downgrade it silently.

## Diagnostics and reporting

Each trap/report contains source location where known, function, violated rule,
relevant type/address/size, and the allocation or synchronization witness when
available.  The debug allocator records allocation and free sites.  Sanitizer
reports are nonzero process outcomes in test mode.  Guarded allocations and
thread instrumentation are explicitly unsuitable for hard real-time use.

## Exit criteria

The release gate requires execution tests for OOB, null, misalignment, invalid
shift, divide-by-zero, use-after-free where detectable, double/invalid-free,
leaks, invalid tags, and a deliberate race report before any mode is marked
supported.  Current status remains unsupported.
