# Zag Release Process

`make release-check` is the sole release-blocking test closure. `release.sh`
invokes it; this document does not maintain a second list of suites.

The strict ZagScript capability matrix is intentionally first in that closure.
A partial or unavailable frozen capability refuses release before expensive
self-host work. Packaging changes must never bypass or soften that boundary.

## Release invariants

- Release versions use stable CalVer `YYYY.MM.PATCH`; `-dev` cannot be tagged.
- `selfhost/version.zag` and `zag.mod` must report the exact requested version.
- `CHANGELOG.md` must already contain a section for that version.
- The version, changelog, source, authority documents, and seed binary must be
  committed before release begins.
- The entire repository must be clean, including untracked files, both before
  the gate and after release-tool builds.
- Builds run as the ordinary user. Elevation is permitted only for the
  copy-only `make install`/`make install-only` phase.
- Both architecture archives, their SHA-256 checksums, identical source
  manifests, identical normalized VSIX, archive layouts, ELF policies, and
  isolated installs must all verify before a signed tag is created.
- A release never auto-commits, rewrites the changelog, overwrites an existing
  archive, or creates an unsigned fallback tag.

## 1. Prepare and commit the release source

Cut a release branch from the intended authority commit. Update both version
sources and replace the changelog's unreleased heading:

```zag
fn zag_version() []u8 { return "2026.07.0"; }
fn zag_edition() []u8 { return "2026"; }
```

```text
# zag.mod
version = "2026.07.0"
```

```markdown
## [2026.07.0] — 2026-07-31
```

Rebuild the committed seed to its byte-identical fixpoint, review all source
and documentation changes, then commit them. Confirm that nothing remains:

```sh
git status --short
```

The command must print nothing. In particular, `docs/SUPPORT.md`,
`docs/DEPENDENCIES.md`, the editor lockfile/license, and every input required by
the release gate must be tracked rather than supplied from a workstation.

## 2. Run the canonical closure

The release command runs this itself. It can be run in advance while fixing a
candidate:

```sh
make release-check
```

This target owns the exact closure and ordering. Individual native, semantic,
ARM, GPU, ABI, driver, daemon, or ZagScript scripts are focused diagnostics;
passing a hand-selected subset is not release evidence.

The separate `make test-zagscript-master` workstation/benchmark gate remains
manual because it requires host services and extended evidence. It is not a
substitute for the fail-closed strict ZagScript release gate.

## 3. Configure signed tags

The final operation uses `git tag -s`. Configure and test the release signing
identity before starting:

```sh
git config user.signingkey
gpg --list-secret-keys
```

There is no automatic unsigned fallback.

## 4. Build both architecture candidates

The x86-64 and native AArch64 jobs must start from the exact same committed
source. Produce `znc`, `zagd`, and `zag-lsp` for each architecture, retain the
native bootstrap/fixpoint logs, and package each job explicitly:

```bash
arch=x86_64 # set to aarch64 in the native AArch64 job
case "$arch" in
  x86_64) target_args=() ;;
  aarch64) target_args=(--target arm64) ;;
  *) exit 2 ;;
esac
artifact_dir="artifacts/$arch"
compiler=${ZAG_RELEASE_COMPILER:-./znc} # AArch64 job sets the trusted native path
mkdir -p "$artifact_dir"
"$compiler" selfhost/native/znc.zag "${target_args[@]}" -o "$artifact_dir/znc" \
  --no-analyze --no-foreground-cache --no-zagd
"$compiler" selfhost/zagd_daemon.zag "${target_args[@]}" -o "$artifact_dir/zagd" \
  --no-analyze --no-foreground-cache --no-zagd
"$compiler" selfhost/lsp/zag-lsp.zag "${target_args[@]}" -o "$artifact_dir/zag-lsp" \
  --no-analyze --no-foreground-cache --no-zagd
```

The AArch64 commands must be run by the separately verified native AArch64
compiler; `--target arm64` selects its output target and is not itself evidence
about the host that ran it.

```sh
./release.sh --package-only 2026.07.0 x86_64 dist artifacts/x86_64 zag-lang.vsix
./release.sh --package-only 2026.07.0 aarch64 dist artifacts/aarch64 zag-lang.vsix
```

`--package-only` never tags or publishes. It validates the supplied ELF
architecture and stack policy, creates a deterministic archive and checksum,
normalizes every member to numeric owner `0/0`, mode `0644`/`0755`, and the
source-commit timestamp, records the source commit and candidate identity,
checks the complete source manifest, and performs a copy-only staged install.
It deliberately does not claim that a gate ran; finalization reruns the
canonical closure and rebuilds all six binaries before signing.

The tracked seed is x86-64. Cross-compiling an AArch64 ELF or running it under
qemu-user is not native AArch64 bootstrap evidence. The AArch64 job therefore
requires a separately trusted native seed and must retain its physical/native
bootstrap and execution evidence as an external release prerequisite. The
finalizer's deterministic cross-rebuild comparison supplements that evidence;
it does not replace it.

For a host that already has matching trusted native tools, the one-argument
form remains a gated convenience:

```sh
./release.sh 2026.07.0
```

