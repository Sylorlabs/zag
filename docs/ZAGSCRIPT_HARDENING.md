# Zag Script hardening

Status: conservative explicit-runtime candidate preview, 2026-07-24.

Hardening is the path from concise Zag Script to reviewable explicit
Zag. It is not a rewrite into another language. `znc harden` can currently
preserve a leading block of imports/declarations and move following executable
statements into an explicit strict-Zag body and `fn main() i32`. The candidate
makes the Script memory limit, selected allocator name and stable policy id,
filesystem/process capability policy, packed execution policy, context
initialization/shutdown, and status-return boundary visible.
With `--output` it writes a separate candidate and never overwrites the source.
`--format json` emits preview status, `candidate_compilable`, the allocator
policy with its explicit-or-derived basis and reclamation behavior, the
candidate when it is not written to a separate output, assumptions, parity
tests, and unsupported transformations as a machine-readable report.

`--apply` is fail-closed: it requires `--test-command`, verifies that the source
still matches the analyzed snapshot, checks the generated strict candidate,
creates `<source>.harden.bak`, and restores the original bytes automatically if
the parity command fails. An existing rollback file is never overwritten.

The maintained hardenable example deliberately avoids compiler-bound prelude
calls:

```sh
./znc harden examples/script_harden.zag
./znc harden examples/script_harden.zag --format json
./znc harden examples/script_harden.zag --output /tmp/script_hardened.zag
```

## Required hardening output

The current preview identifies generated entry behavior, selected defaults,
unsupported conversions, assumptions, and parity tests. A complete preview must
also identify inferred types and effects, allocator and capability policies, hidden allocation/copy
decisions, unresolved choices, assumptions, and parity tests. It must distinguish
facts as proven, derived, measured, estimated, or unknown. Unsupported conversion
must remain an explicit unsupported item rather than generated code presented as
equivalent.

`--output` publishes a separate `.zag` file through a sibling
`<output>.harden.tmp` rename; an already-present temporary is refused rather
than overwritten. Source is never overwritten by default, and naming the
source itself as `--output` is rejected. `--apply` requires an unchanged source snapshot,
an explicit `--test-command`, and a rollback copy. The candidate is checked
before replacement and the original is restored if the parity command fails.

## Current boundary

Leading imports and declarations are retained at file scope. A declaration
appearing after executable top-level statements is rejected because moving it
could change initialization order. The generated private wrapper prefix is
also reserved; a source collision is rejected rather than renamed.

This first strict candidate deliberately supports only a root Script body with
no compiler-bound Script prelude call and no propagated root `try` operation.
Those are proven from the compiler-bound root AST, not guessed from a second
parser. A candidate with no such operation receives an explicit identity status
boundary because preserving an integer status is provable. A body using
`read_file`, output, Script collections, process helpers, path helpers,
Script allocation, or a propagated error is reported as a structured
unsupported item. No candidate or output file is produced for that case, and
`--apply` refuses it rather than claiming equivalence.

Every supported candidate is checked by the compiler before it is printed,
published, or applied. The report lists parity tests still required; passing
the candidate check alone does not establish behavioral parity.

`check --strict` rejects the generated entry point and an implicit allocator.
When `--script-allocator` selected a supported explicit Script policy, strict
checking reports that choice as resolved but still rejects promotion until the
Script-only contract is expanded to an ordinary strict-Zag allocator. It also
adds focused filesystem and script-context allocation diagnostics when present.
`--analyze-strict` is separate and only controls analyzer findings.
