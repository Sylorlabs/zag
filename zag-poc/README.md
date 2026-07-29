# Zag compiler (`zag-poc`)

The supported compiler is `./znc`. It writes a static x86-64 ELF binary,
WebAssembly (`--target wasm`), or GPU MLIR frontend output (`--target gpu-*`).
GPU MLIR output is not a GPU executable or dispatch runtime. No `cc`, no `as`,
no `ld`, no libc, no Zig, no LLVM.

## Zag Script

Zag Script is Zag's built-in low-friction profile. It provides concise safe
defaults for short programs and experiments while preserving a direct path into
explicit native Zag through inspection and hardening. Here, “safe defaults”
means bounded, documented, and fail-closed defaults for the implemented
profile; it is not a claim of general ownership, borrowing, or memory safety.

```sh
./znc script examples/script_hello.zag --run
./znc explain examples/script_hello.zag
./znc harden examples/script_harden.zag
./znc check examples/script_hello.zag --strict
```

See [the Zag Script guide](docs/ZAGSCRIPT_GUIDE.md), [its exact semantics and
safety boundary](docs/ZAGSCRIPT_SEMANTICS.md), and [the `zagd`
guide](docs/ZAGD_GUIDE.md). A `.zag` file containing `script;` selects the same
compiler profile as `znc script`; Zag Script is not a second compiler or type
system.

```sh
./znc examples/numeric.zag -o numeric --run
```

Rebuild the compiler from source:

```sh
./bootstrap.sh
bash tests/run_native_authority.sh
```

`bootstrap.sh` performs three sequential self-host generations, requires a
byte-identical stage-2/stage-3 fixpoint, and by default uses a swap-disabled
low-priority user cgroup when available. An operator can explicitly allow a
bounded compiler-cgroup swap allowance; that is not a no-swap certification.
Its workstation limit preserves 2 GiB
of currently available memory and never exceeds 60% of physical RAM. See
[the self-host memory policy](docs/SELFHOST_MEMORY_POLICY.md) for explicit
limits, the opt-out boundary, and the separate measured regression gate.

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

`--debug` is the only supported native debug-output request; it appends the
current bounded DWARF metadata.  `-g`, parameterized/alternate debug spellings,
strip controls, and assembly/IR-output requests are rejected rather than
silently writing an ordinary executable.

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
bash tests/run_zagscript_release_gate.sh # Zag Script Linux x86-64 first release
bash tests/run_zagscript_master_gate.sh  # expensive sequential local evidence gate
bash tests/run_i686_release_gate.sh      # authoritative bounded Linux/i686 gate
bash tests/run_programs.sh             # programs/*.zag integration gate only
bash tests/run_native_authority.sh
bash tests/run_semantics.sh
bash tests/run_diag.sh
bash tests/run_native.sh
```

The Zag Script gate fails if any required focused or existing release suite
fails. It does not certify the separate i686 milestone, the broader Zag v2
roadmap, or physical GPU execution. `run_i686_release_gate.sh` is the single
authority for the documented bounded Linux/i686 target: mandatory evidence
uses the compiler's own ELF32 emitter, archive writer, and linker with host
`ld`, `ar`, `cc`, `readelf`, and `objdump` disabled, then executes natively or
through `qemu-i386`. The master gate additionally rebuilds to a fixpoint, runs
the remaining distinct v1 compatibility authority (including existing ARM
compatibility gates), then runs that i686 authority, exercises the default no-swap or explicitly recorded
bounded-swap memory gate, and records 30-run benchmarks. It still does not
promote the documented i686 subset to complete language/public-C-ABI,
dynamic/TLS, or external-distribution parity, or turn unsupported v2/GPU work
into a release claim.

Zag v2 is an active, fail-closed development track rather than a production
release. Its matrix and executable gate are in
[docs/V2_FINAL_VERIFICATION.md](docs/V2_FINAL_VERIFICATION.md) and
`tests/run_v2_release_gate.sh`; required unsupported rows deliberately keep
that gate failing until their implementation and execution evidence exist. The
release gate is intentionally fail-closed while required capability rows
remain unsupported; it is not a C replacement or a production-v2 claim yet.
The latest authoritative local run (2026-07-29) completed all 38 executable
rows and then failed the 10 required unsupported rows. That is strong
development evidence, not a production release result.
The passing slices include
checked native word and byte volatile transactions, fixed unsafe i64 atomic
load/store/exchange/compare-exchange/fetch-add/sub/and/or/xor operations, bounded Linux futex wait/wake building blocks, a guarded direct-worker Linux spawn/join boundary, scalar plus bounded `f64` `@cabi` dynamic imports, validated x86
POPCNT/ANDN/trailing-zero intrinsics, bounded SSE2 four-lane integer
add/subtract/and/or/xor operations,
and bounded native memory sanitizer coverage. General atomics/concurrency,
pointer/allocator lifetime, full C ABI, portable SIMD/checked inline assembly,
and physical GPU execution remain explicitly fail-closed; unsupported
native object, static, and shared-object requests also fail closed rather than
silently producing the wrong artifact. The
atomic slice has compiler-reserved `AtomicI64` storage with unsafe receiver-only
operations, plus legacy raw i64 pointer transactions, a separate raw i32 futex
word boundary, and a Linux/x86-64 unsafe join-only worker slice; it is not a
general memory-order or threading model. The passing count is refreshed only by
an authoritative post-bootstrap release-gate run.
Its current checked native x86-64 allocator slice is
[`SystemAllocator`](docs/V2_ALLOCATOR_GUIDE.md): fallible allocate, zeroed
allocate, resize, and deallocate use capacity/alignment/generation-validated
handles. `Allocation` is compiler-opaque and affine: insertion into a local
aggregate moves the capability, the original binding becomes unavailable,
aggregate copies cannot duplicate it, and consuming an aggregate field
invalidates every alias to the same identity. A successful aggregate-field
`resize` applies the same transition and mints one live replacement. A
non-extern `@consumes @returns_owner` helper may make the same transfer only
when every terminal path returns its one exact `Allocation` parameter; the
annotation cannot authorize a fresh or ambiguous owner. Bounded retained
`fixed_buffer_allocator(...)` and `arena_allocator(...)` regions implement
checked byte access, generation-invalidating reset, and explicit `deinit`;
they do not establish a general allocator or heap-graph lifetime model. Legacy
`@memoryFence` emits `mfence` but is unsafe and is not a typed memory-order API.
This is not a raw-pointer memory-safety guarantee or a v2 release claim.

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
