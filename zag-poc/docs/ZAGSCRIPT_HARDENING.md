# Zag Script hardening

Status: conservative statement-only preview, 2026-07-18.

Hardening is the planned path from concise Zag Script to reviewable explicit
Zag. It is not a rewrite into another language. `znc harden` can currently
expand a statement-only script into an explicit `fn main() i32`. With `--output`
it writes a separate candidate and never overwrites the source.

## Required hardening output

When implemented, a preview must identify the generated entry behavior, inferred
types and effects, allocator and capability policies, hidden allocation/copy
decisions, unresolved choices, assumptions, and parity tests. It must distinguish
facts as proven, derived, measured, estimated, or unknown. Unsupported conversion
must remain an explicit unsupported item rather than generated code presented as
equivalent.

`--output` will write a separate formatted `.zag` file. Source must never be
overwritten by default. A future `--apply` requires a clean source snapshot,
rollback material, and successful configured parity tests.

## Current boundary

Imports and declarations mixed with executable top-level statements are rejected
by automatic hardening because placement cannot yet be preserved safely. The
candidate deliberately retains ordinary native primitive calls selected by the
script prelude; allocator and capability policy synthesis remain explicit
unsupported report items. The report lists parity tests still required.

`check --strict` rejects the generated entry point and implicit allocator, and
adds focused filesystem and script-context allocation diagnostics when present.
`--analyze-strict` is separate and only controls analyzer findings.
