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

This is not yet the complete product described by
`ZAGSCRIPT_SEMANTICS.md`. In particular, the script prelude, `ScriptContext`,
bounded arena, uncaught-error wrapper, `znc script`, `explain`, `harden`, and
`check --strict` are not implemented. The normal direct build form is the
currently supported entry:

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

_zag_println("Hello from Zag Script");
return 0;
```

`return` supplies the generated process entry point's status. There is not yet a
script prelude, so this example uses the existing native output primitive. It is
an implementation example, not the intended final ergonomic API.

## Profile rules currently enforced

- Use exactly one `script;` declaration.
- Put it before executable root statements.
- Do not also declare `main`.
- Only the selected root's executable statements run.
- A `.zag` suffix alone does not activate the profile.
- A source file without `script;` keeps regular Zag semantics.

## Unsupported examples

The requested `script_files.zag`, `script_process.zag`,
`script_collections.zag`, and `script_harden.zag` examples are intentionally not
present yet. Publishing them now would imply nonexistent prelude, allocator,
process-timeout, typed-list, or hardening behavior. Existing strict Zag standard
library examples remain valid demonstrations of those ordinary APIs, but they
are not evidence of implicit Zag Script conveniences.

## Safety boundary

The current profile lowering does not establish ownership, borrowing, automatic
reclamation, or general memory safety. It also does not yet enforce a script
memory limit. Normal Zag effects and runtime behavior remain authoritative.

