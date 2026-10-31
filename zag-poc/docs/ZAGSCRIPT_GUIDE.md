# Zag Script guide

Zag Script is Zag's built-in low-friction profile. It provides concise safe
defaults for short programs and experiments while preserving a direct path into
explicit native Zag through inspection and hardening. “Safe defaults” here
means bounded, documented, and fail-closed behavior at the implemented Script
boundary. It does not mean that Zag has a complete ownership or borrowing
system; the exact gaps are listed below and in `ZAGSCRIPT_SEMANTICS.md`.

## Current implementation status

The current foundation recognizes `script;`, records the script profile in the
ordinary module AST, accepts executable root statements, and lowers the selected
root body to a compiler-owned native entry point. Statements run in source order.
A script module imported by a strict root contributes declarations without
running its script body. Duplicate profile declarations and a script containing
a user `main` are diagnosed.

The implemented profile includes a managed context, a bounded default arena,
an explicit bounded-heap alternative, uncaught-error wrapper, `znc script`,
four progressive `view` levels, conservative explicit `expand`/`promote`,
and the bounded portable exact `unexpand` contract, plus `check --strict`.
Both activation forms
are supported:

- `script;` in an ordinary `.zag` file;
- `znc script program.zag`; or
- the optional `.zs` suffix.

`znc harden` remains a compatibility alias for explicit expansion during the
current edition cycle and is deliberately conservative. It renders the
already-bound AST into a reviewable strict-Zag candidate with explicit
memory/capability policy constants, context init/shutdown, and a status
boundary. A root propagated `try` is materialized as an explicit `catch` and
uncaught-error report boundary; compiler-bound Script conveniences are
materialized with explicit standard-library imports and an explicit context
parameter. Unsupported cases remain structured diagnostics rather than guessed
rewrites. By default hardening only prints a preview; `--output`
uses a create-only atomic sibling-temporary publish for a separate derived
artifact. The removed legacy `--apply` mode fails before source loading or any
publication. Use provenance-backed `promote` for human-owned expanded source. See
`ZAGSCRIPT_HARDENING.md` for the exact supported boundary.

The explicit renderer also has one ownership-aware captured-closure envelope:
one or more root-level immutable `i32` value captures with a flat, pure scalar
body are reconstructed as a closure literal in the derived source. The generated
body evaluates its result before `close`, so the heap environment is reclaimed
on every normal return. Pointer captures, aggregate captures, nested function
value captures, branch/error-sensitive bodies, and mutable reassignment remain
fail-closed until the general closure lifetime contract exists.

All three select the same `ModuleProfile.script`, parser, AST, semantic
analysis, runtime, and native backend. `.zs` is a convenience, not a second
language or a claim that arbitrary Python files are source-compatible. The
current `.zs` frontend preserves compact bytes with shared-lexer token spans,
explicit layout events, and bounded line-oriented origin records through
Script normalization; the line-oriented normalizer is not yet the full
indentation/recovery grammar authority of the regular parser. Normalized
output has generated-range coverage back to the available compact origins.
Parser nodes retain stable origin IDs and project through root and imported
compact sources.
Byte-identical ranges are exact; indentation rewrites use a sound enclosing
compact range, and synthetic wrappers remain explicitly unlocated rather than
guessed. The normalizer owns only the bounded layout/header projection, while
the shared lexer/parser owns expression and declaration semantics. Top-level
assignment and the bounded `values.append(...)` convenience also consume the
enclosing CST's shared-token ranges; the legacy line-local scanners remain only
as focused test or compatibility helpers. Recovery
records retain exact byte spans and source lines for invalid UTF-8/NUL bytes,
unterminated literals, mixed indentation, and inconsistent dedents. Broader
Unicode/layout recovery remains incomplete, so malformed or ambiguous layouts
fail closed.

The JSON form of `explain` embeds the compiler's checksummed semantic manifest
and its explicit `detail_level`. A full manifest includes declaration
signatures, layouts, call edges, function effects, and per-expression
`expr_fact` witnesses. Types come from the shared typed frontend; effects come
from sema's context-sensitive expression walk. Calls, binary and unary forms,
casts, slice indexing/slicing, supported struct fields, assignments, returns,
and nested control-flow conditions are recursively reported. A form outside
typed authority is tagged `type_basis=unknown`, never guessed.

