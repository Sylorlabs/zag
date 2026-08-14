#!/usr/bin/env bash
# release.sh — cut a reproducible Zag release
#
# Usage:  ./release.sh 2026.06.0
#
# What this does:
#   Preflight. Checks the frozen ZagScript 1.0 matrix (aborts quickly)
#   1. Rebuilds znc from the committed seed (bootstrap)
#   1b. Verifies the rebuilt compiler is a byte-identical fixpoint
#   2. Runs the authoritative v1 release gate (MUST pass — aborts if not)
#   2b. Runs the strict ZagScript 1.0 gate (MUST pass — aborts if not)
#   3. Runs the full native backend test suite (MUST pass — aborts if not)
#   4. Runs semantic, diagnostic, tooling, and program conformance
#   5. Optionally stamps CHANGELOG.md with the version + date
#   6. Commits + tags the release
#   7. Builds a release tarball: zag-<version>-x86_64-linux.tar.gz
#
# ./znc is the only compiler. Retired implementations live only in Git history.
set -euo pipefail
cd "$(dirname "$0")"
export ZNC="$PWD/znc"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh 2026.06.0" >&2
    exit 1
fi
if [[ ! $VERSION =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
    echo "ERROR: release version must be one safe tag/path component." >&2
    exit 1
fi

echo "════════════════════════════════════════════════════════════════"

bash tests/check_pure_zag_tree.sh
echo "  Zag release: $VERSION"
echo "════════════════════════════════════════════════════════════════"

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "ERROR: release requires a clean worktree." >&2
    exit 1
fi

if ! grep -Fq "return \"$VERSION\"" selfhost/version.zag; then
    echo "ERROR: selfhost/version.zag does not report $VERSION." >&2
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
./bootstrap.sh

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
echo "── step 2b: strict ZagScript 1.0 release gate ──"
if ! bash tests/run_zagscript_release_gate.sh; then
    echo "" >&2
    echo "ERROR: run_zagscript_release_gate.sh FAILED — release aborted." >&2
    echo "       Complete every frozen ZagScript 1.0 capability before release." >&2
    exit 1
fi

# ── 3. Native backend test suite ─────────────────────────────────────────────
echo ""
echo "── step 3: native backend suite (run_native.sh) ──"
if ! bash tests/run_native.sh; then
    echo "" >&2
    echo "ERROR: run_native.sh FAILED — release aborted." >&2
    exit 1
fi

# ── 4. Conformance suites ────────────────────────────────────────────────────
echo ""
echo "── step 4: semantic, diagnostic, tooling, and program conformance ──"
bash tests/run_semantics.sh
bash tests/run_diag.sh
bash tests/run_tooling.sh
bash tests/run_programs.sh

# ── 5. Stamp CHANGELOG.md (if present) ───────────────────────────────────────
echo ""
echo "── step 5: stamp CHANGELOG.md ──"
if [ -f CHANGELOG.md ]; then
    TODAY=$(date +%Y-%m-%d)
    if grep -q '## \[Unreleased\]' CHANGELOG.md; then
        sed -i "s/## \[Unreleased\]/## [$VERSION] — $TODAY/" CHANGELOG.md
        echo "  stamped CHANGELOG.md: [$VERSION] — $TODAY"
    else
        echo "  no [Unreleased] section found in CHANGELOG.md; skipping stamp"
    fi
else
    echo "  CHANGELOG.md not found; skipping stamp"
fi

# ── 6. Commit and tag ────────────────────────────────────────────────────────
echo ""
echo "── step 6: commit + tag v$VERSION ──"
git add CHANGELOG.md selfhost/version.zag zag.mod znc
git commit --allow-empty -m "release: $VERSION"
git tag -a "v$VERSION" -m "Zag $VERSION"
echo "  tagged v$VERSION"

# ── 7. Build release tarball ─────────────────────────────────────────────────
echo ""
echo "── step 7: build release tarball ──"
TARNAME="zag-$VERSION-x86_64-linux"
STAGING="/tmp/$TARNAME"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Primary release artifacts: compiler, planner daemon, and editor server.
./znc selfhost/lsp/zag-lsp.zag -o zag-lsp --no-zagd
cp znc zagd zag-lsp "$STAGING/"
cp bootstrap.sh "$STAGING/"

# Source, tests, and editor integration are required release contents. A copy
# error must abort instead of silently producing a partial tarball.
cp -r examples tests selfhost std "$STAGING/"
cp -r ../editors "$STAGING/"

# Ship an installable editor client, not instructions that require users to
# reconstruct release tooling. Node is a release-packaging dependency only.
(cd ../editors/vscode && npm ci && npm run package)
cp ../editors/vscode/zag-lang.vsix "$STAGING/"

# Required release documentation.
cp README.md BOOTSTRAP.md INSTALL.md CHANGELOG.md "$STAGING/"

# Strip generated artifacts from the tarball and reject forbidden source types.
find "$STAGING" \( \
    -name '*.zag.c' -o \
    -name '*.zag.out' -o \
    -name '*.zag.zir.c' -o \
    -name '*.o' \
    \) -delete
forbidden_artifact=$(find "$STAGING" \( \
    -name '*.zag.c' -o \
    -name '*.zag.out' -o \
    -name '*.zag.zir.c' -o \
    -name '*.o' \
    \) -print -quit)
if [ -n "$forbidden_artifact" ]; then
    echo "ERROR: forbidden generated artifact remains in release: $forbidden_artifact" >&2
    exit 1
fi

tar -czf "$TARNAME.tar.gz" -C /tmp "$TARNAME"
rm -rf "$STAGING"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Release $VERSION ready: $TARNAME.tar.gz"
echo "  Installed tools: znc, zagd, zag-lsp"
echo ""
echo "  Push with:"
echo "    git push origin HEAD v$VERSION"
echo "════════════════════════════════════════════════════════════════"
