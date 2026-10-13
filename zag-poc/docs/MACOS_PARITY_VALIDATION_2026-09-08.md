# macOS ARM64 validation — September 8, 2026

## Result and scope

The complete native Apple Silicon release gate finished with **64 passed, 0 failed**. Both outstanding aggregate-provenance defects are fixed. The compiler reaches a byte-identical self-hosting fixpoint, and the documented macOS native surface has been exercised on physical Apple Silicon. The qualified compiler, matching daemon, and freshly built language server are installed in the checkout's standard native output locations.

This qualifies the scoped native contract in [SUPPORT.md](SUPPORT.md) and [MACOS_NATIVE_PARITY.md](MACOS_NATIVE_PARITY.md). It does not establish that every Linux-specific facility or every experimental feature is supported on macOS. No target has complete edition-2027 release support under [V2_TARGET_SUPPORT.md](V2_TARGET_SUPPORT.md).

## Qualified source and artifacts

The run used Darwin arm64 on macOS 26.6.2. It qualified the **working-tree compiler and standard-library snapshot**, including the in-progress parity changes, based on commit `0ea1b257cfb092a935695ff87ebabbd9ba13d358`. It did not qualify that commit without its working-tree changes. Source fingerprints were checked throughout qualification and before copying the final tools.

| Identity | SHA-256 |
|---|---|
| Compiler/stdlib source snapshot | `faa87bee0e396db3c3c68a45ec09150ce3dd5fd5a7b167bb71eef110d366406b` |
| `znc-macos-arm64` | `6a708ce19bbfa759fead0e10eb81782f2451b06319a10db000e305490bbfdfba` |
| `zagd-macos-arm64` | `4d8653643cf197b1da7d727de8da82442fba09498fca95073be09082227f0b70` |
| `zag-lsp-macos-arm64` | `afc3a7c6ed5738a21b0006f92eb22784bd838ccd3ccbbec2661096c597fe048b` |

All three tools are at the root of `zag-poc`. The compiler published by the complete gate is byte-identical to the default compiler. Generated compiler stages used repository-local directories with `std` and `selfhost` available beside them from the start. Prior local binaries and qualification copies are retained under `build/macos-parity-validation/toolchain/`.

The source fingerprint hashes the sorted paths and SHA-256 digests of `zag.mod` and all Zag files under `selfhost/` and `std/`, using the same NUL-delimited representation as the native gate. Tests and documentation are reviewed separately and are not part of that compiler-source fingerprint.

## Ownership correctness

Both reported failures were real frontend provenance defects. The early return in `zt_agg_assign_value` used the absence of a direct allocation root or stack address to skip field-sensitive propagation. A named aggregate copy can carry provenance without being a direct owner. A compound value with two different owners also has no single direct-root summary. Consequently, copying an aggregate lost its independent provenance, and clearing one field could leave the sibling's owner untracked.

Assignments now always remap saved field provenance through `zt_agg_write_expr`. Existing scalar-snapshot filtering remains in that logic. Clearing a field removes its own provenance; copied values and other fields retain theirs. Explicit borrowed pointer parameters, scalar snapshots, stack escapes, and pointer-laundering rejection remain covered by acceptance tests.

The regressions require the intended ownership diagnostic from both `znc check` and artifact-producing compilation, with no output left behind on rejection. The earlier downstream `unknown function: retain` error cannot count as a successful ownership rejection. The same negative suite passes with Linux x86-64 and ARM64 target selection. These are frontend and no-artifact cross-target checks, **not Linux runtime qualification on this Mac**.

## Tests and results

Component counts overlap the 64 top-level checks and must not be summed into a separate total.

| Validation | Result |
|---|---|
| Fresh native bootstrap | Pass; generated stages 2 and 3 byte-identical; matching daemon built |
| Complete native macOS release gate | **64 passed, 0 failed**; compiler published only after all components passed |
| Parameter contracts | **45 passed, 0 failed** |
| Aggregate provenance | **20 passed, 0 failed**, including both entry points for both defects |
| Try-wrapped borrowing | **2 passed, 0 failed**; correct retained-view diagnostics |
| Affine resources | Pass |
| Network.framework TLS handshake | Pass; TLS 1.3, explicit trust anchor, hostname rejection |
| Network.framework TLS probe | Pass; options, native block callback, system frameworks |
| Shared native ARM64 corpus | **101 passed, 0 failed**, signed Mach-O execution |
| ABI/layout | **21 passed, 0 failed** |
| Link-option contracts | **59 passed, 0 failed** |
| Checked access and allocator sanitizer | **21 passed, 0 failed**; expected guard-page SIGBUS witnesses included |
| Native hot replacement | **25 passed, 0 failed**, including replacement in the same running process |
| Native Metal fill/depth/blend profiles | **3 passed, 0 failed**; physical dispatch/readback |
| Public Metal loader | **3 passed, 0 failed** |
| Protocol codecs | **12 passed, 0 failed** |
| Database / SQLite KV / SQLite HTTP | **8 / 6 / 10 passed**, respectively; no failures |
| Configuration and logging | **6 passed, 0 failed** |
| macOS ZagScript authority | **23 passed, 0 failed**; 85 unique signed executable artifacts |
| Daemon resource stress | Pass; 256 edits, no allocation-count/live-byte growth, 0 KiB observed RSS growth |
| Native LSP protocol | **17 passed, 0 failed**, repeated against the final default LSP |
| Native build authority | **7 passed, 0 failed**, including self-rebuild with host C build tools poisoned on PATH |
| Production package roundtrip | Pass; real archive/extraction/installation, installed std, checksums, no Git invocation, no clobber |
| Production install layout and seed intake | Pass; native compiler/daemon/LSP, installed std, valid checksum acceptance and mismatch rejection |