It runs `make release-check`, rebuilds the host tools, and builds the VS Code
extension inside a temporary Git-exported editor tree, so the live editor
checkout and its `node_modules` are not mutated. It packages one architecture
and never tags; the other architecture is still mandatory.

The archive name is one of:

```text
zag-VERSION-x86_64-linux.tar.gz
zag-VERSION-aarch64-linux.tar.gz
```

Transfer both archives and their `.sha256` sidecars to one clean checkout at the
same commit. An x86-64 archive is not evidence for AArch64 and vice versa.

## 5. Verify the pair and create one signed tag

Only after both candidates exist, run once from the finalizing checkout:

```sh
./release.sh --finalize 2026.07.0 \
  dist/zag-2026.07.0-x86_64-linux.tar.gz \
  dist/zag-2026.07.0-aarch64-linux.tar.gz
```

Finalization runs on the primary x86-64 seed host and is fail-closed. It
verifies both sidecars before extraction, rejects unsafe archive member types,
checks each tool's declared architecture and non-executable stack policy,
proves both archives contain the same normalized VSIX and complete source
manifest, matches every source byte and `RELEASE_COMMIT` against the clean
checkout, and performs copy-only staged installs. It then reruns
`make release-check` at the exact tag commit and deterministically rebuilds
`znc`, `zagd`, and `zag-lsp` for both targets from that source. All six archived
binaries must be byte-identical to those rebuilds. Only then does it create one
signed `vVERSION` tag whose message binds the source commit and both archive
hashes. There is no single-architecture tagging path and no unsigned fallback.

The shared verifier can be exercised without gates, rebuilds, or ref changes:

```sh
./release.sh --finalize-dry-run 2026.07.0 \
  dist/zag-2026.07.0-x86_64-linux.tar.gz \
  dist/zag-2026.07.0-aarch64-linux.tar.gz
```

This dry run is a packaging diagnostic only. It cannot create a tag and is not
release evidence.

## Archive contract

Every archive has one top-level directory and contains:

- executable `znc`, `zagd`, `zag-lsp`, `bootstrap.sh`, `release.sh`, and
  `tools/zagd-user-service.sh`;
- `Makefile`, `zag.mod`, `RELEASE_COMMIT`, `RELEASE_CANDIDATE`,
  `SOURCE_MANIFEST.sha256`, the root `LICENSE`, release/version/compatibility
  documents, and `docs/SUPPORT.md` plus `docs/DEPENDENCIES.md`;
- `benchmarks/`, `examples/`, `programs/`, `selfhost/`, `std/`, `tests/`,
  `docs/`, and `tools/`;
- VS Code extension source and the installable `zag-lang.vsix`.

It must not contain symlinks, `node_modules`, project caches, object files, or
generated `.zag.c`, `.zag.out`, or `.zag.zir.c` files.
Every candidate path writes the same exact `RELEASE_CANDIDATE` identity record.
It binds the format, version, architecture, and commit but is not a signature or
gate attestation. The finalizer trusts neither the record nor its sidecar in
isolation: it recomputes both hashes, matches the complete source snapshot, and
derives the final binaries again before the signed tag becomes the authority.

The focused package test exercises this exact builder with the current native
candidate tools, verifies tags are unchanged, validates reproducibility and the
checksum, extracts the archive, and installs it under non-default `PREFIX` and
`DESTDIR` paths:

```sh
make test-release-package
```

`--package-only` is candidate generation, not release evidence by itself. It
deliberately skips the clean-tree and compiler gate so CI can package already
built architecture artifacts; the real finalizer rejects source drift and
artifacts that are not byte-identical to its gated source rebuild.

## Review and publish

Verify the signature, both sidecars, the tagged source commit, and the exact
archive hashes before any push:

```sh
version=2026.07.0
tag="v$version"
git verify-tag "$tag"
tag_message=$(git tag -l --format='%(contents)' "$tag")
commit=$(git rev-parse HEAD)
tag_commit=$(git rev-list -n 1 "$tag")
test "$tag_commit" = "$commit"
grep -Fqx "Source commit: $commit" <<<"$tag_message"
for arch in x86_64 aarch64; do
  archive="zag-$version-$arch-linux.tar.gz"
  (cd dist && sha256sum -c "$archive.sha256")
  hash=$(sha256sum "dist/$archive" | awk '{ print $1 }')
  tag_hash=$(awk -v artifact="$archive" \
    '$0 == "Artifact: " artifact { getline; sub(/^SHA-256: /, ""); print; exit }' \
    <<<"$tag_message")
  test "$tag_hash" = "$hash"
done
git push origin HEAD "$tag"
```

Attach each architecture archive and matching checksum to the release. The
announcement must state platform scope, bootstrap instructions, ABI or CLI
changes, migration requirements, and the exact gate commit.

If any host gate, build, archive, checksum, source comparison, final closure, or
staged install fails, no tag has been created. Fix and commit the source,
restore both clean checkouts, discard both candidates, and rebuild the pair.
If signing itself fails, the verified archives remain local but there is still
no release tag.

## Post-release

On the development branch, advance `selfhost/version.zag` and `zag.mod` to the
next `-dev` CalVer in a separate commit. Never modify the tagged tree.

Releases target a monthly CalVer cadence. Patch releases repeat the same
closure and packaging contract; urgency does not permit skipped gates.
