# Zag Release Process

This is the authoritative release checklist. Every step must pass before a
release tag is pushed. Steps marked **BLOCKING** abort the release if they fail.
`release.sh VERSION` is the executable authority for ordering these gates,
creating the tag, assembling the native-platform archive, and validating the
archive before it can be published.

---

## Prerequisites

- You are on the `native-self-hosting-no-zig` branch (or a release branch cut
  from it).
- Run the release on one supported native host: Linux x86-64, Linux AArch64,
  or Apple Silicon macOS. Rosetta and cross-host packaging are not release
  evidence.
- Provide a trusted seed matching that exact host. Linux x86-64 uses the
  committed `./znc`; Linux AArch64 uses `./znc-linux-arm64` (or
  `seeds/linux-arm64/znc`); Apple Silicon uses `./znc-macos-arm64` (or
  `seeds/macos-arm64/znc`). A clean Mac checkout may first use
  `tools/bootstrap-macos-seed.sh` with the checksum-paired artifact from a
  successful physical-Mac native gate. The Linux cross-only artifact is not
  eligible. No Python, C, or Zig compiler is accepted as a fallback.
- Node.js 22+ and npm are release-packaging dependencies for the locked,
  byte-reproducible VS Code extension. They are checked before compiler work or
  release mutation and are not dependencies of the Zag compiler.
- `release.sh` validates the seed identity and selects the matching native
  target. The GPU MLIR (`--target gpu-*`) and WASM (`--target wasm`) backends
  remain integrated compiler targets; `selfhost/native/znc_target.zag` is
  optional differential-test infrastructure.
- The working tree is clean (`git status` shows no uncommitted changes).

---

## Checklist

### 1. Freeze the tree

No new features after the release branch is cut. Bug fixes to release-blocking
issues are the only permitted changes.

Verify that retired implementation sources and paths are absent:

```sh
bash tests/check_pure_zag_tree.sh
```

```sh
git checkout -b release/2026.06.0 native-self-hosting-no-zig
# No feature merges beyond this point.
```

### 2. Update version constants

Edit `selfhost/version.zag`:

```zag
fn zag_version() []u8 { return "2026.06.0"; }   // remove the -dev suffix
fn zag_edition() []u8 { return "2026"; }
```

Commit:

```sh
git add selfhost/version.zag
git commit -m "release: bump version to 2026.06.0"
```

### 3. Run the authoritative native gate — BLOCKING

This is the first blocking gate. It poisons host C tools and verifies that the
host-qualified compiler can rebuild itself and pass the native smoke suite with
zero compiler-toolchain dependencies. The runner selects `./znc` on Linux
x86-64, `./znc-linux-arm64` on Linux AArch64, and `./znc-macos-arm64` on Apple
Silicon.

```sh
./tests/run_native_authority.sh
```

Expected: 100% pass. Any failure is a release blocker.

### 4. Run the platform-native language/backend suite — BLOCKING

Run exactly the row for the release host (the executable `release.sh` makes the
same selection):

| Release host | Blocking native row |
|---|---|
| Linux x86-64 | `ZNC=./znc bash tests/run_native.sh` |
| Linux AArch64 | `ZNC=./znc-linux-arm64 bash tests/run_native_arm64.sh` |
| Apple Silicon macOS | `ZNC=./znc-macos-arm64 bash tests/run_macos_arm64_release.sh` |

The macOS row must execute on physical Apple Silicon. Linux ELF or qemu output
does not substitute for its Mach-O loader, Darwin syscall, signing, dyld, and
Metal evidence. Expected: all tests in the selected row pass.

### 5. Run semantic and diagnostic conformance — BLOCKING

Use the same compiler selected for the native row:

```sh
# Apple Silicon; use ./znc on Linux x86-64 or ./znc-linux-arm64 on Linux ARM.
export ZNC=./znc-macos-arm64
bash tests/run_semantics.sh
bash tests/run_diag.sh
bash tests/run_tooling.sh
bash tests/run_programs.sh
```

