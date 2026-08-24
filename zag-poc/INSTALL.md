# Installing Zag

## Prerequisites

- **Linux x86-64** — host for the committed compiler seed and primary release
- **Linux AArch64** — scoped supported target and CI host; x86-64 can
  cross-compile it and verify it through qemu-user
- **Apple Silicon macOS** — scoped signed PIE Mach-O executable development
  path; a matching `znc-macos-arm64` seed is usable as release evidence only
  after the entire physical-Apple-Silicon gate passes
- **No compiler toolchain required** — no `cc`, `zig`, `llvm`, assembler, or
  linker; `make` is only an optional convenience for `make install`
- Tested on: Ubuntu 22.04, Ubuntu 24.04, Fedora 40, Arch Linux (rolling)

The committed `./znc` is the Linux bootstrap seed. Apple Silicon requires a
separate trusted development/CI `znc-macos-arm64` bootstrap seed; the tree does
not treat the Linux seed or a cross-emitted Mach-O file as a macOS release.
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

### Apple Silicon macOS

With a trusted matching development/CI `znc-macos-arm64` seed, make it
executable and exercise the scoped native path directly:

```sh
chmod +x znc-macos-arm64
./znc-macos-arm64 examples/numeric.zag -o numeric --run
```

A macOS-hosted compiler defaults to signed `macos-arm64` executable output.
The explicit spelling is useful for cross-compilation and reproducible scripts:

```sh
./znc-macos-arm64 examples/numeric.zag --target macos-arm64 -o numeric
./numeric
```

The Mach-O writer, PIE address lowering, SHA-256 ad-hoc signer, Darwin entry ABI,
and syscall runtime are all implemented in Zag. No Xcode, system assembler,
linker, `codesign`, C, Python, or Zig is invoked to produce the executable.
Native dyld binding is available only for the writer's closed
libSystem/Metal/libobjc `extern fn` map; the generated executable contains its
own Mach-O bind stream and ARM64 import stubs. Mach-O object, archive, and
shared-library output, BSS-backed edition-2027 globals, checked safety and
memory sanitizing, `--debug` with imports, arbitrary dylib install names, and
general `-l`/`-L` linking are unsupported and must reject rather than silently
producing a partial artifact. `_zag_raw_syscall` retains Linux x86-64 source
numbers and only an audited literal subset is translated for Darwin; unknown
or computed numbers return `ENOSYS`.

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

### Host-scoped v1 release gate (authoritative)

```sh
make test

# Individual evidence rows are also available:
# Poisons cc/gcc/clang/as/ld in PATH, self-rebuilds znc, smoke-tests.
bash tests/run_native_authority.sh

# Native semantic, diagnostic, and backend suites.
bash tests/run_semantics.sh
bash tests/run_diag.sh
bash tests/run_native.sh  # Linux native-backend row
```

`make test` runs neutral conformance plus the native rows for the current host.
On Apple Silicon this means signed Mach-O fixed-point, Darwin runtime,
dyld/Metal, ARM64 object, tooling, diagnostics, and program evidence. Linux-only
ELF, qemu, DRM, and hot-reload rows stay explicit rather than being treated as
Darwin failures. Every row claimed for a release platform must be green before
shipping that platform's artifact.

### Cross-target native gates

```sh
bash tests/run_native_arm64.sh
bash tests/run_differential.sh
bash tests/run_arm64_selfhost.sh
```

On x86-64 these use qemu-user only to execute ARM64 output. The compiler remains
pure Zag and does not use Python, C, or Zig.

### Native Apple Silicon macOS gate

Run this on an ARM64 Mac with a matching `znc-macos-arm64` seed (or a
self-hosted generation) selected through `ZNC`. It attempts signed Mach-O
emission, the Darwin loader and syscall runtime, and the byte-identical macOS
self-hosting fixpoint:

```sh
ZNC=./znc-macos-arm64 bash tests/run_macos_arm64_release.sh
```

Every row must pass before that seed is release-eligible. A partial run proves
only the completed fixture and does not broaden the output, edition, linking,
or syscall boundary in `docs/SUPPORT.md`.

---

## Permanent install

```sh
sudo make install
# Installs znc, zagd, zag-lsp, zagd-user-service, and the macOS
# zagd-launchd-service helper → /usr/local/bin
# Installs the strict and Script standard-library modules → /usr/local/lib/zag/std
# Installs the editable project policy template → /usr/local/share/zag/zagd.conf.example
```

Or manually on Linux x86-64. Apple Silicon and Linux ARM installations should
use `make install`, which selects and renames the platform-qualified compiler,
daemon, and LSP artifacts correctly:

```sh
./znc selfhost/lsp/zag-lsp.zag -o zag-lsp --no-zagd
sudo install -m755 znc zagd zag-lsp /usr/local/bin/
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

The default `mode=adaptive` keeps one bounded daemon resident and permits
deeper analysis only under the configured policy. Change `mode=off` to make a
persistent opt-out. Explicit compiler choices still override Script defaults,
normal Zag remains review-only, and the capability matrix—not the policy
setting—is the authority on which optimizer behaviors are implemented.

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
beyond the kernel. Within the scoped Apple Silicon executable path, output uses
the Darwin entry ABI, is position-independent, carries a deterministic
embedded ad-hoc signature, and loads through macOS dyld. Supported `extern fn`
fixtures use the writer's closed dyld-import map; this is not a general linker
or a claim that Linux raw-syscall coverage carries over to Darwin.