For a large merged Script/prelude unit, `detail_level=compact` preserves the
exact checksum-bound declaration/module/call/type/layout/import graph, raw
module hashes, and public/effect/layout identities while omitting verbose
expression/value/copy and local buffer-lifetime witnesses. Text and JSON mark
those witnesses unavailable; their absence is never reported as proof that no
copy, unknown value, or reusable lifetime exists.

For the compiler-bound calls in the selected root Script body, `explain` also
has an `implicit_operations` report. It names each recognized allocation/copy
operation, says whether allocation and copy are zero, conditional, or use the
Script context, and separates a proven fixed byte fact from a dynamic
`unknown`. Each parsed call is bound to its `NodeOrigin` with module, line,
column, byte span, stable id, and an `exact` bit; compact `.zs` projections are
reported as `projected-origin`. Synthetic or malformed origins remain
`unavailable/unknown` rather than receiving a guessed location. The report is
capped at 64 entries and excludes imported strict-library implementation
details.

```sh
./znc examples/script_hello.zag -o /tmp/script_hello
/tmp/script_hello
```

After compiler-source changes, rebuild the self-hosted compiler through the
documented native bootstrap before testing the new syntax. The current
committed `znc` is a native fixed-point product; a future source change makes
that product stale until bootstrap and empty-PATH reproducibility pass again.
No external compiler, assembler, or linker is part of the supported path.

## Command reference

The profile declaration and command form reach the same compilation path:

```sh
./znc script app.zag
./znc script app.zag --run
./znc script app.zag -o app
./znc app.zag -o app --run
```

A source containing `script;` activates Script lowering in the direct build
form. Inspection and promotion commands never require the daemon:

```sh
./znc explain app.zag
./znc explain app.zag --format text
./znc explain app.zag --format json
./znc harden app.zag
./znc harden app.zag --format json
./znc harden app.zag --output app.hardened.zag
./znc view app.zag --level simple
./znc view app.zag --level explained
./znc view app.zag --level explicit
./znc view app.zag --level native
./znc expand app.zag --to explicit --output app.derived.zag
./znc expand app.zag --to simple --output app.simple.zag
./znc expand app.zag --to native --output app.native.txt
./znc promote app.zag --to explicit --output app.promoted.zag \
    --test-command 'test -s app.promoted.zag'
./znc unexpand app.promoted.zag --output app.restored.zag
./znc check app.zag
./znc check app.zag --strict
```

`view` and output-less `expand` do not modify source. `promote` is the path for
human-owned expanded source: it checks the explicit candidate, requires a
caller-selected parity command, and publishes a portable `.zsledger` sidecar.
All view/expand levels acquire the root through the same 8 MiB bounded,
no-symlink foreground reader; missing, symlinked, replaced, or oversized roots
fail before candidate rendering. Publication separately revalidates the full
prepared module/resource snapshot.
The current JSON fields `candidate_checked=true` and
`candidate_compilable=true` both mean that the rendered source passed the
foreground syntax/type/effect/analyzer gate. They do not by themselves certify
backend lowering or ELF emission. Focused release fixtures therefore compile
and execute their generated candidates separately; arbitrary-candidate native
admission remains a partial capability.
Both human-owned paths are create-only. A failure after parity starts publishes
no ledger and leaves the output in place as ownership-uncertain, because the
parity command may have replaced its inode and a path-only rollback could delete
foreign data.

`expand --to simple`, `expand --to explained`, and `expand --to native --output`
are read-only, create-only projections with no ledger: simple output is the
unchanged compact source, explained output is byte-identical to the selected
`view --level explained` report, and native output is the same typed-IR/
instruction report printed by `view --level native`. Existing output paths are
never overwritten.

