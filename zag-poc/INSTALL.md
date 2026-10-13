# Installing Zag

## Prerequisites

- **Linux x86-64** — host for the committed compiler seed and primary release
- **Linux AArch64** — scoped supported target and CI host; x86-64 can
  cross-compile it and verify it through qemu-user
- **Apple Silicon macOS** — scoped signed PIE Mach-O executable and bounded
  C-ABI object/archive development paths; a matching `znc-macos-arm64` seed is usable as release evidence only
  after the entire physical-Apple-Silicon gate passes
- **No compiler toolchain required** — no `cc`, `zig`, `llvm`, assembler, or
  linker; `make` is only an optional convenience for `make install`
- Tested on: Ubuntu 22.04, Ubuntu 24.04, Fedora 40, Arch Linux (rolling), and
  the physical Apple-Silicon macOS 15 CI gate

The committed `./znc` is the Linux bootstrap seed. Apple Silicon requires a
separate trusted `znc-macos-arm64` bootstrap seed; the tree does not treat the
Linux seed or a cross-emitted Mach-O file as a macOS release. A successful
physical-Mac CI gate publishes a distinct checksum-paired verified seed so a
clean checkout has a reviewable intake path without committing generated Mac
binaries.
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
The snippet above starts from the committed Linux x86-64 seed. On Apple
Silicon, complete the checksum-verified seed intake below first.

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

The durable route is a `macos-arm64` release archive: verify its outer
`.tar.gz.sha256` against the published release, extract it, and use the included
tools directly. To use that release compiler as the seed for a separate source
checkout, pass the extracted `znc` and `znc.sha256` to the helper described
below.

For an exact development commit without a release, open a successful
`test-macos-arm64-native` job for the
commit you reviewed and download its
`zag-znc-macos-arm64-verified-<commit>` artifact. Do not use the similarly named
`-cross-` artifact: it is only the bootstrap precursor supplied to the physical
Mac job. Confirm `SOURCE_COMMIT`, compare the SHA-256 printed in the job summary
with `znc-macos-arm64.sha256`, then run:

```sh
bash tools/bootstrap-macos-seed.sh \
  ~/Downloads/zag-macos-seed/znc-macos-arm64 \
  ~/Downloads/zag-macos-seed/znc-macos-arm64.sha256
```

For a verified release archive, the corresponding invocation is:

```sh
bash tools/bootstrap-macos-seed.sh \
  /path/to/zag-release/znc /path/to/zag-release/znc.sha256
```

The helper verifies bytes, signed Mach-O host identity, a source-built fixed
point, and an independent empty-`PATH` rebuild before creating
`znc-macos-arm64`, `zagd-macos-arm64`, and `zag-lsp-macos-arm64` in the
checkout. It deliberately performs no download and makes no trust decision for
you. An older reviewed seed can bootstrap later source, but only a complete
native gate can certify that later source.

Exercise the scoped native path directly:

```sh
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
The ordinary import-bearing executable path retains the writer's closed
libSystem/Metal/libobjc `extern fn` map; the generated executable contains its
own Mach-O bind stream and ARM64 import stubs. Strict edition-2027 projects can
emit Mach-O objects with `--emit-obj` and BSD static archives with
`--emit-static`. These require defined `pub @cabi_export` functions and scalar
integer/bool/raw-pointer exports, plus bounded `f32`/`f64` exports on Apple Silicon.
Imports may use the same scalar forms plus fixed `f32`/`f64` signatures using
Darwin's `V0`-`V7` FP bank and naturally packed stack overflow, plus direct captureless
scalar/pointer callbacks. Apple Silicon also accepts bounded f32/f64 callback signatures when the direct callback target is
`pub @cabi_export`; mixed FP/GPR and ten-`f32` callback entry are exercised natively.
Apple Silicon additionally supports ordinary named structs whose leaves are only
naturally aligned `i64`, `u64`, or raw pointers; leaves may be nested through
ordinary non-generic structs within the bounded recursive classifier. One- and two-word values use
Darwin's INTEGER aggregate class (`X` registers when they completely fit,
otherwise the whole value on the stack; `X0`/`X1` results). Larger values use
the caller-owned indirect copy and `X8` result convention. Object tests execute
both C-to-Zag and Zag-to-C directions, cover flat/nested small and large values,
and force the small-value stack-spill path.
Apple Silicon also accepts flat ordinary structs made only from naturally aligned
integer/`bool`/raw-pointer leaves when their Darwin C layout is at most 16 bytes.
The compiler explicitly packs/unpacks that byte layout from Zag's eight-byte
internal field slots. Native object and dylib/custom-link tests cover signed and
unsigned subword fields, padding, `bool`, raw pointers, one/two-register
arguments/results, and complete-value stack spill. Nested narrow/mixed-width
structs, mixed-layout structs larger than 16 bytes, HFA/HVA structs, unions, and
by-value `@repr(C)` remain rejected.
The native tests link and execute these forms with Apple's toolchain. Zag itself does not invoke that
external linker.

The same strict edition-2027 scalar/bounded-`f32`/`f64` plus both bounded struct import/export slices support
native dylib output and custom dynamically linked executables. Custom macOS
links also accept SDK `libNAME.tbd` fallback plus `-framework NAME` and `-F PATH`;
`.tbd` input is bounded to TAPI v4 install-name plus target-scoped direct symbol lists. Given a library with exported
`pub @cabi_export` definitions and an application with matching `@cabi` imports:

```sh
./znc-macos-arm64 library.zag --emit-dylib --install-name @rpath/libexample.dylib -o libexample.dylib
./znc-macos-arm64 app.zag --dynamic -L . -l example --rpath @loader_path -o app
./app
```

`--emit-shared` aliases `--emit-dylib`. `--needed path/to/libexample.dylib`,
source `@link`, and linked dependencies in the nearest/imported `zag.mod` use
the same bounded native dependency reader. Install names are taken from the
library; user-specified runtime paths precede discovered build directories.
Versioned symlinks and ARM64 slices in universal dylibs are tested. These
images are linked and signed by Zag itself, with no host linker or signer.

The same native linker accepts explicit ARM64 Mach-O object and BSD archive
inputs on dylib or custom-executable builds. Inputs can be positional or use
`--static-input`:

```sh
./znc-macos-arm64 library.zag helper.o --emit-dylib -o libexample.dylib
./znc-macos-arm64 app.zag --static-input libhelper.a --dynamic -o app
```

The static-input reader is bounded to 64 MiB regular-file snapshots and the
ARM64 Mach-O relocation/symbol families exercised by
`tests/run_macos_static_link.sh`; imported TLVP loads against dylib-exported
thread-local symbols are supported, and unresolved weak imports use dyld's
weak flat-lookup/null semantics. Static TLS-defining input sections and
authenticated-pointer relocations fail closed. Same- and cross-output-section
SUBTRACTOR constants are resolved by the native linker. Aggregate shapes outside
the bounded flat/nested 64-bit-leaf and flat small integer/bool/raw-pointer
slices, including HFA/HVA aggregates and unions, plus by-value `@repr(C)`, variadic, aggregate-callback,
callback-alias/capture/returned-callback forms, arbitrary foreign-object formats, and aggregate
globals remain unsupported. Custom linked
images permit checked access but reject hot/debug/exit-sanitizer combinations.
Scalar globals, bounded checked-access/sanitizer modes,
and `--debug` with audited imports have their separate native gates; this is
not complete instrumentation or whole-language memory safety. Unsupported
link requests must reject rather than silently produce a partial artifact.
`_zag_raw_syscall` retains Linux x86-64 source
numbers and only an audited literal subset is translated for Darwin; unknown
or computed numbers return `ENOSYS`.

### VS Code extension

Native release archives include `zag-lang.vsix` at the archive root. After
installing `zag-lsp`, install the client without Node.js tooling:

```sh
code --install-extension zag-lang.vsix
```

To rebuild the VSIX from a source checkout, use Node.js 22+ and the committed
lockfile. The package command produces the same unversioned filename used by CI
and release archives:

```sh
cd ../editors/vscode
npm ci
npm run package
code --install-extension zag-lang.vsix
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
fixtures use the writer's closed dyld-import map unless custom library inputs
select the separate bounded C-ABI native linker. Fixed `f32`/`f64` imports use
Darwin's independent FP/GPR argument banks; bounded exports use the same
independent banks on entry and return `f32` in `S0` or `f64` in `D0`. Zag's
internal f32 values are converted explicitly at this boundary. Ordinary
64-bit-leaf structs, including bounded ordinary nesting, use Darwin's small
INTEGER register/stack class or, when larger than 16 bytes, caller-copy/`X8`
indirect result convention;
flat ordinary integer/`bool`/raw-pointer structs with Darwin C layouts up to
16 bytes use an explicit byte-layout adapter and the same small INTEGER-class
complete-fit register/stack rule. Nested narrow/mixed-width aggregates,
mixed-layout aggregates larger than 16 bytes, HFA/HVA aggregates, unions,
by-value `@repr(C)`, aggregate
callbacks, variadics, callback aliases/captures, callbacks returned from C, and
unannotated floating-point callback targets remain
outside this contract. Neither path means general
foreign-object linking or Linux raw-syscall coverage on Darwin.
