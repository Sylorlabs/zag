# Zag — the bootstrap, and how to walk its history

Zag is a from-scratch, self-hosting systems language. The compiler that builds
Zag is **written in Zag**, and the native backend emits ELF executables **with
no `cc`, `as`, `ld`, `libc`, `Zig`, or `LLVM`** — only the CPU instruction set,
the ELF format, and the Linux syscall ABI sit beneath it.

Like every self-hosted language (Rust started in OCaml, Go in C, Zig in C++),
Zag was bootstrapped from a compiler written in another language, then that
bootstrap was retired once Zag could compile itself. This file records that
journey so anyone can walk it — **including recovering the original bootstrap.**

## The chain, in one line

```
Python (zagc.py, removed)  →  Zig bootstrap (src/*.zig, removed at v0.1)
                          →  self-hosted C-backend (selfhost/*.zag, differential oracle)
                          →  native backend (selfhost/native/*.zag)
                          →  Zig DELETED  →  numeric system in native code
```

The Python prototype (`zagc.py`) and `gpu/*.py` middlemen are no longer in the tree.
Recover them from git history (`git show v0.0-zig-bootstrap:zag-poc/zagc.py`) if needed.

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

## Recovering the original Zig bootstrap

The Zig bootstrap (~10,500 lines) was removed at `v0.1-native-selfhost`, but git
never forgets. To see it or build from it:

```sh
# read a file from the bootstrap without changing your tree:
git show v0.0-zig-bootstrap:zag-poc/src/main.zig

# or check the whole bootstrap tree out:
git checkout v0.0-zig-bootstrap        # full Zig bootstrap: src/*.zig + build.zig
zig build                              # builds the bootstrap → ./zagc
git checkout -                         # back to the latest, Zig-free tree
```

## Supported v1 bootstrap — native only

The committed `./znc` binary is the trusted bootstrap seed. `bootstrap.sh`
rebuilds the supported compiler directly from Zag source:

```sh
./bootstrap.sh
#   ./znc selfhost/native/znc.zag -o znc.new
#   znc.new -> ./znc
```

`./znc` is the only supported v1 compiler. It performs lexing, parsing, semantic
analysis, optimization, x86-64 encoding, and ELF writing in Zag. Its generated
programs use Linux syscalls and have no dynamic loader or libc dependency.

`./zagc` and `selfhost/codegen.zag` remain in the repository as historical
bootstrap material and a differential oracle. They are not a supported build
path, are not an acceptable bootstrap fallback, and must not be required by a
release gate. C interoperability, when intentionally added later, is an optional
boundary rather than an implementation dependency.

## The one permanent caveat

You can never compile from *absolutely nothing* — there is always one trusted
**seed binary** that builds the next (this is true for every self-hosted
language). "No Zig" means the Zig *source* is gone from the working tree and the
build; you bootstrap from the committed seed, and the original Zig bootstrap
stays preserved in history at `v0.0-zig-bootstrap` as the reproducibility
safety net.

## Supported release gates

```sh
./tests/run_native_authority.sh  # poison host C tools; self-rebuild and smoke test
./tests/run_native.sh            # native language/backend behavior suite
```

The older `run_tests.sh` and `tests/run_selfhost.sh` suites exercise the legacy
C emitter. They remain useful for differential testing but do not define v1
support or release readiness.
