# Zag Script hardening

Status: contract and current limitation, 2026-07-18.

Hardening is the planned path from concise Zag Script to reviewable explicit
Zag. It is not a rewrite into another language. The current compiler does not
implement the `znc harden` command, generated candidate files, patches, or apply
mode.

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

## What can be done today

Developers can manually replace root statements with an explicit `fn main`,
remove `script;`, retain source order, and use ordinary explicit APIs. This is a
manual refactor, not compiler-verified hardening. There is currently no report
proving behavioral parity, no automatic capability expansion, and no strict
promotion gate.

Do not use `--analyze-strict` as a substitute for the planned `check --strict`.
The former controls the existing analyzer; it does not resolve or reject the
full Zag Script convenience set.

