# Zag — the bootstrap, and how to walk its history

Zag is a from-scratch, self-hosting systems language. The compiler that builds
Zag is **written in Zag**, and the native backend emits Linux ELF or Apple
Silicon Mach-O executables **with no `cc`, `as`, `ld`, `libc`, `Zig`, or
`LLVM`** — only the CPU instruction set and the target object/runtime ABI sit
beneath it.

Like every self-hosted language (Rust started in OCaml, Go in C, Zig in C++),
Zag was bootstrapped from a compiler written in another language, then that
bootstrap was retired once Zag could compile itself. This file records that
journey so anyone can walk it — **including recovering the original bootstrap.**

## The chain, in one line

```
Python prototype (removed) → Zig bootstrap (removed at v0.1)
                           → self-hosted C emitter (removed)
                          →  native backend (selfhost/native/*.zag)
                          →  pure Zag self-hosting toolchain
```

The Python prototype, Zig bootstrap, C emitter, C runtime, and generated C files
are no longer in the tree. Recover historical implementations only through Git
history; they are not valid bootstrap fallbacks.

## Walk the history by tag

```
git tag -n1 -l 'v0.*'
```

| Tag | What it marks |
|-----|----------------|
| `v0.0-zig-bootstrap`   | **The last state WITH the Zig bootstrap** (`src/*.zig`, `build.zig`). The seed compiler. |
| `v0.1-native-selfhost` | Zag builds Zag — the Zig bootstrap is **deleted**; the toolchain now bootstraps from a committed seed binary. |
| `v0.2-phase-d-optim`   | Phase D: the native optimizer (register promotion + constant folding + stack-temp elimination + immediate selection). |
| `v0.3-cc-free`         | The **whole toolchain** builds via `znc` with **zero external tools**; the native `zagc` is fully equivalent (46/46 + 28/28). |
| `v0.4-numerics-native` | The heterogeneous numeric system (posits / 512-bit quire / saturating / RNS / bignum / fixed-point / arbitrary-width) ported into the **native machine-code** backend — numeric programs compile straight to ELF, no `cc`. |

## Inspecting retired bootstraps

Git retains the retired Python, Zig, and C-emitting implementations for
historical inspection:

```sh
# read a file from the bootstrap without changing your tree:
git show v0.0-zig-bootstrap:zag-poc/src/main.zig

# inspect the retired C emitter without restoring it:
git log --all -- zag-poc/selfhost/zagc.zag zag-poc/selfhost/codegen.zag
git show <commit>:zag-poc/selfhost/codegen.zag
```

## Supported v1 bootstrap — native only

The committed `./znc` binary is the trusted bootstrap seed. `bootstrap.sh`
rebuilds it directly from Zag source:

```sh
./bootstrap.sh
#   ./znc selfhost/native/znc.zag -o znc.new
#   znc.new -> ./znc
```

### Single compiler binary

| Binary | Source | Role |
|--------|--------|------|
| `./znc` | `selfhost/native/znc.zag` | Native x86-64 compiler **plus** GPU MLIR and WASM backends. Default: `./znc file.zag -o program`. GPU: `--target gpu-nvidia|gpu-amd|gpu-vulkan`. WASM: `--target wasm -o out.wasm`. |

`selfhost/mlir.zag` is a native Zag implementation and does not depend on a
Python, C, or Zig emitter.

`selfhost/native/znc_target.zag` remains as an optional legacy helper (build
with `./znc selfhost/native/znc_target.zag -o znc-target`) for differential
checks; it is not required for normal use.

Generated Linux programs use Linux syscalls and have no dynamic loader or libc
dependency. Apple Silicon macOS programs are signed PIE Mach-O executables that
use the Darwin entry/syscall ABI and load through dyld.

The retired `zagc`, C emitter, runtime, and oracle suites exist only in Git
history. Do not restore them to the current tree or use them as a fallback.

## The one permanent caveat

You can never compile from *absolutely nothing* — there is always one trusted
**seed binary** that builds the next (this is true for every self-hosted
language). "No Zig" means the Zig *source* is gone from the working tree and the
build; you bootstrap from the committed seed, and the original Zig bootstrap
stays preserved in history at `v0.0-zig-bootstrap` as the reproducibility
safety net.

## Supported release gates

```sh
./tests/run_native_authority.sh       # poison host C tools; self-rebuild and smoke test
./tests/run_native.sh                 # native language/backend behavior suite
bash tests/run_native_gpu.sh          # GPU MLIR via ./znc --target gpu-*
bash tests/run_native_wasm.sh         # WASM binary emission via ./znc --target wasm
bash tests/run_native_total.sh        # @total proofs on ./znc
./tests/check_native_bootstrap_repro.sh  # byte-identical ./znc fixpoint
./tests/check_native_target_repro.sh     # optional: byte-identical ./znc-target fixpoint
```

ARM64 Linux is cross-compiled and self-hosted from the x86-64 `znc` seed; QEMU
may execute those binaries on x86-64 as test infrastructure. Apple Silicon
macOS uses the `znc-macos-arm64` release/CI seed and is verified natively with
the Darwin Mach-O release gate.