Current release boundary: the bounded v2 ledger codec is installed and has a
focused round-trip gate, including v1 read compatibility and checksum-valid
missing, duplicate, renumbered, and noncontiguous section rejection plus
semantic-manifest hash-mismatch rejection. The source-integrated adapter binds
the semantic-manifest checksum and graph identity to the same prepared unit;
the release view gate exercises promotion, exact restoration, and bounded
projection. This is not a claim of unrestricted structural editing: supported
projection covers multiple separated uniquely anchored compact edits, while generated-wrapper,
duplicate-context, and non-aligning edits fail closed. The `native` level
renders the versioned `zag-ir-v1` structural contract followed by the selected
artifact instruction stream. Every foreground x86-64 build constructs and
verifies that contract before lowering. Values expose conservative ownership,
alias-region, lifetime, and layout metadata; functions carry effect masks and
compact-source origins with explicit exactness. Raw ZIR records explicit source
types where the frontend has already bound them, but literal widening,
contextual coercions, and untyped inference are not yet a complete semantic
authority. Native x86 lowering admits the checked declared-bool/i32 subset, a
source-proven inferred-i32 literal/arithmetic initializer subset,
source-proven local nullary/one-/two-/three-/four-/five-/six-argument scalar `i32`
calls, and explicitly typed i64 scalar arithmetic/constants/calls plus
source-proven local nullary/one-/two-/three-/four-/five-/six-argument inferred-i64
calls with canonical integer arguments; seven-or-more-argument, contextual, imported, or extern calls, checked-policy
or sanitized artifacts, and broader routes use the checked AST bridge
(`artifact_ir_consumed=0`) and publish incomplete-coverage status until a
width-complete native route is independently verified.
Untyped-local inference remains incomplete rather than general authority:
literal/arithmetic-only i32 initializers and canonical local scalar calls are
independently source-proven, while other argument-bearing or contextual calls,
identifiers and imported/extern calls publish `coverage_complete=0`, a
nonzero `coverage_errors`, and `verified_raw_ast_bridge_incomplete`.
Exact i32/i64 casts and bounded finite integer↔float casts use the direct
checked-ZIR route; NaN, out-of-range, boolean, contextual, and broader cast
semantics remain on the AST bridge until their edge behavior is independently
certified.
The native projection also emits a `zir-contract=` line with the independent
type, effect, ownership, alias, lifetime, layout, origin, and checked-operation
counts; those fields are evidence about the contract checker, not a claim that
unsupported domains have become complete.

The only foreground semantic transforms currently exposed are explicit,
bounded opt-ins: `--foreground-transform const-i32-add-v1`,
`--foreground-transform const-i32-neg-v1`, `--foreground-transform
const-i64-add-v1`, and `--foreground-transform const-bool-cmp-v1`. The i64 form
is limited to canonical, non-overflowing explicitly typed i64 additions. All
four require regular unsanitized
Linux x86-64 Zag, bind the source context and arithmetic policy, and refuse to
emit an artifact when the checked rule does not match. The default build and
every daemon path remain raw/no-transform; these narrow opt-ins do not make the
general certificate or differential-validation capability available.

The reviewed `znc optimize --accept` handoff also re-reads the bounded source
snapshot after the baseline and transformed child builds and immediately before
create-only publication. A source replacement during that window fails closed;
the handoff never publishes an artifact whose differential evidence may refer
to a different source snapshot.

Pure explicitly typed `bool`/`i32`/`i64` scalar functions with SSA locals,
mutable stack slots, calls, returns, structured `if`/`while`, `break`/`continue`, and
noncapturing integer `switch` lower directly from verified ZIR on Linux x86-64.
Signed `/` and `%` also lower directly under the narrowly admitted `Panic`
effect: divide by zero prints `panic: division by zero` and exits 134, while
division or remainder by `-1` preserves the defined `i32`/`i64` wrapping edge
instead of taking an x86 trap. Both branch arms, mutable loop control, source-ordered
shadow initializers, multi-pattern dispatch, normal division, overflow edges,
and the panic path are execution-tested. The native header reports
`artifact_ir_consumed=1` only for this direct path. When it reports `0`, the
instructions come from the checked AST bridge and are not derived from the
preceding structural ZIR rendering. Other effects and operations remain on that
bridge. Immutable explicitly typed captureless function values may also lower
directly when they name an exact root-owned non-generic declaration; imported,
captured, mutable, or mismatched function values remain on the bridge. Structured
IR coverage also includes enum/union switch and `defer`, plus
string and aggregate operations, but the native typed-IR/instruction view stays
partial until all displayed contextual types and artifact routes share one IR
authority.

The direct ZIR call seam includes one deliberately narrow imported-call slice:
an inferred top-level `i32` or `i64` binding may call an explicitly qualified
public, captureless, non-generic imported function when every argument is a
canonical integer literal and the return width matches. The native backend
proves this with `tests/zir_import_scalar.zag` and rejects unqualified names,
private/extern/generic/captured declarations, source names that merely contain
`__`, and mismatched widths via `tests/zir_import_scalar_bad.zag`. Imported
calls outside that exact shape remain on the checked AST bridge; this does not
make imported or contextual calls generally typed-IR authoritative.

Background planning is project-scoped and editor-independent:

