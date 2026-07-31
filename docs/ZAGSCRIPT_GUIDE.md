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
`explain`, conservative `harden`, and `check --strict`. Both activation forms
are supported:

- `script;` in an ordinary `.zag` file;
- `znc script program.zag`; or
- the optional `.zs` suffix.

`znc harden` is deliberately conservative. For a root body with no
compiler-bound Script prelude operation and no propagated `try`, it produces a
reviewable strict-Zag candidate with explicit memory/capability policy
constants, context init/shutdown, and a status boundary. Other Script
conveniences are reported as structured unsupported conversions rather than
silently rewritten. By default hardening only prints a preview; `--output`
uses an atomic sibling-temporary publish, while `--apply` still requires an
explicit parity-test command and preserves a rollback copy. See
`ZAGSCRIPT_HARDENING.md` for the exact supported boundary.

All three select the same `ModuleProfile.script`, parser, AST, semantic
analysis, runtime, and native backend. `.zs` is a convenience, not a second
language or a claim that arbitrary Python files are source-compatible.

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
`unknown`. It does not guess a source line: statement spans are not yet stored
in the AST, so the witness explicitly says location is unavailable. The report
is capped at 64 entries and excludes imported strict-library implementation
details.

```sh
./znc examples/script_hello.zag -o /tmp/script_hello
/tmp/script_hello
```

After compiler-source changes, rebuild the self-hosted compiler through the
documented native bootstrap before testing the new syntax. The committed `znc`
binary is the bootstrap seed; no external compiler, assembler, or linker is part
of the supported path.

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
./znc check app.zag
./znc check app.zag --strict
```

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
println(length(numbers));
println(item_at(numbers, 0));
```

`append(list, value)`, `length(list)`, and `item_at(list, index)` are Script
root conveniences for typed lists. They lower to the ordinary explicit
`script_list_append(&list, value)`, `script_list_len(list)`, and
`script_list_get(list, index)` APIs. They do not introduce dynamic values or
change strict Zag. If `append`, `length`, or `item_at` is declared by the user,
the user declaration wins.

The beginner rule is simple: values have a kind, functions do work, `if`
chooses, loops repeat, and diagnostics explain the next small correction.
`znc explain` is optional inspection, not required knowledge.

## Prelude

The intentionally small implemented prelude is `print`, `println`, `say`,
`input`, `env`, `read_file`, `write_file`, `args_len`, `arg`, `args`,
`path_join`, `path_basename`, `path_dirname`, `path_extension`,
`string_concat`, `script_alloc`, `script_alloc_used`, `process_run_timeout`,
`string_builder`, and `list`. The ordinary strict-Zag mappings are
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
lexical path helpers. `path_join` allocates from the bounded Script context; the
other helpers return input slices and never access the filesystem.

Implicit JSON bindings are not implemented; JSON remains available through the
ordinary `std:json` declarations.
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

`string_builder(capacity)` creates a fixed-capacity `ScriptStringBuilder` from
the bounded Script allocator. `string_builder_append`, `string_builder_len`,
`string_builder_failed`, and `string_builder_output` are ordinary Zag
declarations. Appends never grow or reallocate the buffer: successful total copy
work equals the number of appended bytes, overflow leaves existing contents and
length unchanged, and marks the builder failed. Strict Zag imports
`std:script_string_builder` and calls `string_builder_from_buffer` with explicitly
allocated storage. It is not a dynamic value system.

`list(a, b, ...)` accepts one to four statically compatible initial values and
infers one element type. `script_list_append`, `script_list_len`, and
`script_list_get` remain typed; mixed literal types are rejected. Capacity grows
geometrically through the bounded Script allocator, so successful append
sequences copy linear total data. Superseded Script buffers remain until
shutdown and count toward `script_alloc_used()` under the selected policy.

Root-level `make[T]` is intentionally rejected in Zag Script because its storage
does not pass through `ScriptContext` and therefore cannot satisfy the configured
memory limit. Use `list`, `string_builder`, `script_alloc`, or write an explicit
strict-Zag function with its own allocator policy. Ordinary Zag and imported
strict libraries retain their existing allocator semantics; their allocation is
not charged to `script_alloc_used()` and must be bounded by their explicit API
contract. This separation prevents Script defaults from silently changing a
library's allocator, but it does not prove that imported code is bounded.

Basic JSON scalar support is available as the ordinary `std:json` module. It
stringifies and parses strings, signed integers, and booleans, parses finite
JSON floating-point syntax, and parses/stringifies null. Statically typed parse
results contain `ok` and, where applicable, `value`; parse failure is explicit.
Homogeneous integer arrays and string-to-string objects have separate statically
typed parsers; heterogeneous dynamic JSON values are deliberately not the
default model. Float stringification and general nested composite decoding
remain unsupported. Unicode `\\u` escapes, including valid surrogate pairs,
decode to UTF-8 and malformed or lone surrogates fail explicitly.
Zag Script uses the same inspectable API as strict Zag:

```zag
@import("std:json") as json
let result: json.JsonIntResult = json.json_parse_int("42");
```

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
