#!/usr/bin/env bash
# release.sh — cut a validated Zag release
#
# Usage:  ./release.sh 2026.06.0
#
# What this does:
#   Preflight. Checks the frozen ZagScript 1.0 matrix (aborts quickly)
#   1. Rebuilds znc from the committed seed (bootstrap)
#   1b. Verifies the rebuilt compiler is a byte-identical fixpoint
#   2. Runs the authoritative v1 release gate (MUST pass — aborts if not)
#   2b. Runs the strict ZagScript 1.0 gate (MUST pass — aborts if not)
#   3. Runs the authoritative host-scoped `make test` release matrix
#   5. Optionally stamps CHANGELOG.md with the version + date
#   6. Commits + creates a signed release tag
#   7. Builds a release tarball named for the native host platform
#
# ./znc is the only compiler. Retired implementations live only in Git history.
set -euo pipefail
cd "$(dirname "$0")"
. ./tests/portable.sh

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh 2026.06.0" >&2
    exit 1
fi
if [[ ! $VERSION =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
    echo "ERROR: release version must be one safe tag/path component." >&2
    exit 1
fi

release_target_args=()
case "$(uname -s):$(uname -m)" in
    Darwin:arm64)
        RELEASE_PLATFORM=macos-arm64
        release_target_args=(--target macos-arm64)
        ;;
    Linux:x86_64|Linux:amd64)
        RELEASE_PLATFORM=linux-x86_64
        ;;
    Linux:aarch64|Linux:arm64)
        RELEASE_PLATFORM=linux-arm64
        release_target_args=(--target arm64)
        ;;
    *)
        echo "ERROR: unsupported release host: $(uname -s) $(uname -m)" >&2
        exit 1
        ;;
esac

case "$RELEASE_PLATFORM" in
    linux-x86_64)
        release_compiler="$PWD/znc"
        release_daemon="$PWD/zagd"
        ;;
    *)
        release_compiler="$PWD/znc-$RELEASE_PLATFORM"
        release_daemon="$PWD/zagd-$RELEASE_PLATFORM"
        ;;
esac

release_seed=""
for release_candidate in \
    "$PWD/seeds/$RELEASE_PLATFORM/znc" \
    "$PWD/znc-$RELEASE_PLATFORM" \
    "$PWD/znc"; do
    [ -x "$release_candidate" ] || continue
    if zag_assert_native_executable "$release_candidate"; then
        release_seed=$release_candidate
        break
    fi
done
if [ -z "$release_seed" ]; then
    echo "ERROR: no executable $RELEASE_PLATFORM release seed found" >&2
    exit 1
fi
export ZNC="$release_seed"

echo "════════════════════════════════════════════════════════════════"

bash tests/check_pure_zag_tree.sh
echo "  Zag release: $VERSION"
if [ "$RELEASE_PLATFORM" = macos-arm64 ]; then
    echo "  Scope: Apple-Silicon development archive (ad-hoc signed; not notarized)"
fi
echo "════════════════════════════════════════════════════════════════"

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "ERROR: release requires a clean worktree." >&2
    exit 1
fi

if ! grep -Fq "return \"$VERSION\"" selfhost/version.zag; then
    echo "ERROR: selfhost/version.zag does not report $VERSION." >&2
    exit 1
fi
release_manifest_version=$(sed -n \
    's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' \
    zag.mod | sed -n '1p')
if [ "$release_manifest_version" != "$VERSION" ]; then
    echo "ERROR: zag.mod reports $release_manifest_version, not $VERSION." >&2
    exit 1
fi

# Fail before any expensive self-host work while the frozen capability matrix
# still contains partial or unavailable rows.
echo ""
echo "── preflight: ZagScript 1.0 capability matrix ──"
if ! bash tests/run_zagscript_1_0_matrix_selftest.sh; then
    echo "" >&2
    echo "ERROR: ZagScript matrix validator self-test failed — release aborted." >&2
    exit 1
fi
if ! bash tests/run_zagscript_1_0_matrix.sh --release; then
    echo "" >&2
    echo "ERROR: ZagScript 1.0 capability matrix is incomplete — release aborted." >&2
    exit 1
fi

# ── 1. Bootstrap: rebuild znc from seed ──────────────────────────────────────
echo ""
echo "── step 1: bootstrap (rebuild znc from seed) ──"
ZAG_BOOTSTRAP_SEED="$release_seed" \
ZAG_BOOTSTRAP_OUTPUT="$release_compiler" \
ZAG_BOOTSTRAP_DAEMON_OUTPUT="$release_daemon" \
    ./bootstrap.sh
export ZNC="$release_compiler"
export ZNC_SEED="$release_compiler"