```sh
./znc watch
./znc watch --mode light
./znc watch --mode adaptive
./znc watch --mode deep
./znc watch --mode off
./znc status
./znc suggest
./znc suggest --format text
./znc suggest --format json
./znc shutdown
```

`mode=off` in `.zagd.conf` is the persistent opt-out. An explicit CLI
allocator, CPU, device, or layout choice overrides the corresponding Script
default without changing source. See `ZAGD_GUIDE.md` for the persistent
systemd-user-service form and resource policy.

## A minimal script

The indentation-oriented surface is intended for first programs:

```zag
name = input("What is your name? ")
print("Hello")
print(name)
```

In `.zs`, a first assignment declares a statically typed local, indentation
forms blocks, and line-ending semicolons are optional. `print` includes a
newline. The same profile can be written in canonical Zag:

```zag
script;

println("Hello from Zag Script");
return 0;
```

`return` supplies the generated process entry point's status.

The implemented indentation surface includes assignment and reassignment,
`if`/`elif`/`else`, `while`, collection and `range` loops, `def`, `return`,
`pass`, `True`, `False`, `None`, `not`, homogeneous list literals,
`.append`, indexing, `len`, `print`, and bounded `input`. Function parameters
without annotations currently default to `i64`; annotations may use `int`,
`float`, `str`, and `bool`. This is a deliberately typed Zag surface, not
Python emulation. Classes, decorators, generators, comprehensions, arbitrary
Python modules, and dynamic mixed-type containers are not accepted.

`print` and `println` accept strings/slices and integer expressions. Script
users do not need to manually convert a counter merely to display it:

```zag
script;

let files_checked: i32 = 42;
println(files_checked);
```

## First programs

Zag Script is ordinary Zag with the low-friction profile selected by `script;`.
For a first program, use values, `if`, `while`, functions, and the small
prelude. You do not need `main`, allocator arguments, effects, or type
annotations unless a program benefits from making one explicit.

```zag
script;

let numbers = list(2, 3, 5);
append(numbers, 7);
set_at(numbers, 1, 4);
println(length(numbers));
println(item_at(numbers, 0));
let last = pop(numbers);
println(last);
```

`append(list, value)`, `set_at(list, index, value)`, `length(list)`,
`item_at(list, index)`, `pop(list)`, and `clear(list)` are Script root conveniences for
copy-semantic typed lists. They lower to the ordinary explicit
`script_list_append(&list, value)`, `script_list_set(&list, index, value)`,
`script_list_len(list)`, `script_list_get(list, index)`, and
`script_list_pop(&list)` and `script_list_clear(&list)` APIs. `clear` zeroes the
live element bytes, resets `len`, and retains the ScriptContext-backed capacity
for later appends. Invalid indexes, empty pops, failed/forged descriptors, and
invalid clear targets fail closed. Resource-valued list move/drop semantics
remain unsupported, including plain clear; use an explicit ownership-aware
strict-Zag collection path instead. These helpers do not introduce dynamic
values or change strict Zag. If one of these names is declared by the user,
the user declaration wins.

The beginner rule is simple: values have a kind, functions do work, `if`
chooses, loops repeat, and diagnostics explain the next small correction.
`znc explain` is optional inspection, not required knowledge.

## Prelude

The intentionally small implemented prelude is `print`, `println`, `say`,
`input`, `env`, `read_file`, `write_file`, `args_len`, `arg`, `args`,
`path_join`, `path_basename`, `path_dirname`, `path_extension`,
`string_concat`, `script_alloc`, `script_alloc_used`, `process_run_timeout`,
`process_run_argv`, `new`, `string_builder`, `list`, `append`, `set_at`,
`length`, `len`, `item_at`, `pop`, and `clear`. The same root-only allowlist
also contains the documented `map*`, `text_map*`, `set*`, `text_set*`, and
`range*` families plus the bounded `json_*` and `csv_*` conversion helpers
described below. These are typed conveniences with ordinary strict-Zag
implementations, not dynamic values or authority to import arbitrary APIs.
The ordinary strict-Zag mappings are
`_zag_print`, `_zag_println` (`say` uses `_zag_println`),
`_zag_script_env_get`, `_zag_read_file`, `_zag_write_file`, `_zag_argc`,
`_zag_arg`, `script_args`, the `script_path_*` helpers, `_zag_str_concat`, and
the explicit script-context allocation runtime calls. Prelude bindings occur
only in executable statements of the selected script root. An ordinary user
function with the same name wins independently.

