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
| Linux i686 | limited milestone | bounded integer/object/archive paths only; not complete v1 or public-ABI parity |
| WebAssembly | artifact-only | `.wasm` emission exists; Zag has no supported pure-Zag WASM execution runtime |
| GPU targets | bounded compatibility/development targets | only the exact Vulkan, OpenGL, and OpenCL compatibility gates are runtime evidence; frontend artifacts and local probes are not general GPU support |
| macOS, Windows, BSD, RISC-V | unsupported | no supported compiler host and native release contract |

“ARM64 supported” therefore means the scoped rows above, not universal backend
parity. “Experimental v2 feature” describes the feature edition, not the entire
ARM64 backend.

## Systems-language foundations

| Capability | v1 / edition 2026 | v2 / edition 2027 |
|---|---|---|
| ownership and borrowing | unavailable | partial, compiler-enforced `Allocation` ownership and bounded borrow/consume contracts; not a general lifetime model |
| destructors and RAII | unavailable | unavailable |
| garbage collection | unavailable | unavailable |
| memory safety | programmer-managed pointers; no complete guarantee | bounded checked-access, allocator provenance, and sanitizer slices on native x86-64/ARM64; not whole-language memory safety |
| threads and atomics | unavailable as a language model | partial Linux x86-64 join-only worker and atomic/futex slices; no general scheduler, race freedom, or portable memory model |
| async/await | unavailable | unavailable |
| stable ABI | unavailable | named, edition-gated C ABI slices only; no general cross-edition ABI stability |
| dynamic linking | unavailable as a portable v1 contract | partial documented x86-64 and ARM64 ELF paths with explicit SONAMEs |

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
- VS Code client source: `editors/vscode/`. Until a marketplace or attached
  VSIX release exists, installation still requires Node.js tooling; that is an
  editor-packaging dependency, not a compiler dependency.

## What “production-ready” does not mean here

A green v1 gate establishes the documented v1 compiler boundary. It does not
certify the v2 roadmap, a package ecosystem, all operating systems, arbitrary
GPU workloads, or complete memory safety. Those remain separate deliverables.
