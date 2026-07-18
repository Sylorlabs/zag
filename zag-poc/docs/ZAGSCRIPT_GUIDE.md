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
`write_file`, `args_len`, `arg`, `string_concat`, `script_alloc`, and
`script_alloc_used`. The ordinary strict-Zag
mappings are `_zag_print`, `_zag_println`, `_zag_read_file`, `_zag_write_file`,
`_zag_argc`, `_zag_arg`, `_zag_str_concat`, and the explicit script-context
allocation runtime calls. Prelude bindings occur
only in executable statements of the selected script root. An ordinary user
function with the same name wins independently.

`read_file` currently allocates outside the requested-payload script budget and
reports failure using a slice with negative length. This is documented behavior,
not a general memory-safety guarantee or the eventual typed error API.

## Profile rules currently enforced

- Use exactly one `script;` declaration.
- Put it before executable root statements.
- Do not also declare `main`.
- Only the selected root's executable statements run.
- A `.zag` suffix alone does not activate the profile.
- A source file without `script;` keeps regular Zag semantics.

Process execution with timeout, JSON, typed-list convenience syntax, a materialized
`args` collection, and automatic allocator/capability expansion are not implemented. Use
ordinary explicit Zag APIs where available; the compiler does not pretend those
APIs are script defaults.

## Safety boundary

The profile lowering does not establish ownership, borrowing, automatic
reclamation, or general memory safety. `script_alloc` enforces a configurable
requested-payload limit, but ordinary allocation and file-read buffers are not
charged to it. Normal Zag effects and runtime behavior remain authoritative.
