# Apple Silicon macOS native support contract

This document refines the authoritative row in `docs/SUPPORT.md`. The
`macos-arm64` is a first-class native target, not a Linux compatibility layer.
Equivalent user-facing capabilities may use Darwin-specific mechanisms, while
every support claim remains evidence-gated. A backend implementation or one
passing fixture does not imply parity for unrelated features.

## Current scoped capability

| Area | Evidence-bearing path | Boundary |
|---|---|---|
| Native output | `znc source.zag --target macos-arm64 -o app` | signed PIE ARM64 Mach-O executable with Darwin `LC_MAIN`, `__TEXT`/`__DATA`, PIE-relative data addresses, and a deterministic embedded ad-hoc signature |
| Relocatable output and C interoperability | `tests/run_macos_object.sh`, `tests/run_macos_object_encoder.sh` | strict edition-2027 `--emit-obj` Mach-O objects and `--emit-static` BSD archives; scalar integer/pointer plus bounded `f32`/`f64`, ordinary flat/nested 64-bit-leaf structs, and flat small integer/bool/raw-pointer structs with explicit C byte-layout adaptation for `@cabi` imports and `pub @cabi_export` definitions; includes small INTEGER-class register/stack and large 64-bit-leaf indirect paths; direct captureless scalar/pointer callbacks and bounded f32/f64 callbacks whose direct targets are `pub @cabi_export`; deterministic bytes, mixed-width C stack arguments, globals, literals, allocation and checked access; Apple's linker is the interoperability oracle, not the implementation |
| Native dynamic libraries and custom linking | `tests/run_macos_dylib.sh`, `tests/run_macos_dylib_format.sh` | strict edition-2027 scalar/bounded-`f32`/`f64` plus ordinary flat/nested 64-bit-leaf and flat small integer/bool/raw-pointer struct import/export, including small register/stack and large 64-bit-leaf indirect paths; direct scalar callbacks and explicit-export bounded f32/f64 callbacks for `--emit-dylib`/`--emit-shared` and explicitly `--dynamic` custom executables; `-l`/`-L`, `--needed`, bounded TAPI-v4 SDK library and `-framework`/`-F` lookup, source/manifest links, install names, runtime paths, checked access, deterministic signing, 305 exports, data-pointer rebase/bind, and real C/Zag/C execution without a host linker in the implementation |
| Static Mach-O inputs | `tests/run_macos_static_link.sh` | explicit ARM64 Mach-O `.o` and BSD `.a` inputs, positional or `--static-input`, merged by Zag into native dylib/custom-executable output; demand-driven transitive archive extraction, COMMON and strong/weak resolution, private-external visibility, resolved/unresolved weak-import null semantics, absolute/data/page fixups, imported/local GOT loads, imported TLVP loads against dylib-exported thread-local symbols, both `POINTER_TO_GOT` forms, same/cross-output-section subtractors, symlinked inputs, deterministic CLI forms, and output-preserving negative cases are executed natively |
| External-link request validation | `tests/run_macos_link_options.sh`, `tests/run_macos_dylib.sh` | linking requests on non-linking output modes, missing values, malformed/unresolved libraries and conflicting options reject without replacing caller-owned output; source-only dependency paths remain valid |
| v1 runtime slice | native runtime fixture on Apple Silicon | arguments, strings/data, heap, basic file I/O, bounded process execution, stdout, and exit status only as exercised by the native gate |
| Closed dyld imports | positive and negative import-bearing executable fixtures | the original executable path retains its exact compiler-validated libSystem/Metal/libobjc symbol-and-ABI allowlist, bind stream and ARM64 stubs; its libSystem witnesses include fixed `f32`/`f64`, mixed FP/X-register calls, and a direct Zag callback through `qsort`, while custom linking uses the separate native dependency resolver and bounded C ABI contract above |
| Metal/GPU runtime | `tests/run_gpu_platform.sh`, `tests/run_compat_metal.sh`, `tests/run_macos_metal_loader.sh`, `tests/run_macos_metal_native_profiles.sh` | Apple Silicon is a ready first-class Metal platform: `--target gpu-metal` emits deterministic MSL for the reviewed fill, depth-write, and depth-tested fixed-point RGB blend profiles; the public native adapter discovers the physical device/queue, queries capabilities, verifies shared-memory transfer, compiles MSL through Metal.framework, submits and waits, reads results back, and releases owned resources. Physical witnesses match the bounded Linux GFX10.1 profile outcomes for depth and alpha 0/128/256 blend; the legacy `metal-compat` spelling remains deterministic and source-compatible |
| Debug information | `tests/run_macos_debug.sh`, `tests/run_macho_debug_writer.sh` | page-aligned self-hosted DWARF for standalone and import-bearing executables; signature and section inspection plus actual native execution and cold/warm cache equivalence; explicit hot-mode text permissions are tested separately from ordinary immutable text |
| Source-level C layout | `tests/run_repr_c_layout.sh` | edition-2027 `@repr(C)` pointer-only integer/bool/raw-pointer layout executes as signed ARM64 Mach-O with exact offsets/stride and narrow loads/stores; qualified imports and ordinary-layout isolation are covered, while by-value, nested/generic, float, and broader representation forms remain fail-closed or unsupported |
| CPU and v2 slices | `tests/run_macos_scalar_intrinsics.sh`, `tests/run_macos_machine_control.sh`, explicit atomic fixtures | the same compiler-owned popcount/ANDN-semantics/leading-zero/trailing-zero/byte-swap scalar operations as native x86-64, lowered to mandatory AArch64 `CNT`/`ADDV`/`UMOV`, `BIC`, `CLZ`, `RBIT`, and `REV`; baseline `PRFM`, bounded NEON i32x4 arithmetic/bitwise operations, ARMv8 fences, and LL/SC atomic witnesses; these do not establish complete edition-2027 target support |
| Scalar globals and checked access | `tests/run_macos_checked_safety.sh` | zero-initialized PIE-relative scalar cells, local shadowing and address-taking; null, alignment, index-overflow, bounds, use-after-free, and requested-length sanitizer checks; sanitizer small allocations carry a distinct 16-byte `0xD3` trailing red zone that catches out-of-band libSystem mutation before free and quarantined payloads are overwritten with `0xA5`, verified through an out-of-band stale libSystem read; dedicated sanitizer allocations above 512 KiB append a 16 KiB `PROT_NONE` page and poison the exact logical payload with `0xA5` before unmap, with both an independent Darwin `mprotect` probe and an allocator-owned libSystem `qsort` guard-page probe physically terminating with `SIGBUS`; statically evident leaks reject before codegen, while a deliberately false foreign consume contract is caught by the exit-time allocator check |
| Threads and atomic workers | `tests/run_macos_thread_spawn.sh` | the same bounded unsafe `@threadSpawn(fn() void)` / `@threadSpawn(fn(i64) void, value)` / consuming `@threadJoin(*opaque)` surface as Linux; compiler-owned `pthread_create`/`pthread_join` imports, an ARM64 C-ABI trampoline that restores Zag process context, checked-mode atomic worker execution, scalar argument copying, affine-handle enforcement, and signed Mach-O runtime evidence all execute natively |
| Atomic wait/wake | `tests/run_macos_atomic_wait_wake.sh` | the same unsafe `@atomicWait32` / `@atomicWake32` language surface as Linux, with non-null four-byte-aligned i32 pointer checks, raw `-EAGAIN` mismatch behavior, exact wake counts, and physical two-worker blocking/wake evidence; Darwin implements it with compiler-owned pthread mutex/condition state rather than Linux futex syscalls |
| Foreground machine cache | `tests/run_foreground_cache_integration.sh`, `tests/run_macos_filesystem_abi.sh` | actual code/data payload substitution; CPU-request and policy identities; bounded no-follow reads, corruption repair and concurrent publication; a sparse 512 MiB entry is rejected without reading it into memory |
| Native live text replacement | `tests/run_macos_hot_reload.sh` | running-PID replacement of page-aligned same-layout text with native cache synchronization; incompatible text/data/safety layouts reject; ordinary non-hot text remains non-writable |
| Clock, entropy, and filesystem services | `tests/run_os_macos_services.sh` | `std:os_macos` maps the portable clock and secure-random service contract to libSystem `clock_gettime` and `arc4random_buf`; the macOS-only surface adds the sleep-inclusive `mach_continuous_time` clock and APFS `clonefile` copy-on-write cloning, with deterministic signed Mach-O and ABI checks |
| Bounded concurrency service | `tests/run_macos_concurrency_services.sh` | `std:macos_channel_i64` and the async-worker reference app provide the Linux channel/worker role through Darwin shared memory, atomics, pthread workers, and `EVFILT_USER` kqueue notifications; kernel probe, timeout, join, signing, and reproducible-build checks pass natively |
| Dynamic plugin lifecycle | `tests/run_reference_dynamic_plugin_macos.sh` | `std:dynamic_plugin` uses the same bounded runtime load/resolve/call/unload contract through Darwin `dlopen`/`dlsym`/`dlclose`; the host is a signed Mach-O and the plugin is a runtime-loaded `.dylib`, with negative lifecycle cases |
| Network.framework TLS HTTP composition | `tests/run_reference_tls_http_service_macos.sh` | a real TLS 1.3 `nw_connection` sends and receives an HTTP/1.1 request through Network.framework, verifies an explicit Security.framework trust anchor and hostname, checks negotiated TLS metadata, and rejects the wrong-host case without OpenSSL linkage |
| Portable services and editor | `tests/run_macos_zagscript_authority.sh`, `tests/run_macos_network_abi.sh`, `tests/run_database_drivers.sh`, `tests/run_reference_sqlite_kv.sh`, `tests/run_reference_sqlite_http_service.sh`, `tests/test_lsp.sh` | signed native Script and offline package-resolution corpora, bounded IPv4 socket adapters, target-owned SQLite KV and loopback HTTP composition bound only to libSystem plus `/usr/lib/libsqlite3.dylib`, and native language-server protocol checks; not arbitrary POSIX, general database access, or complete public networking API coverage |
| Project planner | optional `zagd_macos_daemon.zag` fixture | Darwin recursive `kqueue` plus bounded project-input polling publishes checksum-bound advisory semantic manifests and reacts to root, import, and dependency-input changes; watch-cap fallback closes partial descriptors, and planner availability never changes foreground compiler correctness or grants executable authority |