### 5b. Run multi-target native gates — BLOCKING

ABI/layout hardening runs with the selected native compiler on every release
host:

```sh
bash tests/run_abi_layout.sh
```

The following additional rows retain the Linux x86-64 release boundary. They
exercise GPU MLIR, WASM, and `@total` proofs on the committed `./znc` path:

```sh
ZNC=./znc bash tests/run_native_gpu.sh
ZNC=./znc bash tests/run_native_wasm.sh
ZNC=./znc bash tests/run_native_total.sh
```

ABI/layout hardening (`tests/run_abi_layout.sh`) documents **current** struct,
slice, union, `fat_fn`, and `!T` sizing per `COMPATIBILITY.md`. Failure is a
release blocker — language v1 does **not** freeze binary layout; the suite
captures documented-current behavior only.

### 5c. Run cross-target native gates — BLOCKING

These are Linux x86-64 cross-target rows, not Apple Silicon substitutes. On
Linux x86-64, qemu-user executes Linux ARM64 binaries for validation. It is
test infrastructure only; compilation and self-hosting remain pure Zag.

```sh
ZNC=./znc bash tests/run_native_arm64.sh
ZNC=./znc bash tests/run_differential.sh
ZNC=./znc bash tests/run_arm64_selfhost.sh
```

On native Linux AArch64, `run_native_arm64.sh` is the platform row from step 4;
run `ZNC=./znc-linux-arm64 bash tests/run_arm64_selfhost.sh` for its native
self-hosting row. On Apple Silicon, use only the macOS gate from step 4 for
release evidence; its explicit `macos-arm64` builds are signed Mach-O, not
Linux AArch64 ELF.

### 6. Verify byte-identical self-hosting fixpoint — BLOCKING

```sh
./bootstrap.sh
bash tests/check_native_bootstrap_repro.sh
```

Both scripts select the exact native host. The fixed-point output is `./znc`
on Linux x86-64, `./znc-linux-arm64` on Linux AArch64, and
`./znc-macos-arm64` on Apple Silicon. A byte mismatch is a release blocker.
Optionally run `tests/check_native_target_repro.sh` on Linux x86-64 if you
rebuilt `znc-target` for differential checks.

### 7. Update CHANGELOG.md

Fill in the release date for the `[Unreleased]` entry and rename it:

```markdown
## [2026.06.0] — 2026-06-??
```

Commit:

```sh
git add CHANGELOG.md
git commit -m "changelog: add release date for 2026.06.0"
```

### 8. Build and record the native seed binary

Rebuild the native seed from source. Linux x86-64 updates the committed `./znc`
seed. Linux AArch64 and Apple Silicon retain their platform-qualified,
release-gated compiler; `release.sh` packages that compiler as the archive's
unsuffixed `znc` without overwriting or committing the Linux x86-64 seed.

```sh
./bootstrap.sh

# Linux x86-64 only:
git add znc
git commit -m "release: update seed binary for 2026.06.0"
```

On Linux AArch64, verify `./znc-linux-arm64`; on Apple Silicon, verify
`./znc-macos-arm64`. Do not add either qualified artifact as `./znc` in the
source checkout.

### 9. Tag the release

Use a signed tag. The tag message should be the first 15 lines of the
`CHANGELOG.md` entry.

```sh
git tag -s v2026.06.0 -m "$(head -15 CHANGELOG.md)"
```

### 10. Build release tarball

`release.sh` delegates to `tools/package-release.sh` to assemble
`zag-$VERSION-$PLATFORM.tar.gz`; do not maintain a second copy recipe. The
standalone archive contains:

- native `znc`, `zagd`, and `zag-lsp` executables;
- `znc.sha256`, binding the normalized compiler used by clean-checkout seed
  intake after the release archive itself has been verified;
- `bootstrap.sh`, `Makefile`, and `zag.mod` as one coherent bootstrap/install
  surface;
