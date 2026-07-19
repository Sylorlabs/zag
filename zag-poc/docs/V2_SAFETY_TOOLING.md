# Zag v2 safety tooling (draft)

Status: specification only.  The current compiler rejects the proposed v2
driver options rather than silently accepting them.  No sanitizer is claimed
until this document has implementation, negative tests, and runtime evidence.

## Modes

- `--safety=checked` preserves language traps and enables available dynamic
  checks for raw-pointer alignment/bounds/lifetime, invalid shifts, division by
  zero, and invalid tags.
- `--safety=release` retains defined-language traps while allowing proven
  redundant checks to be removed.  It never converts a safe operation into
  ambient undefined behavior.
- `--sanitize=memory` adds allocator metadata, freed-region poisoning/guard
  pages where practical, double/invalid-free detection, red zones, and a leak
  report at process exit.
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