## macOS-native capabilities

The target also exposes native APIs and facilities that are specific to macOS.
Some of these fill roles that Linux covers through different native APIs:

| Capability | Native role | Evidence |
|---|---|---|
| `mach_continuous_time` | sleep-inclusive monotonic time for deadline accounting and diagnostics | `std:os_macos`, `tests/run_os_macos_services.sh` |
| `clonefile` | APFS copy-on-write file cloning with native filesystem semantics | `std:os_macos`, `tests/run_os_macos_services.sh` |
| Network.framework and Security.framework TLS | system TLS policy, trust evaluation, and connection-managed send/receive | `tests/run_macos_network_tls_handshake.sh`, `tests/run_reference_tls_http_service_macos.sh` |
| Metal | Apple GPU device, queue, shader, and shared-memory execution | `std:metal_loader`, `tests/run_macos_metal_native_profiles.sh` |
| Mach-O/dyld runtime facilities | signed Mach-O images, dyld binding, native dylibs, and live text cache synchronization | `tests/run_macos_dylib.sh`, `tests/run_macos_hot_reload.sh` |

These facilities are documented as native macOS capabilities rather than
portable Linux requirements.

The native claim-producing gate is
`tests/run_macos_arm64_release.sh`. It must run on physical Apple Silicon with a
matching macOS compiler seed. A seed is eligible for a release only after the
gate reaches its byte-identical second/third self-host generations and all
runtime and negative witnesses pass. Merely producing a Mach-O compiler, or
cross-emitting an artifact on Linux, is development evidence rather than a
release claim.

