# Installing Zag

## Prerequisites

- **x86-64 Linux** — the native backend emits x86-64 ELF; ARM and 32-bit are
  not yet supported
- **No other build tools required** — no `cc`, no `zig`, no `llvm`, no `make`
- Tested on: Ubuntu 22.04, Ubuntu 24.04, Fedora 40, Arch Linux (rolling)

The committed `./znc` binary is the only bootstrap dependency.

---

## Quick start (pre-built binaries)

```sh
git clone https://github.com/Sylorlabs/zag zag
cd zag/zag-poc
chmod +x znc bootstrap.sh tests/*.sh
```

Compile and run a Zag program:

```sh
./znc examples/numeric.zag -o numeric && ./numeric
```

Build and run in one native step:

```sh
./znc examples/numeric.zag -o numeric --run
```

---

## Build from source (bootstrap)

The bootstrap rebuilds `./znc` from its own Zag source using the committed seed
binary.  No host C compiler or assembler is invoked.

```sh
./bootstrap.sh
# Rebuilds: ./znc (from selfhost/native/znc.zag)
# The legacy ./zagc is NOT rebuilt by bootstrap.sh — it is not a supported path.
```

After bootstrap, verify the fixpoint (znc compiling itself produces an
identical binary):

```sh
bash tests/check_native_bootstrap_repro.sh
```

---

## Run the test suite

### v1 release gate (authoritative)

```sh
# Poisons cc/gcc/clang/as/ld in PATH, self-rebuilds znc, smoke-tests.
bash tests/run_native_authority.sh

# Native semantic, diagnostic, and backend suites.
bash tests/run_semantics.sh
bash tests/run_diag.sh
bash tests/run_native.sh
```

All four gates above must be green before shipping a release.

### Additional / informational

```sh
# Self-hosted compiler pipeline tests (28 tests, differential):
bash tests/run_selfhost.sh

# Language behaviour suite via the C-backend oracle (46 tests, differential):
bash run_tests.sh
```

These use `./zagc` (C backend) and are informational. A release does not invoke
them; the native authority, bootstrap, semantic, diagnostic, and backend gates
define release readiness.

---

## Permanent install

```sh
sudo make install
# Installs znc → /usr/local/bin/znc
```

Or manually:

```sh
sudo install -m755 znc /usr/local/bin/znc
```

After installing, you can compile Zag programs from anywhere:

```sh
znc myprogram.zag -o myprogram
./myprogram
```

### Optional: install the C-backend oracle

`./zagc` is available for differential testing but is **not supported for
production use**.

```sh
sudo install -m755 zagc /usr/local/bin/zagc
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Permission denied: ./znc` | `chmod +x znc` |
| `cannot execute binary file: Exec format error` | You are on ARM or 32-bit; the native backend is x86-64 only |
| `bootstrap: native seed ./znc is missing` | Restore from git: `git checkout HEAD -- znc` |
| bootstrap fixpoint mismatch | Release blocker: rebuild the seed to convergence and rerun the dedicated check |
| `run_native_authority.sh: strace unavailable` | Install strace: `sudo apt install strace`; authority test still passes via PATH poisoning alone |

---

## Compiler flags

```sh
# Compile to ELF (native backend):
./znc source.zag -o output

# Compile and run (native backend):
./znc source.zag -o output --run

# Format source or update it in place:
./znc fmt source.zag
./znc fmt --in-place source.zag

# Emit DWARF debug sections:
./znc source.zag -o output --debug
```

---

## What `./znc` is

`znc` (Zag Native Compiler) performs the full compilation pipeline in Zag:

```
source.zag
  → lex (selfhost/lex.zag)
  → parse (selfhost/parse.zag)
  → semantic analysis + effect proof (selfhost/sema.zag)
  → native codegen + register allocation + optimizer (selfhost/native/ncodegen.zag)
  → x86-64 encoding (selfhost/native/x86.zag)
  → ELF writer (selfhost/native/elf.zag)
  → static ELF binary (no libc, no dynamic loader)
```

The resulting binary uses Linux syscalls directly and has zero runtime
dependencies beyond the kernel.
