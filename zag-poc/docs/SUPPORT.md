# Zag support contract

This is the user-facing authority for what Zag supports. A feature is not
general support merely because a parser accepts it, a backend contains code for
it, or a focused development test passes. General support requires a documented
scope, executable evidence, and release packaging for that scope.

## Release channels

- **Zag v1, edition 2026:** the stable language core. It is intentionally small.
- **Zag v2, edition 2027:** a fail-closed development edition. Its implemented
  slices are useful for testing, but v2 is not a production release.
- **Zag Script:** a low-friction profile of the same compiler. Its bounded
  defaults do not turn Zag into a garbage-collected or memory-safe language.

## Host and output targets

| Target | Status | Exact boundary |
|---|---|---|
| Linux x86-64 | primary supported target | committed compiler seed, self-hosted fixed point, static ELF, documented dynamic and object slices |
| Linux AArch64 | supported scoped target | cross compilation plus qemu-user and native-ARM CI; static v1 programs and the documented edition-2027 object/dynamic slices are gated, but not every x86-64 v2 feature has ARM parity |
| Apple Silicon macOS (`macos-arm64`) | scoped native development target | signed PIE ARM64 Mach-O executables, edition-2027 scalar/bounded-`f32`/`f64` plus bounded flat/nested 64-bit-leaf and flat small integer/bool/pointer struct import/export and direct-callback C-ABI objects, static archives, dylibs and custom dynamically linked executables, bounded ARM64 Mach-O object/archive input linking, Darwin runtime and project services, DWARF with closed dyld imports, native live text replacement, machine caching, bounded global/safety slices, integer/boolean/raw-pointer `@repr(C)` pointer-layout execution, and native parity for the compiler-owned `popcount`/`andn`/leading-zero/trailing-zero/byte-swap scalar CPU controls, plus native equivalents for the supported portable clock/entropy, filesystem, networking/TLS HTTP, concurrency-worker, and dynamic-plugin service slices; macOS-native `mach_continuous_time`, APFS `clonefile`, Network.framework/Security.framework TLS, Metal, Mach-O/dyld, and kqueue facilities are documented separately; a seed needs the complete native gate, while Linux-specific kernel, ELF, `/proc`, systemd, and driver interfaces retain target-specific behavior |
| Linux i686 | limited milestone | bounded integer/object/archive paths only; not complete v1 or public-ABI parity |
| WebAssembly | artifact-only | `.wasm` emission exists; Zag has no supported pure-Zag WASM execution runtime |
| GPU targets | bounded native/compatibility development targets | Vulkan, OpenGL, and OpenCL are runtime-gated on their verified Linux stacks; Apple Silicon has a first-class `gpu-metal` target for the reviewed fill, depth-write, and depth-tested packed-RGB blend profiles plus physical execution through the native `std:metal_loader` device/queue/capability/memory/dispatch/readback path; `metal-compat` remains a source-compatible legacy spelling; frontend artifacts and local probes alone are not general GPU support |
| Windows, BSD, RISC-V | unsupported | no supported compiler host and native release contract |

“ARM64 supported” therefore means the scoped rows above, not universal backend
parity. “Experimental v2 feature” describes the feature edition, not the entire
ARM64 backend.

