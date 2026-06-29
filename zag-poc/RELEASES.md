# Zag Release Process

This is the authoritative release checklist. Every step must pass before a
release tag is pushed. Steps marked **BLOCKING** abort the release if they fail.

---

## Prerequisites

- You are on the `native-self-hosting-no-zig` branch (or a release branch cut
  from it).
- `./znc` is the committed seed binary. `./zagc` is present only for
  differential testing; it is NOT a release artifact.
- The working tree is clean (`git status` shows no uncommitted changes).

---

## Checklist

### 1. Freeze the tree

No new features after the release branch is cut. Bug fixes to release-blocking
issues are the only permitted changes.

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

This is the first blocking gate. It poisons host C
tools and verifies that `znc` can rebuild itself and pass the native test suite
with zero external dependencies.

```sh
./tests/run_native_authority.sh
```

Expected: 100% pass. Any failure is a release blocker.

### 4. Run the native language/backend test suite — BLOCKING

```sh
./tests/run_native.sh
```

Expected: all tests pass.

### 5. Run semantic and diagnostic conformance — BLOCKING

```sh
./tests/run_semantics.sh
./tests/run_diag.sh
```

### 5b. Run the differential test suites (informational)

These suites test the legacy C-emitting backend (`zagc`) and the self-hosted
semantic checker. They are not release gates but regressions here indicate
parser or sema bugs that affect both backends.

```sh
./run_tests.sh
./tests/run_selfhost.sh
./tests/run_stdlib.sh
```

### 6. Verify byte-identical self-hosting fixpoint — BLOCKING

```sh
./bootstrap.sh                                   # rebuild znc from seed
./znc selfhost/native/znc.zag -o znc.new         # znc compiles znc
diff znc znc.new && echo "fixpoint OK"
```

Or use the dedicated script:

```sh
./tests/check_native_bootstrap_repro.sh
```

A non-zero diff is a release blocker.

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

### 8. Build and commit seed binaries

Rebuild the seed binaries from source and commit them. Only `znc` is a release
artifact. `zagc` is committed for differential-testing convenience, not as a
supported binary.

```sh
./bootstrap.sh          # produces ./znc only
git add znc             # REQUIRED: znc is the supported seed binary
# git add zagc          # OPTIONAL: zagc is a differential oracle only
git commit -m "release: update seed binaries for 2026.06.0"
```

### 9. Tag the release

Use a signed tag. The tag message should be the first 15 lines of the
`CHANGELOG.md` entry.

```sh
git tag -s v2026.06.0 -m "$(head -15 CHANGELOG.md)"
```

### 10. Build release tarball

Assemble the release tarball. Only include the supported artifacts.

```sh
VERSION=2026.06.0
mkdir -p dist/zag-$VERSION
cp znc bootstrap.sh run_tests.sh dist/zag-$VERSION/
cp -r selfhost/ examples/ std/ dist/zag-$VERSION/
cp README.md BOOTSTRAP.md VERSIONING.md CHANGELOG.md \
   COMPATIBILITY.md RELEASES.md dist/zag-$VERSION/
tar -czf dist/zag-$VERSION.tar.gz -C dist zag-$VERSION
sha256sum dist/zag-$VERSION.tar.gz > dist/zag-$VERSION.tar.gz.sha256
```

### 11. Publish

Push the branch and tag:

```sh
git push origin release/2026.06.0
git push origin v2026.06.0
```

Attach to the GitHub release:
- `zag-$VERSION.tar.gz`
- `zag-$VERSION.tar.gz.sha256`

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