`input(prompt)` prints the prompt and reads at most 4096 bytes from standard
input into Script-lifetime storage. The allocation is charged to the Script
limit and the trailing newline is removed. It is bounded input, not an
unbounded console buffer.

`env("NAME")` reads a configured process-environment variable without copying
it into Script storage. Put exact allowed names in `.zagd.conf`, for example
`environment_allow=HOME,TERM`; the empty default denies all lookups. `NAME`
must be a literal simple name, not a computed string. Unset or values longer
than 4096 bytes return an empty value. The prelude never grants environment
authority to an imported strict library.

`read_file` size-preflights a regular file, allocates one Script-lifetime
destination charged to the selected Script allocator, then reads directly into
that destination while checking for growth or replacement. It never stages a
whole file in the ordinary native allocator. The only native temporary is a
NUL-terminated path bridge of at most 4097 bytes, released immediately after
`open(2)`. Open failure uses a slice with negative length; budget or size-limit
failure emits a diagnostic and returns an empty slice. A post-allocation read
failure retains its charged Script allocation until generated shutdown.
`string_concat` returns Script-lifetime storage charged to that budget.

String literals in the indentation-oriented Script profile support bounded
`[]u8` interpolation, for example `println("hello {name}")`. Source-proven
`i64` expressions and `bool` values are also formatted into ScriptContext
storage (`{count + 2}` and `{ready}`); unknown expressions remain under the
ordinary typed checker rather than being guessed. Standalone decimal float
literals preserve their validated source spelling (`{1.5}` and `{-2.5}`),
without allocating a temporary. Typed float variables and expressions use a
locale-free ScriptContext formatter rounded to six fractional places, trimming
trailing zeroes; NaN and out-of-range values have fixed bounded spellings.
Each placeholder is parsed
with the shared lexer and lowered to compiler-owned `string_concat` calls, so
the copied bytes are charged to the Script allocator. A non-empty generated
scalar result that cannot be charged because the Script budget is exhausted
fails closed with a diagnostic and exit status 1; it is never silently changed
into an empty string. Empty, nested, or
unmatched braces fail with a localized diagnostic; use `{{` and `}}` for
literal braces. Float formatting and general format-specifier semantics
remain outside the profile. Strict Zag strings and canonical-brace Script
sources are left byte-for-byte unchanged.

## Profile rules currently enforced

- Use exactly one `script;` declaration.
- Put it before executable root statements.
- Do not also declare `main`.
- Only the selected root's executable statements run.
- A `.zag` suffix alone does not activate the profile; `.zs` does.
- A source file without `script;` keeps regular Zag semantics.

`args()` materializes a typed `ScriptList[[]u8]`; its backing array is charged
to the Script allocator while argument string bytes remain immutable process
storage. `path_join`, `path_basename`, `path_dirname`, and `path_extension` are
lexical path helpers. `path_join` allocates from the bounded Script context and
fails closed with a diagnostic and exit status 1 if a non-empty result cannot
be charged; it never silently becomes an empty path. The other helpers return
input slices and never access the filesystem.

The Script profile exposes bounded JSON conveniences in addition to the
ordinary `std:json` declarations: `json_normalize`, `json_int_array`,
`json_bool_array`, `json_int_array_encode`, `json_bool_array_encode`,
`json_string_array_encode`, `json_string_map`, and the other explicitly typed
encode helpers.
They lower to compiler-owned bridges and retain the same fail-closed
ScriptContext allocation boundary; they do not turn JSON into dynamic Script
values.
Project `.zagd.conf` defaults for allocator, CPU, device, layout, and Script
memory budget are resolved by foreground compilation; command-line
`--script-allocator`, `--cpu`, `--device`, and `--layout` choices win. This is
configuration of supported choices, not arbitrary allocator/capability
synthesis. Use
ordinary explicit Zag APIs where available; the compiler does not pretend those
APIs are script defaults.

Two native Script allocator policies are currently supported:

- `script_process_arena` is the default. It reserves one mapping, charges exact
  requested payload bytes, retains values for the Script lifetime, and unmaps
  the mapping at generated shutdown.
- `script_bounded_heap` is a genuinely distinct explicit option. Each
  successful allocation owns a native block linked from `ScriptContext`; the
  budget charges the payload plus a 16-byte ownership header, including for a
  zero-length request. Generated shutdown frees every complete block. Native
  size-class slack is visible in allocator telemetry but is outside
  `script_alloc_used()`.

For example:

```sh
./znc script app.zag --script-allocator script_bounded_heap --run
```