# ── 1b. Fixpoint check ───────────────────────────────────────────────────────
echo ""
echo "── step 1b: byte-identical fixpoint check ──"
bash tests/check_native_bootstrap_repro.sh

# ── 2. Authoritative v1 release gate ─────────────────────────────────────────
# Poisons host C tools to prove znc is genuinely cc-free.  Must pass; otherwise
# the release is aborted — a broken authority gate means the compiler is not
# production-ready.
echo ""
echo "── step 2: native authority gate (v1 release gate) ──"
if ! bash tests/run_native_authority.sh; then
    echo "" >&2
    echo "ERROR: run_native_authority.sh FAILED — release aborted." >&2
    echo "       Fix the authority gate before cutting a release." >&2
    exit 1
fi

# Once the matrix and checked-in compiler authority are proven, the aggregate
# executable ZagScript authority remains mandatory. Matrix status alone never
# certifies a release.
echo ""
if [ "$RELEASE_PLATFORM" = linux-x86_64 ]; then
    echo "── step 2b: strict ZagScript 1.0 Linux x86-64 release gate ──"
    if ! bash tests/run_zagscript_release_gate.sh; then
        echo "" >&2
        echo "ERROR: run_zagscript_release_gate.sh FAILED — release aborted." >&2
        echo "       Complete every frozen ZagScript 1.0 capability before release." >&2
        exit 1
    fi
else
    echo "── step 2b: strict ZagScript Linux-only aggregate: not applicable to $RELEASE_PLATFORM ──"
fi

# ── 3. Authoritative host-scoped release matrix ──────────────────────────────
echo ""
echo "── step 3: host-scoped make test release gate ($RELEASE_PLATFORM) ──"
if ! make test; then
    echo "" >&2
    echo "ERROR: host-scoped make test FAILED — release aborted." >&2
    exit 1
fi

# ── 4. Stamp CHANGELOG.md (if present) ───────────────────────────────────────
echo ""
echo "── step 5: stamp CHANGELOG.md ──"
if [ -f CHANGELOG.md ]; then
    TODAY=$(date +%Y-%m-%d)
    if grep -q '## \[Unreleased\]' CHANGELOG.md; then
        # An attached backup suffix is accepted by both GNU and BSD sed.
        sed -i.bak "s/## \[Unreleased\]/## [$VERSION] — $TODAY/" CHANGELOG.md
        rm -f CHANGELOG.md.bak
        echo "  stamped CHANGELOG.md: [$VERSION] — $TODAY"
    else
        echo "  no [Unreleased] section found in CHANGELOG.md; skipping stamp"
    fi
else
    echo "  CHANGELOG.md not found; skipping stamp"
fi

# ── 5. Commit and tag ────────────────────────────────────────────────────────
echo ""
echo "── step 6: commit + tag v$VERSION ──"
release_git_paths=(CHANGELOG.md selfhost/version.zag zag.mod)
if [ "$RELEASE_PLATFORM" = linux-x86_64 ]; then
    release_git_paths+=(znc)
fi
git add "${release_git_paths[@]}"
git commit --allow-empty -m "release: $VERSION"
release_tag_message=$(sed -n '1,15p' CHANGELOG.md)
if [ -z "$release_tag_message" ]; then
    echo "ERROR: cannot create signed release tag without a CHANGELOG entry." >&2
    exit 1
fi
git tag -s "v$VERSION" -m "$release_tag_message"
echo "  tagged v$VERSION"

# ── 6. Build release tarball ─────────────────────────────────────────────────
echo ""
echo "── step 7: build release tarball ──"
TARNAME="zag-$VERSION-$RELEASE_PLATFORM"
STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zag-release.XXXXXX")
STAGING="$STAGING_ROOT/$TARNAME"
cleanup_staging() { rm -rf "$STAGING_ROOT"; }
release_signal() { cleanup_staging; exit 130; }
trap cleanup_staging EXIT
trap release_signal HUP INT TERM
mkdir -p "$STAGING"

# Primary release artifacts: compiler, planner daemon, and editor server.
"$release_compiler" selfhost/lsp/zag-lsp.zag "${release_target_args[@]}" \
    -o "$STAGING/zag-lsp" --no-zagd
cp "$release_compiler" "$STAGING/znc"
cp "$release_daemon" "$STAGING/zagd"
cp bootstrap.sh "$STAGING/"