- the `selfhost`, `std`, `examples`, `programs`, `tests`, `tools`, `docs`, and `editors`
  trees plus the packaged VS Code extension;
- `LICENSE` and the top-level install, bootstrap, compatibility, versioning,
  changelog, and release documentation.

Before writing the checksum, the release flow validates the staged tree,
extracts the tarball into a fresh directory, compares it with staging, and
validates the extracted tree again. Validation includes required content and
permissions, native executable identity, `zag.mod`/compiler version agreement,
a non-writing `make install` expansion, the actual production install recipe
in a temporary prefix, installed standard-library and native compile/run
smoke tests, and a
fail-closed check for AppleDouble files. Archive creation disables both
copyfile AppleDouble metadata and tar xattr records on macOS while remaining
compatible with GNU tar on Linux; the layout self-test injects a real macOS
xattr and proves that ordinary extraction cannot recover it.
The lightweight contract self-test is safe to run without committing, tagging,
or creating a release:

```sh
bash tests/run_release_package_layout.sh
```

The real packaging recipe can also be exercised with explicitly selected
native binaries and an already-built VSIX, without release-side Git actions:

```sh
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-check.XXXXXX")
. ./tests/portable.sh
package_version=$(zag_compiler_version ./znc-macos-arm64)
bash tools/package-release.sh "$package_version" macos-arm64 \
  ./znc-macos-arm64 ./zagd-macos-arm64 ../editors/vscode/zag-lang.vsix \
  "$package_dir"
```

The helper refuses an existing archive/checksum, validates a real extraction
and installation, and never modifies Git or installs globally. This produces
development packaging evidence, not a release authorization: the preceding
native qualification gates, clean tree, and signed tag are still mandatory.

`make test-release-package-roundtrip` runs that same recipe in temporary
directories, checks real extraction/installation and archive checksums,
poisons Git, and verifies that existing archives cannot be overwritten. Set
`ZNC`, `ZAGD`, and `ZAG_VSIX` to select the exact artifacts under test.

The editor source includes `package-lock.json`, a pinned VSIX packager, a
bundled runtime client, and a fixed ZIP timestamp. `release.sh` runs `npm ci`,
packages twice, and requires byte-identical VSIX hashes before it can stamp the
changelog, commit, or tag.

The `macos-arm64` archive is evidence for the scoped native development target
described in `docs/SUPPORT.md`; it is not a notarized end-user distribution.
Its deterministic Mach-O outputs carry embedded ad-hoc signatures, not a
Developer ID identity or an Apple notarization ticket. Do not present that
archive as Gatekeeper-ready software. A future general macOS release must add
credentialed Developer ID signing, hardened-runtime validation, notarization,
and Gatekeeper assessment as separate blocking release steps before this
restriction can be removed.

### 11. Publish

Push the branch and tag:

```sh
git push origin release/2026.06.0
git push origin v2026.06.0
```

Attach to the GitHub release:
- `zag-$VERSION-$PLATFORM.tar.gz`
- `zag-$VERSION-$PLATFORM.tar.gz.sha256`

### 12. Post announcement

The announcement must cover:
- What's new (summarize CHANGELOG.md additions).
- What's changed or removed.
- Migration guide for any breaking changes (language, ABI, or CLI).
- Minimum platform requirements.
- How to bootstrap from the seed binary.

---

## Post-Release

- Bump `selfhost/version.zag` back to `"2026.07.0-dev"` on the main branch.
- Update `zag-poc/zag.mod` to `version = "2026.07.0-dev"`.
- Commit: `git commit -m "post-release: start 2026.07.0-dev cycle"`.

---

## Release Cadence

Releases follow the CalVer `YYYY.MM.PATCH` scheme. The target cadence is one
release per month for edition `2026`. Patch releases (`YYYY.MM.1`,
`YYYY.MM.2`) are issued for blocking bug fixes only and skip steps 1 and 7.