The gate keeps its generated compilers in a repository-local `build/` directory
with both module roots available from the first generation. It also runs the
parameter-contract, affine-resource, and aggregate-provenance suites against
the qualified compiler, including independent `check` and native-build
rejections for copied owners and sibling provenance after a partial overwrite.
An unrelated backend diagnostic cannot satisfy these ownership regressions.
The Network.framework TLS gates exercise TLS 1.3 options, native block
callbacks, a real handshake with an explicit trust anchor, hostname rejection,
and a composed HTTP send/receive exchange before a verified compiler may be
published.

The [September 8, 2026 native validation report](MACOS_PARITY_VALIDATION_2026-09-08.md)
records a completed 64/0 gate run, source and artifact checksums, ownership
fixes, package/install evidence, and retained support boundaries. It qualifies
its recorded working-tree snapshot, not later changes.

The gate hashes the compiler and standard-library source snapshot and checks
it after every native generation and before verified-output publication. A
source mutation invalidates the run even when an earlier generation comparison
passed. Runtime regression results for an older seed do not qualify later code.

On CI, the Linux cross-built precursor is named
`zag-znc-macos-arm64-cross-<commit>`. Only after the complete physical-Mac job
passes does the gate copy its fixed-point compiler into the distinct
`zag-znc-macos-arm64-verified-<commit>` artifact, alongside `SOURCE_COMMIT` and
`znc-macos-arm64.sha256`. The checksum is also printed in the successful job
summary so it can be reviewed separately from the downloaded ZIP.

