# Zag Script hardening

Status: conservative explicit-runtime candidate preview with a bounded,
prepared-evidence reversible ledger. Promotion, exact unchanged unexpansion,
and multiple uniquely anchored source-edit projection are release-tested; the
general structural/equivalence contract remains unavailable.

Hardening is the path from concise Zag Script to reviewable explicit
Zag. It is not a rewrite into another language. `znc harden` can currently
preserve a leading block of imports/declarations and move following executable
statements into an explicit strict-Zag body and `fn main() i32`. The candidate
makes the Script memory limit, selected allocator name and stable policy id,
filesystem/process capability policy, packed execution policy, context
initialization/shutdown, and status-return boundary visible.

The public reversible-view spelling is now `znc expand <file> --to explicit`.
`harden` remains a compatibility alias for this conservative expansion for one
edition cycle. `znc promote` adds the stronger human-owned-source contract: it
requires a parity command and publishes `<output>.zsledger`, which contains
checksummed exact compact and baseline-derived bytes and does not depend on
daemon caches. `znc unexpand` restores unchanged promotions exactly. For an
edited promotion it performs a structural three-way projection when the edited
baseline line/context occurs exactly once in compact source. Localized body
replacement, insertion, and deletion are supported. Generated-only edits,
duplicate compact contexts, missing baselines, and non-aligning edits fail with
derived-byte conflict bounds in the complete baseline coordinate space rather
than guessing or discarding work. Multi-region conflicts retain the original
derived-file offsets even when the failing region was analyzed as a slice.
Promotion output and its sidecar are create-only and use
`renameat2(RENAME_NOREPLACE)`. If any failure occurs after the parity command
has started, no ledger is published and the output is deliberately left in
place as ownership-uncertain: the parity command may have replaced its inode,
so deleting it by path would risk deleting foreign data. The diagnostic tells
the user to inspect or remove that output explicitly.

Current release boundary: the bounded v2 ledger codec is installed and has a
focused 14-check round trip, including v1 read compatibility and checksum-valid
missing, duplicate, renumbered, and noncontiguous section rejection plus
semantic-manifest hash-mismatch rejection. The source-integrated adapter derives
its semantic-manifest checksum and graph identity from the same prepared unit.
The view gate exercises promotion, exact unchanged restoration, bounded
multi-edit projection, cache-deletion recovery, and fail-closed conflicts. This
is not a claim of unrestricted structural editing or formal source/native
equivalence; unsupported/generated-only/ambiguous edits remain rejected.
With `--output` it writes a separate candidate and never overwrites the source.
`--format json` emits preview status, `candidate_compilable`, the allocator
policy with its explicit-or-derived basis and reclamation behavior, the
candidate when it is not written to a separate output, assumptions, parity
tests, and unsupported transformations as a machine-readable report.

The legacy `--apply` mode is removed and fails before daemon setup, source
loading, candidate publication, or parity-command execution. `harden` never
replaces compact source and never creates a rollback copy. A separate
`--output` is a compiler-derived expansion artifact without human-owned
provenance. Use `znc promote <source> --to explicit --output <path>
--test-command <command>` when the expanded file is intended to become
human-owned source; successful promotion is the only path that publishes its
portable `.zsledger` provenance.

The maintained hardenable example is intentionally small, but compiler-bound
prelude calls are now materialized from the already-bound AST when their
standard-library imports and context ABI are bounded:

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

`--output` publishes a separate `.zag` file through a per-process sibling
staging file opened with `O_EXCL|O_NOFOLLOW`, followed by
`renameat2(RENAME_NOREPLACE)`; neither a pre-existing staging entry nor a final
entry is overwritten. Source is never overwritten by default, and naming the
source itself as `--output` is rejected. `--apply` is not an accepted mode;
the diagnostic points to provenance-backed `promote` instead.

## Current boundary

Leading imports and declarations are retained at file scope. A declaration
appearing after executable top-level statements is rejected because moving it
could change initialization order, with one bounded exception: a plain trailing
`const` whose initializer is a decimal integer literal, `true`/`false`, or a
compiler-proven pure scalar expression containing only integer literals and
`+`, `-`, or `*`, or literal booleans joined by `&&`/`||`, unary `!`, or
`==`/`!=`, is compile-time-only and may be moved after strict validation.
Calls, names, strings, unsupported operators, and duplicate assignments remain
rejected. The generated private wrapper prefix is also reserved; a source
collision is rejected rather than renamed.

This strict candidate supports a root Script body, including a propagated root
`try` operation. Propagated errors are materialized through an explicit strict
`catch`/report boundary that converts the uncaught code to a nonzero status.
Compiler-bound `read_file`, output, Script collections,
process helpers, path helpers, and Script allocation are rendered from the
bound AST, with explicit standard-library imports and an explicit context
parameter. Those transformations are still a conservative derivation, not a
formal equivalence proof. Declaration-order changes, reserved-name collisions,
and unsupported compiler-bound operations remain structured unsupported items
and produce no candidate.
The bounded process convenience is also supported from an explicit edition-2026
root when the generated strict candidate passes ordinary compiler validation.
The imported `std:process` implementation keeps its own unsafe/library
authority; the root edition is not used as a proxy for that implementation.
Arbitrary ownership-sensitive library equivalence remains outside this bounded
expansion contract and still fails closed.

Every supported candidate is checked by the compiler before it is printed,
or published as a separate expansion artifact. The report lists parity tests still required; passing
the candidate check alone does not establish behavioral parity.

`check --strict` rejects the generated entry point and an implicit allocator.
When `--script-allocator` selected a supported explicit Script policy, strict
checking reports that choice as resolved but still rejects promotion until the
Script-only contract is expanded to an ordinary strict-Zag allocator. It also
adds focused filesystem and script-context allocation diagnostics when present.
`--analyze-strict` is separate and only controls analyzer findings.