or in `.zagd.conf`:

```text
allocator=script_bounded_heap
```

The selected policy is part of the foreground machine-code cache identity.
Changing it produces a cache miss and fresh code generation; it can never
reuse code generated for the other allocator.

The resolved choices and project filesystem/process permissions are retained as
compiler-owned ScriptContext metadata. The context also records argument
metadata, bounded limits, allocator state, deterministic shutdown state, and
the uncaught-error reporting policy. `env("NAME")` is read-only and requires
the exact literal name to appear in `.zagd.conf` as
`environment_allow=NAME,OTHER_NAME`; the default empty list denies it. Values
are a zero-copy process-environment view capped at 4096 bytes; unset or
oversized values are empty. This does not create an environment API for strict
imports. Unknown
allocator/device/layout policy ids fail before output, and the native initializer
also rejects malformed internal policy words rather than treating them as a new
execution implementation. ScriptContext CPU metadata currently accepts the
generic x86-64 baseline (including its aliases) or `native`; runtime-dispatch
metadata is not yet part of this Script policy.

`process_run_timeout(command, timeout_ms, max_output)` is the root-only Script
name for the ordinary strict-Zag `std:process.process_run_bounded` declaration.
It invokes `/bin/sh -c`, captures stdout, uses a monotonic deadline, caps output
at 1 MiB, kills the complete child process group on timeout/overflow, and reaps
the shell. Its typed `ProcessResult` reports `status`, `state`, and `output`
through the ordinary getter functions. An explicit user declaration named
`process_run_timeout` overrides the convenience.
Its command copy, descriptor/status storage, capture capacity, and result handle
are charged to the Script budget before being exposed. The output capacity is
reserved up front, making its maximum charged cost deterministic. The result
handle is 32 bytes under `script_process_arena`; `script_bounded_heap` charges
48 bytes because its tracked native block includes the same 16-byte ownership
header as other heap-policy allocations. Strict Zag's ordinary
`process_run_bounded` retains its allocator behavior.

`process_run_argv(executable, arguments, timeout_ms, max_output)` is the
shell-free Script spelling. The currently proven `arguments` producer is
`args()`, a homogeneous `ScriptList[[]u8]`; the compiler-owned bridge copies
the executable and arguments into bounded NUL-terminated storage and calls
`execve` directly with an empty environment. Shell metacharacters remain
literal bytes. The direct form keeps the same timeout, output-limit,
process-group cleanup, and typed result states, and rejects malformed list
descriptors, empty paths, embedded NULs, more than 31 arguments, per-item
lengths above 4095 bytes, or combined argv storage above 64 KiB. Generic
string-list literal inference is not part of this bounded slice. An explicit
user declaration named `process_run_argv` overrides the convenience.

`string_builder(capacity)` creates a fixed-capacity `ScriptStringBuilder` from
the bounded Script allocator. `string_builder_append`, `string_builder_len`,
`string_builder_failed`, and `string_builder_output` are ordinary Zag
declarations. Appends never grow or reallocate the buffer: successful total copy
work equals the number of appended bytes, overflow leaves existing contents and
length unchanged, and marks the builder failed. `string_builder_output` carries
an explicit retained-return contract so a returned slice keeps its backing
builder live while invalid descriptors fail closed through the mutable handle.
Strict Zag imports
`std:script_string_builder` and calls `string_builder_from_buffer` with explicitly
allocated storage. It is not a dynamic value system.

`list(a, b, ...)` accepts one to four statically compatible initial values and
infers one element type. `script_list_append`, `script_list_len`, and
`script_list_get` remain typed; mixed literal types are rejected. Capacity grows
geometrically through the bounded Script allocator, so successful append
sequences copy linear total data. Superseded Script buffers remain until
shutdown and count toward `script_alloc_used()` under the selected policy.

`map()` is the first bounded Script dictionary slice. It creates a
`ScriptMapI32` with integer keys and integer values; `map_put`, `map_get`,
`map_has`, `map_del`, `map_clear`, `map_len`, and `map_failed` provide checked
update/query/delete/reuse operations. `map_del` returns zero for a deletion and one
for an absent key; `map_clear` zeroes the retained key, value, and state arrays,
resets the live/tombstone counts, and preserves capacity for later inserts.
Malformed map state, including a null target, invalid table descriptor, or
live/tombstone count mismatch, fails closed before any table write. The table
grows and rehashes through
ScriptContext storage, uses tombstones for probe continuity, and retains
superseded arrays until shutdown. The Script profile also accepts
bounded single-line map-literal sugar (and its bounded multiline form) for
simple unannotated
`i32: i32` bindings: entries must be non-empty in-range integer literals with
no trailing comma. Same-line nested, annotated, dynamic, string, and
resource-valued forms remain unsupported, so this is not a general dynamic
dictionary.

