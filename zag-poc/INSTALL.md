# Installing Zag

## Prerequisites

- **x86-64 Linux, ARM64 Linux, or Apple Silicon macOS** — native ELF is
  supported on Linux and signed Mach-O is supported on macOS arm64;
  Linux x86-64 can cross-compile either ARM64 format
- **No other build tools required** — no `cc`, no `zig`, no `llvm`, no `make`
- Tested on: Ubuntu 22.04, Ubuntu 24.04, Fedora 40, Arch Linux (rolling)

The committed `./znc` is the Linux bootstrap seed. Apple Silicon uses the
`znc-macos-arm64` release/CI artifact as its bootstrap seed.

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

### Apple Silicon macOS

Download the `znc-macos-arm64` artifact, make it executable, and run it directly:

```sh
chmod +x znc-macos-arm64
./znc-macos-arm64 examples/numeric.zag -o numeric --run
```

A macOS-hosted compiler defaults to signed `macos-arm64` output. The explicit
spelling is useful for cross-compilation and reproducible scripts:

```sh
./znc-macos-arm64 examples/numeric.zag --target macos-arm64 -o numeric
./numeric
```

The Mach-O writer, PIE address lowering, SHA-256 ad-hoc signer, Darwin entry ABI,
and syscall runtime are all implemented in Zag. No Xcode, system assembler,
linker, `codesign`, C, Python, or Zig is invoked to produce the executable.
External library linking, `--debug`, and `--hot` are not yet available on this
target and are rejected instead of silently producing a partial artifact.

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

### Native Apple Silicon macOS gate

Run this on an ARM64 Mac with the `znc-macos-arm64` seed (or a self-hosted
generation) selected through `ZNC`. It verifies signed Mach-O emission, the
Darwin loader and syscall runtime, and the byte-identical macOS self-hosting
fixpoint:

```sh
ZNC=./znc-macos-arm64 bash tests/run_macos_arm64_release.sh
```

---

## Permanent install

```sh
sudo make install
# Installs znc, zagd, zagd-user-service, and zagd-launchd-service → /usr/local/bin
# Installs the strict and Script standard-library modules → /usr/local/lib/zag/std
# Installs the editable project policy template → /usr/local/share/zag/zagd.conf.example
```

Or manually:

```sh
sudo install -m755 znc zagd /usr/local/bin/
sudo install -m755 tools/zagd-user-service.sh /usr/local/bin/zagd-user-service
sudo install -m755 tools/zagd-launchd-service.sh /usr/local/bin/zagd-launchd-service
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

On Apple Silicon macOS, `zagd` uses a native Darwin `kqueue` vnode watch for
the project root because inotify is Linux-only. It falls back to bounded
polling only if native event setup fails and supports the same watch/status/
shutdown lifecycle; it never affects foreground compiler correctness.
Use `--no-zagd` on an individual foreground command when a hermetic invocation
must not start or contact the background service; this never changes project
configuration.

To use the shipped bounded defaults and change them per project, copy the
template rather than editing installed files:

```sh
cp /usr/local/share/zag/zagd.conf.example .zagd.conf
```

The default `mode=light` keeps the daemon resident; change only `mode=off` to
make a persistent opt-out. Explicit compiler choices still override Script
defaults in the file, and normal Zag remains advisory-only.

To keep a project planner active across login and restart it after an
unexpected exit, use the native service manager:

```sh
zagd-user-service install myprogram.zag adaptive
```

On Apple Silicon macOS, use the equivalent `launchd` adapter:

```sh
zagd-launchd-service install myprogram.zag adaptive
```

Both services are per project, use the same `.zagd.conf` policy, and are never
a foreground build correctness dependency.

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

`znc` (Zag Native Compiler) performs the full compilation pipeline in Zag.
On Linux x86-64 the default path is:

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

The Linux result uses Linux syscalls directly and has no runtime dependency
beyond the kernel. The Apple Silicon result uses the Darwin entry/syscall ABI,
is position-independent, carries a deterministic embedded ad-hoc signature,
and loads through macOS dyld without compiler-generated symbol imports.
