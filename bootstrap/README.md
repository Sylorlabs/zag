# Bootstrap seeds

This directory contains the irreducible seed binaries for Zag's self-hosting
bootstrap. Like Zig's `stage1/`, these are the trusted starting point — you
cannot compile a self-hosting compiler from nothing.

- `znc` — the native compiler seed (x86-64 ELF / ARM64 Mach-O emitter)
- `zagd` — the semantic planner daemon seed
- `zag-lsp` — the language server seed (built from `selfhost/lsp/zag-lsp.zag`)
- `znc-target` — the GPU/WASM target driver seed (built from `selfhost/native/znc_target.zag`)

## Bootstrapping

```sh
./bootstrap.sh
```

This reads `bootstrap/znc` as the seed, rebuilds the compiler from source
through three stages, verifies a byte-identical fixpoint, and writes the
freshly built `znc` and `zagd` to the repository root (gitignored as build
outputs).