The macOS row does not imply whole-target Linux parity. Mach-O object
(`--emit-obj`) and BSD archive (`--emit-static`) output require strict edition
2027 and defined non-generic `pub` functions annotated `@cabi_export`. Imported
C functions require `@cabi`; this boundary admits scalar integer, boolean,
raw-pointer, and void-return signatures plus fixed `f32`/`f64` imports and exports
using `V0`-`V7` and Darwin's naturally packed FP stack overflow. Apple Silicon
also admits ordinary non-generic named structs whose leaves are only naturally
aligned `i64`, `u64`, or raw pointers; those leaves may be nested through
ordinary non-generic structs within the bounded recursive classifier. One- and two-word values use Darwin's
INTEGER aggregate class (`X` registers when the complete value fits, otherwise
the whole value on the stack; `X0`/`X1` for results). Larger values use the
indirect-composite convention (caller-owned argument copy and `X8` indirect
result). Both paths are exercised in both C/Zag directions, including forced
register exhaustion and flat/nested small and large witnesses. A second bounded
small-aggregate slice admits flat ordinary structs made only from naturally
aligned integer/`bool`/raw-pointer leaves when their Darwin C layout is at most
16 bytes. Because ordinary Zag fields occupy eight-byte internal slots, this
path explicitly packs/unpacks the C byte layout; native witnesses cover signed
and unsigned subword fields, padding, `bool`, raw pointers, one/two-register
transport, returns, and whole-value stack spill. Nested narrow/mixed-width
structs, mixed-layout structs larger than 16 bytes, HFA/HVA aggregates, unions,
and `@repr(C)` by-value aggregates remain unsupported. A callback parameter may be a direct, non-generic,
captureless named Zag function and is passed as one raw code pointer. The ordinary
callback form has an exact scalar/pointer signature; Apple Silicon additionally admits
fixed `f32`/`f64` callback signatures when
the direct callback target is `pub @cabi_export`, which supplies the proven C FP
entry/return adapter. Aggregate shapes outside the two bounded struct slices above,
including HFA/HVA aggregates and unions, plus by-value `@repr(C)` aggregates,
variadics, aggregate callback signatures, callback
aliases/captures, and callbacks returned from C remain unsupported. The native gate links and runs the
actual CLI outputs with Apple's C toolchain, including mixed-width stack
arguments, ten-FP-parameter register/stack overflow, independent FP/X-register `f32`/`f64` imports/exports with explicit f32 single/double conversion, flat/nested small register/stack and large indirect 64-bit-leaf struct imports/exports, flat small integer/bool/pointer struct byte-layout adaptation, direct scalar callbacks and mixed/wide FP/GPR f32/f64 callbacks, globals, literals, allocation, checked access, and archive-index
extraction. Those external tools are test oracles, not compiler dependencies.
Objects permit `--safety=checked`, but executable/hot/debug/exit-sanitizer options
must not be silently applied to relocatable output. Native shared-library output
uses `--emit-dylib` (alias `--emit-shared`), the same strict edition-2027
scalar/bounded-`f32`/`f64` plus bounded flat/nested 64-bit-leaf and flat small integer/bool/pointer struct import/export and direct-callback C ABI, and a deterministic embedded signature. Custom external `-l`/`-L` linking,
`--needed`, and bounded TAPI-v4 SDK library plus `-framework`/`-F` lookup accept ARM64 macOS dylibs/frameworks for a library or an explicitly
`--dynamic` executable, including source `@link` and nearest/imported-manifest
library declarations. `--install-name` applies only to dylibs; `--rpath` applies
to these custom-linked images. Bounded dependency snapshots, thin/universal
ARM64 selection, full reachable export-trie validation, symlinked library input,
and loader-relative relocation are exercised by `tests/run_macos_dylib.sh` and
`tests/run_macos_dylib_format.sh`. Unknown custom symbols, malformed dependencies,
missing option values, and conflicting modes reject before replacing output.
Framework metadata is intentionally narrow: only v4 install names and direct
target-scoped symbol lists are link authority; TAPI reexports, weak-definition,
ObjC/Swift, umbrella, and non-v4 forms remain outside the supported boundary.
The same bounded TAPI reader backs SDK `libNAME.tbd` fallback for ordinary
`-l NAME` and `--needed` library resolution when the runtime image is in dyld's
shared cache.
Shared-cache system providers use audited names or a single explicitly selected
system library; the latter may defer symbol resolution to dyld. Explicit ARM64
Mach-O `.o` and BSD `.a` inputs are accepted on the same `--emit-dylib` or
explicit `--dynamic` path, either positionally or through `--static-input`.
Each selected file is a bounded 64 MiB regular-file snapshot; archive members
are extracted to an unresolved-symbol fixed point without trusting the archive
index. The gated relocation slice covers branches, page/pageoff address and
load/store fixups, absolute data pointers, imported and local GOT loads, both
`POINTER_TO_GOT` forms, imported TLVP loads bound to dylib-exported thread-local
symbols, resolved and unresolved weak imports (including dyld null fallback),
and same/cross-output-section subtractor constants. COMMON, strong/weak
precedence, private-external visibility, transitive archive demand, and
composition with dylib/libSystem imports are exercised by
`tests/run_macos_static_link.sh`. This remains a bounded ARM64 Mach-O slice,
not a general foreign ABI, arbitrary object linker, or Intel Mac support.
Custom linked images currently reject hot/debug/exit-sanitizer combinations;
checked access is separately exercised. Source-only dependency paths remain valid.

Edition-2027 zero-initialized scalar globals use PIE-relative
writable data cells, not Linux's fixed BSS-backed virtual addresses; aggregate
global storage remains outside this contract. `--safety=checked` and
`--sanitize=memory` have native null/alignment/bounds/lifetime and allocator
leak witnesses, including global-address and foreign-contract cases, but are
not whole-language memory safety. `--debug` combined with dyld imports is
exercised by native launch, signature, DWARF, and cold/warm cache-equivalence
checks. Without custom link inputs, `--dynamic` retains the existing closed
import-bearing executable path. It never means shared-library output; use
`--emit-dylib` for that.

Zag source-level `_zag_raw_syscall` uses the Linux x86-64 syscall-number
namespace. The macOS backend translates only an audited literal subset needed
by its process/runtime adapters. Unknown or computed raw syscall numbers return
`ENOSYS`; they are never passed through as Darwin numbers. Native platform code
uses a separate literal-only Darwin adapter. See
`docs/MACOS_NATIVE_PARITY.md` for the exact boundary and evidence rule.

## Systems-language foundations

