# Zag Script hardening

Status: conservative declaration-aware preview, 2026-07-18.

Hardening is the path from concise Zag Script to reviewable explicit
Zag. It is not a rewrite into another language. `znc harden` can currently
preserve a leading block of imports/declarations and move following executable
statements into an explicit `fn main() i32`. With `--output`
it writes a separate candidate and never overwrites the source.
`--format json` emits preview status, the candidate when it is not written to a
separate output, assumptions, parity tests, and unsupported transformations as
a machine-readable report.

`--apply` is fail-closed: it requires `--test-command`, verifies that the source
still matches the analyzed snapshot, checks the generated strict candidate,
creates `<source>.harden.bak`, and restores the original bytes automatically if
the parity command fails. An existing rollback file is never overwritten.

## Required hardening output

The current preview identifies generated entry behavior, selected defaults,
unsupported conversions, assumptions, and parity tests. A complete preview must
also identify inferred types and effects, allocator and capability policies, hidden allocation/copy
decisions, unresolved choices, assumptions, and parity tests. It must distinguish
facts as proven, derived, measured, estimated, or unknown. Unsupported conversion
must remain an explicit unsupported item rather than generated code presented as
equivalent.

`--output` writes a separate formatted `.zag` file. Source is never
overwritten by default. `--apply` requires an unchanged source snapshot,
an explicit `--test-command`, and a rollback copy. The candidate is checked
before replacement and the original is restored if the parity command fails.

## Current boundary

Leading imports and declarations are retained at file scope. A declaration
appearing after executable top-level statements is rejected because moving it
could change initialization order. The candidate deliberately retains ordinary
native primitive calls selected by the
script prelude; allocator and capability policy synthesis remain explicit
unsupported report items. The report lists parity tests still required.

`check --strict` rejects the generated entry point and implicit allocator, and
adds focused filesystem and script-context allocation diagnostics when present.
`--analyze-strict` is separate and only controls analyzer findings.