Additional passing checks cover typed authority, resource contract syntax, networking foundations, HTTP/WebSocket foundations, collections/Unicode, documentation truth and consistency, and the generated support matrix. The final default compiler built and ran the Script greeting, producing `Hello from Zag Script`.

## Linux capability comparison

| Capability family | Executed macOS equivalent |
|---|---|
| Generation, linking and loading | Signed Mach-O executables, edition-2027 objects/BSD archives, native dylibs/custom executables, bounded Mach-O static inputs, deterministic signing and negative format/option checks |
| ARM64 ABI and runtime | Native C/Zag/C interoperability within documented scalar/FP/aggregate/callback slices; builtins, heap reuse, arena-overlap cleanup, stack offsets, arguments and data |
| Frameworks and GPU | libSystem, Objective-C/Metal and Network.framework paths; physical Metal fill/depth/blend and TLS witnesses |
| Filesystem/process services | Darwin layouts, close-on-exec descriptors, bounded process execution, executable identity, cache corruption/race handling and safe output publication |
| Networking/applications | Bounded IPv4 TCP/UDP, TLS witnesses, HTTP/WebSocket/DNS codecs, SQLite KV and loopback reference applications |
| Threading/synchronization | Real pthread-backed join-only workers, atomic operations, checked worker execution, raw i32 wait/wake and exact wake counts |
| Development/distribution | Native hot replacement, DWARF, advisory kqueue daemon, Script/package resolution, LSP, actual archive/extract/install recipe and seed checksums |

Linux-specific facilities remain outside the Darwin contract: Linux kernel driver/Kbuild interfaces, ELF loaders, arbitrary Linux raw syscalls, `/proc`, inotify, systemd, Linux DRM/driver stacks, and Linux qemu-user behavior. Darwin equivalents are qualified only within the documented native boundaries above.

Separate experimental limits remain: a general foreign ABI; unsupported aggregate, variadic and capturing-callback forms; aggregate globals; complete memory instrumentation and race freedom; broader thread/TLS APIs; general GPU-profile coverage; and custom-linked hot/debug/exit-sanitizer combinations. Some are unsupported or incomplete on Linux as well and must not all be described as Linux-only capabilities.

The optional foreground-cache fixture requiring a glibc `libm` static archive was explicitly skipped on macOS. Native Mach-O static-input linking was tested separately. `strace` was unavailable for native build-authority validation; PATH poisoning of host C build tools remained enforced.

## Completion changes and review

The large backend/framework/runtime implementation already existed in the working tree. This completion repaired and qualified that work. Its focused changes are:

- `selfhost/typed.zag`: preserve aggregate provenance through assignments.
- `tests/run_v2_aggregate_provenance.sh` and `tests/run_v2_try_borrow.sh`: semantic rejection at both check and build entry points.
- `tests/run_macos_arm64_release.sh`: repository-local module-aware compiler stages, isolated watcher fixture, mandatory ownership and TLS regressions.
- `tests/run_native_authority.sh`: repository-local module-aware self-rebuild.
- `tests/check_pure_zag_tree.sh`: exact C ABI test-oracle exceptions and exclusion of generated build artifacts from production-source scanning.
- `.gitignore`: contain generated builds and nested fixture runtime state.
- `docs/MACOS_NATIVE_PARITY.md` and this report: gate documentation and exact qualification evidence without expanding support boundaries.

Review found no added implementation debug markers. All 66 changed/new shell scripts passed syntax checks, and `git diff --check` passed. Generated scratch compilers are retained outside the source diff. No release tag, commit, external publication, or system-wide installation was performed.

## Evidence and conclusion

Local raw evidence is retained under [`build/macos-parity-validation/`](../build/macos-parity-validation/): the full native gate and bootstrap logs; focused and cross-target results; package roundtrip and native-authority logs; `qualified-final-artifacts.json`; `closeout-results.json`; and `files-changed.txt` (the full working-tree inventory, including inherited changes). The directory is ignored build evidence, not automatically part of a source commit.

**The documented macOS ARM64 native surface is qualified for this source snapshot.** The outstanding ownership defects and native validation failures have been resolved. An unqualified claim that all Linux behavior or complete edition-2027 support has been ported would exceed the evidence and support contract.
