# Zag compiler (`zag-poc`)

The supported compiler is `./znc`. It writes a static x86-64 ELF binary,
WebAssembly (`--target wasm`), or GPU MLIR frontend output (`--target gpu-*`).
GPU MLIR output is not a GPU executable or dispatch runtime. No `cc`, no `as`,
no `ld`, no libc, no Zig, no LLVM.

```sh
./znc examples/numeric.zag -o numeric --run
```

Rebuild the compiler from source:

```sh
./bootstrap.sh
bash tests/run_native_authority.sh
```

More detail lives in [INSTALL.md](INSTALL.md) and [BOOTSTRAP.md](BOOTSTRAP.md). The frozen language boundary is in [docs/V1_LANGUAGE_SPEC.md](docs/V1_LANGUAGE_SPEC.md).

## Everyday commands

```sh
./znc version
./znc init
./znc fmt --in-place source.zag
./znc source.zag -o program --run
./znc source.zag -o program --debug
make test
```

## LSP

Build the language server:

```sh
./znc selfhost/lsp/zag-lsp.zag -o zag-lsp
```

The VS Code client is in `../editors/vscode/`.

## Examples worth running first

```sh
./znc examples/audio_render.zag -o audio_render --run
./znc examples/audio_render_bad.zag -o /tmp/bad        # should fail with a witness chain
./znc examples/embedded_sensor.zag -o embedded_sensor --run
```

Larger programs under `programs/` are documented in [programs/GAPS.md](programs/GAPS.md).

## Tests

Release gates (these must pass before a release):

```sh
make test                              # full v1 release gates (includes programs)
bash tests/run_programs.sh             # programs/*.zag integration gate only
bash tests/run_native_authority.sh
bash tests/run_semantics.sh
bash tests/run_diag.sh
bash tests/run_native.sh
```

Native cross-target and self-hosting gates:

```sh
bash tests/run_native.sh
bash tests/run_native_arm64.sh
bash tests/run_arm64_selfhost.sh
```

## Retired C-emitting compiler

The old `zagc` C-emitting compiler, its runtime, generated C files, and its
oracle suites are intentionally absent from this tree. They must not be
restored as a fallback. Use Git history if you need to study them:

```sh
git log --all -- zag-poc/selfhost/zagc.zag zag-poc/selfhost/codegen.zag
git show <commit>:zag-poc/selfhost/codegen.zag
```

The supported compiler is self-hosted `./znc`; x86-64 and ARM64 machine code,
WASM, and GPU MLIR frontend output are emitted by Zag sources without Python,
C, or Zig.  GPU MLIR is not physical GPU execution.
