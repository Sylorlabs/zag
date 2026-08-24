# Resource embedding

`#embed("relative/path")` includes the exact bytes of a project resource at
compile time and evaluates to `[]u8`. The compiler owns parsing, identity,
lowering, and diagnostics; no C, Zig, linker-script, or generated-source bridge
is required.

```zag
fn main() i32 {
    let icon: []u8 = #embed("assets/icon.png");
    return icon.len;
}
```

## Path and identity contract

- The argument is exactly one non-empty string literal.
- The path is relative to the source file containing the expression.
- Absolute and computed paths are rejected with `E0017` so builds do not depend
  on a machine-specific filesystem or environment.
- Resource lookup is exact. It does not use `@import` standard-library or
  sibling `lib/` search paths.
- The normalized path and exact raw bytes are part of the foreground machine
  cache identity. Changing only the resource forces authoritative lowering.
- The current per-resource limit is 64 MiB. Runtime asset streaming is the
  correct contract for larger content.

Empty resources and all byte values, including NUL and invalid UTF-8, are
preserved. Formatting retains the exact quoted expression without reading the
filesystem. AST JSON reports the literal, normalized path, and byte length but
does not place arbitrary binary data in JSON.

## Target and output contract

The x86-64 and ARM64 executable backends place bytes verbatim in the compiler
owned data image and materialize a `{pointer, length}` slice. Repeated builds
with identical compiler, sources, options, and resources must be byte-identical.
Object formats may advertise resource embedding only after their data-section,
relocation, alignment, and reproducibility suites pass.

Run the focused gate with:

```sh
make test-resource-embed
```

It covers binary and empty data, imported-module-relative paths, x86-64 and
ARM64 execution, deterministic output, source-only formatting, malformed and
missing inputs, exact lookup, artifact fail-closed behavior, and resource-aware
cache invalidation.