`set()` is the bounded homogeneous integer-set counterpart. `set_add`,
`set_has`, `set_del`, `set_len`, and `set_failed` use bounded open addressing
with tombstones. `set_clear(set)` validates the non-null target and context,
power-of-two capacity, backing arrays, state bytes, and exact live/tombstone
counts before zeroing every retained key/state slot. It then resets both counts
while retaining capacity and pointers for later insertion. Invalid descriptors
or a null target return status `1`; non-null failures set `failed` and leave
backing slots untouched. The context check is a descriptor invariant rather
than arbitrary-pointer authentication, and a user declaration named
`set_clear` takes precedence.

`text_map()` is a separate bounded byte-slice dictionary. Its
`text_map_put/get/has/del/clear/len/failed` operations copy non-empty keys and values
into ScriptContext storage, retain superseded payloads until shutdown, and use
the same bounded tombstone/probe rules. `text_map_clear` first validates the
non-null target, context, bounded power-of-two table, backing arrays, every
state byte, and exact live/tombstone counts. It then replaces every retained
key/value slice with the empty slice, zeros every state byte, resets the counts,
and preserves the table pointers and capacity for reuse. A malformed non-null
descriptor is marked failed and returns status `1` without changing a table
slot; null targets passed to put, delete, or clear return `1` before any
dereference. Payload allocations remain arena-owned until
shutdown, so clearing is deterministic table reuse rather than reclamation.
Empty keys and values are valid. It is still not a general dynamic-value map
and has no resource-element semantics.
The profile also accepts a bounded single-line or multiline text-map literal on a simple
unannotated binding, for example
`let labels = {"alpha": "one", "beta": "two"};`. Every entry must contain
one string literal key and one string literal value; duplicate keys overwrite
earlier entries, and the normal Script string escapes are retained. Empty
keys/values are valid. Unescaped single braces and interpolation in literal
keys or values are rejected; doubled `{{` and `}}` are literal brace escapes.
Trailing commas, empty maps, identifiers or calls,
nested values, annotated bindings, and resource-valued forms remain rejected.
The table grows only through the bounded ScriptContext path
and its runtime capacity is capped at 1,048,576 slots; this is not a general
map-literal or dynamic-value surface.

`text_set()` is the homogeneous byte-slice set facade over `ScriptMapText`.
It copies keys into ScriptContext storage and exposes duplicate, membership,
delete, length, and failure status without exposing map values.
`text_set_clear` delegates to the same all-or-nothing descriptor validation,
full key/value/state scrub, retained-capacity reuse, and malformed/null-target
status boundary as `text_map_clear`; add and delete also reject a null facade
target. The ownership checker recognizes its exact resolver-owned constructor
as a compiler ScriptContext producer rather than a user borrow; same-name
project functions do not receive that exception. This remains a byte-slice collection, not
a claim of Unicode normalization or general dynamic set values.

Root-level `make[T]` is intentionally rejected in Zag Script because its storage
does not pass through `ScriptContext` and therefore cannot satisfy the configured
memory limit. Use `list`, `string_builder`, `script_alloc`, or write an explicit
strict-Zag function with its own allocator policy. Ordinary Zag and imported
strict libraries retain their existing allocator semantics; their allocation is
not charged to `script_alloc_used()` and must be bounded by their explicit API
contract. This separation prevents Script defaults from silently changing a
library's allocator, but it does not prove that imported code is bounded.

JSON is available as the ordinary `std:json` module. Its smallest typed helpers
parse/stringify strings, signed integers, booleans, and null, parse JSON number
syntax to `f64`, and retain the existing homogeneous-integer-array,
homogeneous-boolean-array, and string-to-string-object APIs. `JsonDocument` is
the general representation for
nested objects, arrays, strings, exact number lexemes, booleans, and null. It is
a flat indexed tree rather than an untyped language value. The default parser
limits input to 1 MiB, nesting to 64 containers, and values to 65,536;
`json_parse_value_bounded` makes those limits explicit. The compact encoder has
a 4 MiB default output limit. Object order and duplicate keys are preserved;
`json_object_find` selects the first matching key. Strings cross this boundary
as UTF-8 byte slices:
all JSON escapes and valid surrogate pairs decode to UTF-8, while malformed
UTF-8, escapes, and lone surrogates fail. `json_document_free` is required for
both successful and failed documents because a failed partial parse retains one
ownership ledger. `json_encode_result_free` releases encoded output.

