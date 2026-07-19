# Zag Script guide

Zag Script is Zag's built-in low-friction profile. It provides concise defaults
for short programs and experiments while preserving a direct path into explicit
native Zag through inspection and hardening.

## Current implementation status

The current foundation recognizes `script;`, records the script profile in the
ordinary module AST, accepts executable root statements, and lowers the selected
root body to a compiler-owned native entry point. Statements run in source order.
A script module imported by a strict root contributes declarations without
running its script body. Duplicate profile declarations and a script containing
a user `main` are diagnosed.

The implemented profile includes a managed context, requested-payload allocation
limit, uncaught-error wrapper, `znc script`, `explain`, conservative `harden`,
and `check --strict`. Both activation forms are supported:

The JSON form of `explain` embeds the compiler's checksummed semantic manifest,
including declaration signatures, layouts, call edges, function effects, and
per-expression `expr_fact` witnesses. Types come from the shared typed frontend;
effects come from sema's context-sensitive expression walk. Calls, binary and
unary forms, casts, slice indexing/slicing, supported struct fields, assignments,
returns, and nested control-flow conditions are recursively reported. A form
outside typed authority is tagged `type_basis=unknown`, never guessed. Text and
JSON expose the same checksummed manifest.

```sh
./znc examples/script_hello.zag -o /tmp/script_hello
/tmp/script_hello
```

After compiler-source changes, rebuild the self-hosted compiler through the
documented native bootstrap before testing the new syntax. The committed `znc`
binary is the bootstrap seed; no external compiler, assembler, or linker is part
of the supported path.

## A minimal script

```zag
script;

println("Hello from Zag Script");
return 0;
```

`return` supplies the generated process entry point's status.

## Prelude

The intentionally small implemented prelude is `print`, `println`, `read_file`,
`write_file`, `args_len`, `arg`, `string_concat`, `script_alloc`,
`script_alloc_used`, `process_run_timeout`, `string_builder`, and `list`. The ordinary strict-Zag
mappings are `_zag_print`, `_zag_println`, `_zag_read_file`, `_zag_write_file`,
`_zag_argc`, `_zag_arg`, `_zag_str_concat`, and the explicit script-context
allocation runtime calls. Prelude bindings occur
only in executable statements of the selected script root. An ordinary user
function with the same name wins independently.

`read_file` copies its returned value into Script-lifetime storage charged to the
requested-payload budget. The native reader still uses temporary staging storage
outside that accounting, but releases it immediately after the Script copy or
copy-budget failure; its temporary native path bridge is released immediately
after `open(2)`. Open failure uses a slice with negative length; budget
failure emits a diagnostic and returns an empty slice. This is not a general
memory-safety guarantee or the eventual typed error API.
`string_concat` returns Script-lifetime storage charged to that budget.

## Profile rules currently enforced

- Use exactly one `script;` declaration.
- Put it before executable root statements.
- Do not also declare `main`.
- Only the selected root's executable statements run.
- A `.zag` suffix alone does not activate the profile.
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

`process_run_timeout(command, timeout_ms, max_output)` is the root-only Script
name for the ordinary strict-Zag `std:process.process_run_bounded` declaration.
It invokes `/bin/sh -c`, captures stdout, uses a monotonic deadline, caps output
at 1 MiB, kills the complete child process group on timeout/overflow, and reaps
the shell. Its typed `ProcessResult` reports `status`, `state`, and `output`
through the ordinary getter functions. An explicit user declaration named
`process_run_timeout` overrides the convenience.
Its command copy, descriptor/status storage, capture capacity, and result handle
are charged to the Script budget before being exposed. The output capacity is
reserved up front, making its maximum charged cost deterministic. Strict Zag's
ordinary `process_run_bounded` retains its allocator behavior.

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
sequences copy linear total data. Superseded arena buffers remain until Script
shutdown and count toward `script_alloc_used()`.

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
safety. Compiler-owned Script payloads use one bounded mmap-backed arena and the
generated shutdown boundary reclaims that complete mapping deterministically.
The configurable requested-payload limit
covers Script collection/string-builder storage, string concatenation, returned
file data, bounded-process storage, and compiler-owned `new` in root top-level
statements. Ordinary `make`, allocator metadata, file-reader staging, and `new`
inside imported strict functions remain outside it. Normal Zag effects and runtime
behavior remain authoritative.
