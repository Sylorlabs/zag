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
  programmer responsibility. The checked `SystemAllocator` handle boundary is
  narrower and separately records a generation, so copied handles cannot be
  reused after the same native address is reissued. Invalid shifts, division by zero, and invalid
  tags remain separate implementation work.
- `--safety=release` is not implemented and is rejected by the v2 option gate;
  no release-mode check-elision or safety contract exists.
- `--sanitize=memory` currently enables the same bounded ordinary-allocation
  provenance checks as `--safety=checked` and fails process exit on a nonzero
  ordinary-allocation live witness. It does not yet provide red zones,
  poisoning, guard pages, allocation-site reports, or custom-allocator
  tracking. Its SystemAllocator-handle checks retain the same generation
  validation as checked mode; that does not make raw-pointer ABA generally safe.
- `--sanitize=undefined` is not implemented and is rejected; it does not
  instrument integer conversion/overflow, shifts, tags, or other preconditions.
- `--sanitize=thread` is not implemented and is rejected; it records no
  synchronization or conflicting accesses.

These are selected build modes, not source-level promises.  They compose with
the effect system: instrumentation itself must not make an `@realtime` or
`@noalloc` program falsely appear compliant.  A build may reject a requested
sanitizer on an unsupported target, but it may not downgrade it silently.

## Diagnostics and reporting

The current native reports are fixed diagnostic strings and a nonzero process
outcome. Checked raw-access traps name null, alignment, bounds, or retired
allocator state; the memory-sanitizer exit trap says only that live ordinary
allocation capacity remains. They do **not** contain source locations,
function names, addresses, sizes, allocation/free sites, redzone bytes, or a
backtrace. The allocator telemetry observers can expose aggregate live/peak
capacity to a program, but are not allocation-site reporting. Thread
instrumentation and guarded allocations do not exist in this implementation.
Known source-level owner leaks are normally rejected earlier by the edition-2027
typed ownership pass, so the sanitizer's exit witness is a backstop for
lowered/runtime paths rather than a replacement for that static rule; it does
not yet have an independent source-level leak execution regression.

## Exit criteria

The release gate requires execution tests for OOB, null, misalignment, invalid
shift, divide-by-zero, use-after-free where detectable, double/invalid-free,
leaks, invalid tags, and a deliberate race report before any mode is marked
supported.  Current status remains unsupported.
