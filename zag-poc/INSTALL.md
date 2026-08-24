# Installing Zag

## Prerequisites

- **Linux x86-64** — host for the committed compiler seed and primary release
- **Linux AArch64** — scoped supported target and CI host; x86-64 can
  cross-compile it and verify it through qemu-user
- **No other build tools required** — no `cc`, no `zig`, no `llvm`, no `make`
- Tested on: Ubuntu 22.04, Ubuntu 24.04, Fedora 40, Arch Linux (rolling)

The committed `./znc` binary is the only bootstrap dependency.
Read [`docs/SUPPORT.md`](docs/SUPPORT.md) before choosing a target; support is
scoped by output mode and language edition rather than claimed as universal
backend parity.

---

## Quick start (pre-built binaries)

```sh
git clone https://github.com/Sylorlabs/zag zag
cd zag/zag-poc
chmod +x znc bootstrap.sh tests/*.sh
sudo make install
```

`make install` builds and installs `znc`, `zagd`, and `zag-lsp`.

Create a project:

```sh
mkdir my-zag-app && cd my-zag-app
znc init --name my-zag-app
znc src/main.zag -o app --run
znc tests/smoke.zag -o smoke --run
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
# Rebuilds: ./znc and builds sibling ./zagd in pure Zag
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

### Cross-target native gates

```sh
bash tests/run_native_arm64.sh
bash tests/run_differential.sh
bash tests/run_arm64_selfhost.sh
```

On x86-64 these use qemu-user only to execute ARM64 output. The compiler remains
pure Zag and does not use Python, C, or Zig.

---

## Permanent install

```sh
sudo make install
# Installs znc, zagd, zag-lsp, and zagd-user-service → /usr/local/bin
# Installs the strict and Script standard-library modules → /usr/local/lib/zag/std
# Installs the editable project policy template → /usr/local/share/zag/zagd.conf.example
```

Or manually:

```sh
./znc selfhost/lsp/zag-lsp.zag -o zag-lsp --no-zagd
sudo install -m755 znc zagd zag-lsp /usr/local/bin/
sudo install -m755 tools/zagd-user-service.sh /usr/local/bin/zagd-user-service
sudo install -d /usr/local/lib/zag/std
sudo install -m644 std/*.zag /usr/local/lib/zag/std/
sudo install -m644 selfhost/std/process.zag selfhost/std/script_*.zag \
  /usr/local/lib/zag/std/
sudo install -d /usr/local/share/zag
sudo install -m644 examples/zagd.conf /usr/local/share/zag/zagd.conf.example
```

After installing, you can compile Zag programs from anywhere:

```sh
znc myprogram.zag -o myprogram
./myprogram
```

Ordinary source commands attempt to start one `zagd` per project. Planner
failure only emits a warning and never blocks foreground correctness. Control it
explicitly with `znc watch --mode light|adaptive|deep|off`, `znc status`,
`znc suggest`, and `znc shutdown`. A project may set `mode=off` (or another
mode) in `.zagd.conf`. The daemon never rewrites source and regular Zag
suggestions are advisory.
Use `--no-zagd` on an individual foreground command when a hermetic invocation
must not start or contact the background service; this never changes project
configuration.

To use the shipped bounded defaults and change them per project, copy the
template rather than editing installed files:

```sh
cp /usr/local/share/zag/zagd.conf.example .zagd.conf
```

The default `mode=adaptive` keeps one bounded daemon resident and permits
deeper analysis only under the configured policy. Change `mode=off` to make a
persistent opt-out. Explicit compiler choices still override Script defaults,
normal Zag remains review-only, and the capability matrix—not the policy
setting—is the authority on which optimizer behaviors are implemented.

To keep a project planner active across login and restart it after an
unexpected exit, install its bounded systemd user service:

```sh
zagd-user-service install myprogram.zag adaptive
```

The service is per project, uses the same `.zagd.conf` policy, and is never a
foreground build correctness dependency.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Permission denied: ./znc` | `chmod +x znc` |
| `cannot execute binary file: Exec format error` | The compiler binary does not match the host architecture; use the matching release seed |
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
