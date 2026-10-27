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
if ! zag_verify_manifest_toolchain "$release_seed" "$PWD/zag.mod"; then
    echo "ERROR: release seed does not match the zag.mod toolchain identity pin." >&2
    exit 1
fi
export ZNC="$release_seed"

# Editor packaging is a release-only dependency. Fail before compiler work,
# changelog mutation, commits, or tags if the locked Node toolchain is absent.
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 ||
   ! command -v unzip >/dev/null 2>&1; then
    echo "ERROR: release packaging requires Node.js 22+, npm, and unzip." >&2
    exit 1
fi
release_node_major=$(node -p 'Number(process.versions.node.split(".")[0])')
case "$release_node_major" in
    ''|*[!0-9]*)
        echo "ERROR: could not determine the Node.js major version." >&2
        exit 1
        ;;
esac
if [ "$release_node_major" -lt 22 ]; then
    echo "ERROR: release packaging requires Node.js 22+ (found $(node --version))." >&2
    exit 1
fi

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

# Build the editor artifact before any release mutation. npm ci consumes the
# committed lockfile, while SOURCE_DATE_EPOCH in the package script makes the
# VSIX byte-reproducible. Prove that property instead of merely assuming it.
echo ""
echo "── preflight: locked VS Code extension package ──"
(cd ../editors/vscode && npm ci && npm run package)
release_vsix_first=$(zag_sha256_file ../editors/vscode/zag-lang.vsix)
(cd ../editors/vscode && npm run package)
release_vsix_second=$(zag_sha256_file ../editors/vscode/zag-lang.vsix)
if [ "$release_vsix_first" != "$release_vsix_second" ]; then
    echo "ERROR: repeated VS Code packages are not byte-identical." >&2
    exit 1
fi
echo "  VSIX sha256: $release_vsix_second"
if ! unzip -tq ../editors/vscode/zag-lang.vsix >/dev/null ||
   ! unzip -p ../editors/vscode/zag-lang.vsix extension/out/extension.js |
       awk 'index($0, "vscode-languageclient") { found=1 } END { exit !found }' ||
   ! unzip -p ../editors/vscode/zag-lang.vsix extension/out/extension.js |
       awk 'index($0, "zag-lsp") { found=1 } END { exit !found }'; then
    echo "ERROR: VS Code package is corrupt or missing its bundled client/server default." >&2
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
    if ! env -u ZAGSCRIPT_RELEASE_SHARD_START -u ZAGSCRIPT_RELEASE_SHARD_END \
        bash tests/run_zagscript_release_gate.sh; then
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
# The exact production recipe is independently exercisable on a development
# tree. This helper performs no Git writes and refuses existing artifacts.
bash tools/package-release.sh "$VERSION" "$RELEASE_PLATFORM" \
    "$release_compiler" "$release_daemon" ../editors/vscode/zag-lang.vsix "$PWD"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Release $VERSION ready: $TARNAME.tar.gz"
echo "  Checksum: $TARNAME.tar.gz.sha256"
echo "  Installed tools: znc, zagd, zag-lsp"
echo ""
echo "  Push with:"
echo "    git push origin HEAD v$VERSION"
echo "════════════════════════════════════════════════════════════════"