# Source, tests, install helpers, documentation, and editor integration are
# required release contents. A copy error must abort instead of silently
# producing a partial tarball.
cp Makefile zag.mod "$STAGING/"
cp -R examples programs tests selfhost std tools docs "$STAGING/"
cp -R ../editors "$STAGING/"
# Ignored packaging outputs may exist even in a clean worktree. Keep the editor
# sources, but never inherit a workstation's dependency tree or an older VSIX.
rm -rf "$STAGING/editors/vscode/node_modules"
rm -f "$STAGING/editors/vscode/zag-lang.vsix"
find "$STAGING" -name '.DS_Store' -delete
find "$STAGING" -type d -name '.zag-cache' -prune -exec rm -rf {} +

# Ship an installable editor client, not instructions that require users to
# reconstruct release tooling. Node is a release-packaging dependency only.
(cd ../editors/vscode && npm ci && npm run package)
cp ../editors/vscode/zag-lang.vsix "$STAGING/"

# Required license and release documentation. The repository license lives one
# level above zag-poc, but the archive is a standalone distribution.
cp ../LICENSE "$STAGING/LICENSE"
cp README.md BOOTSTRAP.md INSTALL.md CHANGELOG.md COMPATIBILITY.md \
    NATIVE_BOOTSTRAP_REPRODUCIBILITY.md RELEASES.md VERSIONING.md "$STAGING/"

# Strip generated artifacts from the tarball and reject forbidden source types.
# This operates only inside the fresh staging directory: ignored workstation
# binaries are not visible to the clean-worktree preflight, but must never be
# inherited by any platform archive.
find "$STAGING" -type d -name '*.dSYM' -prune -exec rm -rf {} +
find "$STAGING" \( \
    -name '*.zag.c' -o \
    -name '*.out' -o \
    -name '*.zag.zir.c' -o \
    -name '*.o' -o \
    -name '*.a' -o \
    -name '*.a.o' -o \
    -name '*.dylib' -o \
    -name '*.so' -o \
    -name '*.wasm' -o \
    -name '*.mlir' \
    \) -delete
forbidden_artifact=$(find "$STAGING" \( \
    -name '*.zag.c' -o \
    -name '*.out' -o \
    -name '*.zag.zir.c' -o \
    -name '*.o' -o \
    -name '*.a' -o \
    -name '*.a.o' -o \
    -name '*.dylib' -o \
    -name '*.so' -o \
    -name '*.wasm' -o \
    -name '*.mlir' -o \
    -name '*.dSYM' \
    \) -print -quit)
if [ -n "$forbidden_artifact" ]; then
    echo "ERROR: forbidden generated artifact remains in release: $forbidden_artifact" >&2
    exit 1
fi

# Finder downloads and ordinary copies can attach quarantine/provenance xattrs
# to otherwise deterministic source inputs. Tell both BSD tar and GNU tar not
# to serialize them. COPYFILE_DISABLE also prevents macOS copyfile(3) from
# synthesizing AppleDouble payloads; it is harmless on GNU/Linux.

# Validate the tree users will receive, including native binary identity, the
# shipped Makefile install recipe, compiler/version coherence, and a native
# compile/run smoke. The same validator runs after extraction below.
bash "$STAGING/tests/check_release_package.sh" \
    "$STAGING" "$RELEASE_PLATFORM" "$VERSION"

COPYFILE_DISABLE=1 tar --no-xattrs -czf "$TARNAME.tar.gz" \
    -C "$STAGING_ROOT" "$TARNAME"
EXTRACTED_ROOT="$STAGING_ROOT/extracted"
EXTRACTED="$EXTRACTED_ROOT/$TARNAME"
mkdir -p "$EXTRACTED_ROOT"
COPYFILE_DISABLE=1 tar --no-xattrs -xzf "$TARNAME.tar.gz" \
    -C "$EXTRACTED_ROOT"
if ! diff -qr "$STAGING" "$EXTRACTED" >"$STAGING_ROOT/archive.diff"; then
    echo "ERROR: extracted release differs from staged release:" >&2
    cat "$STAGING_ROOT/archive.diff" >&2
    exit 1
fi
bash "$EXTRACTED/tests/check_release_package.sh" \
    "$EXTRACTED" "$RELEASE_PLATFORM" "$VERSION"

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$TARNAME.tar.gz" >"$TARNAME.tar.gz.sha256"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$TARNAME.tar.gz" >"$TARNAME.tar.gz.sha256"
else
    echo "ERROR: SHA-256 tool unavailable (need sha256sum or shasum)" >&2
    exit 1
fi
cleanup_staging
trap - EXIT HUP INT TERM

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Release $VERSION ready: $TARNAME.tar.gz"
echo "  Checksum: $TARNAME.tar.gz.sha256"
echo "  Installed tools: znc, zagd, zag-lsp"
echo ""
echo "  Push with:"
echo "    git push origin HEAD v$VERSION"
echo "════════════════════════════════════════════════════════════════"