The Script `json_int_array(source)` and `json_bool_array(source)` conveniences
accept only homogeneous JSON arrays and copy their values into typed,
ScriptContext-owned lists. Both use the strict parser's 1 MiB input and 65,536
value bounds; malformed JSON, the wrong element type, trailing data, a
trailing comma, or a Script-budget failure returns a failed list without
exposing native temporary storage. The strict `std:json` boolean-array result
must be released with `json_bool_array_result_free`, including after failure.
`json_bool_array_encode(values)` emits deterministic compact JSON (`true` and
`false` spellings) from a validated `ScriptList[bool]`. It validates context,
failed-list, shape, count, and output bounds before allocating one retained
ScriptContext byte buffer; failed lists, output-limit rejection, and exhausted
Script budget return the zero-length failure slice. There is no nested/dynamic
JSON-to-Script conversion, general aggregate ownership claim, or unrestricted
application-scale codec semantics in this slice.

CSV is available as byte-preserving `std:csv`. `csv_parse` accepts comma fields,
doubled quotes, embedded CR/LF in quoted fields, CRLF and LF records (plus bare
CR as a documented extension), leading/trailing empty fields, and rejects
unquoted quotes, unterminated quotes, or bytes after a closing quote. Defaults
are 1 MiB input/field, 65,536 rows, and 262,144 cells; `csv_parse_bounded`
exposes each limit. `csv_encode` emits deterministic CRLF records,
`csv_encode_lf` selects LF, and both quote only when required. CSV does not
infer or validate a character encoding or require uniform row widths. Call `csv_free` and
`csv_encode_result_free` for owned results.

Zag Script can import both modules and inspect their typed aggregate results:

```zag
@import("std:json") as json
let document: json.JsonDocument = json.json_parse_value("{\"ready\":true}");
```

The Script profile also provides two raw-byte bridges: `json_normalize(source)`
and `csv_normalize(source)`. Each uses the existing bounded parser and encoder,
copies only the final encoded bytes into ScriptContext, and frees its native
`JsonDocument`/`JsonEncodeResult` or `CsvTable`/`CsvEncodeResult` temporaries on
success, parse failure, encode failure, and Script allocation failure. Malformed
input remains the zero-length bounded failure value; a valid encoded result
that cannot be charged to ScriptContext instead emits a diagnostic and exits
status 1, so resource exhaustion cannot masquerade as malformed data. The
bridges never expose those owned aggregates to Script code.
`tests/script_json_csv_wrappers.zag` covers normalization, malformed input, and
unchanged Script allocation accounting; `tests/script_json_csv_wrapper_limit.zag`
covers cleanup followed by the fail-closed allocation boundary. Passing an
imported owned aggregate to an untrusted helper remains rejected by the focused
negative fixture. Direct strict Zag continues to provide the full ownership
API, while the strict fixtures prove leak-free success and failure cleanup.

## Safety boundary

The profile lowering does not establish ownership, borrowing, or general memory
safety. The default allocator uses one bounded mmap-backed arena; the explicit
bounded heap uses individually tracked native blocks. The generated shutdown
boundary unmaps the arena or frees all tracked blocks, respectively. The
configurable limit covers Script collection/string-builder storage, string
concatenation, returned file data, bounded-process storage, and compiler-owned
`new` in root top-level statements. The arena charges requested payload; the
bounded heap also charges its 16-byte ownership header per allocation. Ordinary
`make`, native allocator size-class slack, the bounded file-reader path bridge,
and `new` inside imported strict functions remain outside it. `read_file`
never stages whole-file contents outside the Script allocator. Normal Zag
effects and runtime behavior remain authoritative.

Native allocation diagnostics and telemetry cover the implemented allocator
paths, including copied raw-slice descriptor double frees and failed mappings.
They do not validate arbitrary integer-derived pointers. Edition-2027 strict
projects may opt into the documented named-owner and explicit borrow-contract
checks. The same edition rejects tested callee-frame addresses returned through
named pointer-carrying aggregate aliases, but does not track mutation-aware
container, global, or callback provenance. These checks remain a conservative
promotion aid rather than a claim that every heap graph is proven.