`tools/bootstrap-macos-seed.sh` is the clean-checkout intake path for that
verified artifact. It never fetches or auto-selects a binary. It checks the
caller-supplied checksum, exact signed ARM64 Mach-O identity, source rebuild,
and byte-identical fixed point before producing the checkout-qualified
compiler, daemon, and LSP. Bootstrapping a later checkout from an older trusted
seed does not certify the later source: its full native gate must still pass
before it can publish another verified artifact or support claim.

Native release archives normalize the verified compiler to `znc` and include
its `znc.sha256` record, in addition to the archive's separately published
checksum. This is the durable clean-checkout seed route once the release tag,
archive checksum, and scoped native release evidence have been reviewed.

## Explicitly unsupported

The current target must fail closed for all of these requests:

- aggregate shapes outside the bounded struct slices below, including HFA/HVA
  aggregates, unions, by-value `@repr(C)` aggregates, variadics, aggregate callback signatures, callbacks
  returned from C, callback-alias, or capturing-callback C signatures. The
  first supported aggregate slice is limited to ordinary non-generic named structs
  containing only naturally aligned `i64`, `u64`, or raw-pointer leaves; those
  leaves may be nested through ordinary non-generic structs within the bounded
  recursive classifier. One-
  and two-word values use the Darwin INTEGER register/stack class and larger
  values use caller-owned indirect copies plus `X8` results; the object and
  dylib/custom-link gates execute both C-to-Zag and Zag-to-C argument/result
  paths, including flat/nested small and large cases plus forced small-aggregate stack spill.
  A second slice accepts flat ordinary structs containing only naturally aligned
  integer/`bool`/raw-pointer leaves when the Darwin C layout is at most 16 bytes.
  It explicitly translates between that byte layout and Zag's eight-byte field
  slots; object and dylib/custom-link witnesses cover `i32` pairs, padded
  `i32`/`i64`, `u8`/`u16`/`u32`, `bool` plus raw pointer, one/two-register
  arguments/results, and complete-value stack spill. Nested narrow/mixed-width
  values and mixed-layout values larger than 16 bytes still reject. Fixed `f32`/`f64` imports and exports use
  Darwin's `V0`-`V7` FP argument bank and naturally packed stack overflow, with
  scalar `f32` return in `S0` or `f64` return in `D0`; native C interoperability
  exercises ten FP parameters so both register and stack paths are covered.
  Callbacks are bounded to a direct, non-generic, captureless
  named function with an exact supported signature; scalar/pointer callbacks may
  target an ordinary function, while any callback containing `f32`/`f64` requires
  the direct target to be `pub @cabi_export`. Ten-`f32` callback entry is exercised
  through C so its FP stack-overflow path is covered. Unannotated floating-point
  callback targets fail closed.
  The bounded struct slices do not establish HFAs/HVAs, arbitrary nested C
  layout, large mixed-width transport, aggregate callbacks, or a general aggregate ABI.
  The native object/custom-link/libSystem witnesses above do not make the
  object/archive/dylib boundary a general foreign-function ABI.
- legacy-edition object/archive output and combining relocatable output with
  `--dynamic`, `--run`, `--hot`, `--debug`, or `--sanitize=memory`.
- aggregate global storage, a general BSS-backed global-layout ABI, or complete
  stack/global/foreign-allocation instrumentation. The bounded scalar and
  allocator checks above do not establish those broader guarantees.
- TAPI forms beyond the bounded v4 `install-name` plus target-scoped direct
  `exports[].symbols` slice used by `-framework`/`-F`: re-exported libraries,
  weak-definition/ObjC/Swift metadata, umbrella semantics, and non-v4 stubs
  remain unsupported. ARM64e authenticated pointers, static TLS-defining input sections/local TLS allocation,
  and arbitrary foreign-object formats/relocations. Imported TLVP loads against a thread-local symbol
  exported by a linked dylib are covered by the static-input gate; broader TLS
  models are not. Same- and cross-output-section SUBTRACTOR pairs are covered
  for the native text/data layout. The static-input row above is deliberately bounded to the
  ARM64 Mach-O relocation and symbol-resolution families proven by its native
  gate.
