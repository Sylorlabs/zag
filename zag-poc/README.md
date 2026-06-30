# Zag compiler (`zag-poc`)

The supported compiler is `./znc`. It reads Zag source and writes a static x86-64 ELF binary, GPU MLIR (`--target gpu-*`), or WebAssembly (`--target wasm`). No `cc`, no `as`, no `ld`, no libc, no Zig, no LLVM.

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
bash tests/run_native_authority.sh
bash tests/run_semantics.sh
bash tests/run_diag.sh
bash tests/run_native.sh
```

Informational differential suites that still use the legacy C emitter:

```sh
bash run_tests.sh
bash tests/run_selfhost.sh
```

## Legacy `./zagc` path

`./zagc` emits C and shells out to the host compiler. It remains in the tree as a differential oracle only. It is not rebuilt by `bootstrap.sh` and it is not a supported build path. Multi-target builds (wasm, GPU, arm64, and the rest) live on that legacy path if you need them for comparison.

`prove.sh` exercises `@total` proofs through ghost_engine on the legacy path.