| Capability | v1 / edition 2026 | v2 / edition 2027 |
|---|---|---|
| ownership and borrowing | unavailable | partial, compiler-enforced `Allocation` ownership and bounded borrow/consume contracts; not a general lifetime model |
| destructors and RAII | unavailable | unavailable |
| garbage collection | unavailable | unavailable |
| memory safety | programmer-managed pointers; no complete guarantee | bounded checked-access, allocator provenance, and sanitizer slices on Linux x86-64/AArch64 and Apple Silicon macOS; platform-specific witnesses do not establish whole-language memory safety or complete instrumentation parity |
| threads and atomics | unavailable as a language model | bounded join-only worker support on Linux x86-64 and Apple Silicon macOS with one copied `i64` argument; native atomic slices and the same unsafe raw `@atomicWait32`/`@atomicWake32` surface execute on both targets, using Linux futexes versus a compiler-owned Darwin pthread mutex/condition runtime; no general scheduler, detach, mutex/condition language API, race freedom, or portable memory model |
| volatile/MMIO and bounded SIMD | unavailable | edition-2027 exact-width 8/16/32/64-bit volatile transactions, baseline prefetch, and raw-pointer i32x4 add/sub/and/or/xor execute on Linux x86-64 and Apple Silicon macOS with target-native opcode evidence. A target-independent vector IR, opt-in loop vectorizer, vector register allocator, and CPU-width lowering exist and reach emitted x86 machine code for functions small enough for the ZIR-direct route; this is verified at the IR and byte level AND by execution: a vectorized and a scalar build of the same self-checking equivalence program are both run on x86-64 (under emulation where needed) and must each agree with their own scalar reference. AArch64 does not yet consume the vector IR. Lanes are ELEMENTS and an element is a whole 8-byte word, so the generic 128-bit baseline carries 2 i32 lanes, not 4; float and byte/halfword element types are refused with a reject code rather than mis-encoded. See [`docs/VECTOR_PIPELINE.md`](VECTOR_PIPELINE.md). This is still not a physical-device MMIO authority, a vector value ABI, or a portable general-SIMD contract |
| async/await | unavailable | unavailable |
| stable ABI | unavailable | named, edition-gated C ABI slices only; no general cross-edition ABI stability |
| dynamic linking | unavailable as a portable v1 contract | partial documented Linux x86-64/AArch64 ELF paths and bounded C-ABI macOS dylib/custom-executable paths; each has its own native gate and explicit limitations |

The detailed executable evidence for edition 2027 remains in
`docs/V2_FINAL_VERIFICATION.md`. A passing row there must not be generalized
beyond its stated target and negative cases.

## Modules and dependencies

Zag supports source modules through `@import`, compiler-owned `std:` modules,
explicit local paths, and bounded `pkg:` aliases declared in the importing
module's nearest `zag.mod`. An ordinary alias resolves an explicit `.zag`
module from a reviewed relative sibling or vendored root and remains unlocked.

A dependency stored under the consuming project may instead select
`mode = "vendor"`. This mode requires a canonical `zag.lock` beside `zag.mod`.
Each lock entry binds one declared alias, vendor root, explicit module path, and
deterministic checksum of that module's raw bytes. Resolution is offline,
rechecks the selected bytes before compilation, validates package inputs before
machine-cache reuse, and includes exact manifest and lock snapshots in semantic
and cache provenance. These checks provide reproducibility, not authenticity:
the raw checksum is not a package signature.

Zag does **not** currently provide a public package registry, network resolver
or fetch path, semantic-version or revision solver, lock/update generator,
package-signature authority, automatic download command, complete transitive
locking, non-Zag asset snapshots, or filesystem/symlink containment. `zag.mod`
is not evidence of a public package ecosystem.

For reproducible projects today:

1. vendor reviewed dependency source into the repository;
2. use an explicit relative import, a declared local `pkg:` alias, or the
   compiler-enforced locked vendor mode;
3. keep revision identity in version control and, for locked vendor imports,
   maintain canonical raw-byte lock entries; and
4. review and test every upgrade like any other source change.

See `docs/DEPENDENCIES.md` for the workflow summary and
`docs/LOCAL_PACKAGE_IMPORTS.md` for the exact executable resolver and lockfile
contract.

## Tooling shipped to users

- `znc`: compiler, formatter, checker, project scaffold, and global help.
- `zagd`: optional project-scoped advisory daemon.
- `zag-lsp`: language server built and installed by `make install` and included
  in release archives.
- VS Code client source: `editors/vscode/`. Native release archives include a
  ready-to-install `zag-lang.vsix`. Rebuilding that VSIX uses the committed npm
  lockfile and a fixed archive timestamp; Node.js is an editor/release-packaging
  dependency, not a compiler dependency.
- A clean Apple-Silicon checkout can ingest an explicitly selected,
  native-gate-verified CI seed with `tools/bootstrap-macos-seed.sh`. The helper
  requires the published SHA-256 record, validates signed Mach-O identity,
  reaches a source-built fixed point, reruns the independent reproducibility
  proof, and builds the matching daemon and LSP. It does not download a seed or
  choose trust on the user's behalf, and a cross-only artifact is ineligible.
  Verified native release archives provide the durable equivalent through
  their normalized `znc` plus `znc.sha256`, after the outer archive checksum
  and signed release tag have been reviewed.

## What “production-ready” does not mean here

A green v1 gate establishes the documented v1 compiler boundary. It does not
certify the v2 roadmap, a package ecosystem, all operating systems, arbitrary
GPU workloads, or complete memory safety. Those remain separate deliverables.