- custom dylib/executable linking combined with hot replacement, debug output,
  or exit-time memory sanitization; the existing closed executable path retains
  its separate hot/debug/sanitizer gates.
- general thread arguments/returns, closures or generic/extern workers, detach,
  mutex/condition/TLS language APIs, and a language-wide race-free memory
  model. The bounded join-only worker and raw i32 wait/wake slices above are
  supported; their compiler-owned pthread machinery is not a general public
  mutex/condition-variable API.
- Linux hot-reload, Linux driver, inotify, `/proc`, systemd, ELF, or qemu-user
  behavior presented as a macOS-native implementation.

`--dynamic` selects executable output, never shared-library output. With no
custom link inputs it retains the closed import-bearing path. With library
inputs it selects the native custom linker; shared libraries instead use
`--emit-dylib` or `--emit-shared`. Neither path establishes whole-target parity.

## Native dynamic-library inputs

Custom inputs are immutable snapshots of regular files, capped at 64 MiB each.
Versioned library symlinks are followed only by the explicit linker reader;
cache input readers remain no-follow. The same opened descriptor is checked
for regular-file identity and size. Dependency parsing accepts thin ARM64 or
universal/FAT ARM64 macOS dylibs, checks load-command bounds and install names,
and validates the entire reachable export trie before symbol lookup. Cycles,
overlapping nodes, ambiguous edges, malformed off-path terminals and unknown
custom symbols reject without an output replacement. These are bounded format
checks, not authentication or a substitute for trusting dependency code.

`-l NAME` searches `libNAME.dylib` and then `libNAME.tbd` in explicit
`-L`/manifest directories followed by `/usr/local/lib`, `/opt/homebrew/lib`,
`/usr/lib`, and available selected/Command-Line-Tools/Xcode SDK `usr/lib`
directories. Explicit `--needed` files and names use the same reader. Absolute and relative file paths are
normalized lexically; relative inputs use the physical working directory.
Explicit symlink directory spellings are retained as runtime search paths,
so different directory aliases are not promised byte-identical artifacts.
A library's actual install name is recorded;
discovered directories for `@rpath` dependencies follow user-specified
`--rpath` entries, allowing loader-relative paths to work after relocation.

Known libSystem, libobjc, Metal and SQLite shared-cache providers need not have
ordinary on-disk images. Audited names select their known provider; one
explicitly selected opaque system provider may defer unresolved-name lookup to
dyld. Multiple possible opaque providers never cause a guessed symbol ordinal.
This exception does not turn an unreadable custom library into an accepted input.

## Native archive validation

`tools/package-release.sh` is the shared, non-publishing archive recipe used by
`release.sh`. It builds the language server from staged source, checks the
packaged compiler/daemon/client, validates the staged and extracted trees, and
executes the production install recipe in temporary prefixes with installed
standard-library compile/run witnesses. It never commits, tags, replaces an
existing archive, or installs globally. A development run does not authorize a
release or substitute for the full source-qualified native gate.

## Raw syscall namespace

`_zag_raw_syscall` is a legacy source boundary whose numbers are Linux x86-64
syscall identities on every backend. For Mach-O, the compiler recognizes only
an audited literal adapter subset (read, close, mkdir (Linux 83 to Darwin 136),
getpid, fcntl, dup2, timeout, fork, execve, wait4, kill, setpgid, and pipe). It
translates those calls and their required argument/return differences to Darwin
behavior.

The `fcntl` entry admits only literal `F_GETFD` with a zero third argument and
literal `F_SETFL` with zero or Linux `O_NONBLOCK`, which is translated to the
Darwin flag bit. These tuples support bounded descriptor-state witnesses and
the native process adapter. Other command/argument tuples return `ENOSYS`;
Linux and Darwin command numbers must never alias by accident.
Syscall identities must be non-negative literals within the signed 32-bit
range, so narrowing cannot wrap a large value into an audited operation.

An unknown Linux number or a computed raw syscall number returns Darwin
`ENOSYS` (78) without issuing an unrelated trap. Native macOS implementation
code may use the separate `_zag_darwin_syscall` boundary, which itself requires
a non-negative integer literal. Neither escape hatch is a portable public
syscall API, and Linux syscall coverage must never be inferred for macOS.

Unsupported hardware or operating-system capabilities must reject with a
specific diagnostic and leave no substitute artifact. They must never silently
route through Linux numbers, qemu, an ELF image, or a partial emulation path.
