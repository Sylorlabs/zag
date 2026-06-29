#!/usr/bin/env bash
# release.sh — cut a reproducible Zag release
#
# Usage:  ./release.sh 2026.06.0
#
# What this does:
#   1. Rebuilds znc from the committed seed (bootstrap)
#   2. Runs the authoritative v1 release gate (MUST pass — aborts if not)
#   3. Runs the full native backend test suite (MUST pass — aborts if not)
#   4. Verifies byte-identical fixpoint (znc compiles itself to the same binary)
#   5. Optionally stamps CHANGELOG.md with the version + date
#   6. Commits + tags the release
#   7. Builds a release tarball: zag-<version>-x86_64-linux.tar.gz
#
# NOTE: ./zagc is NOT a release artifact.  ./znc is the only supported compiler.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh 2026.06.0" >&2
    exit 1
fi

echo "════════════════════════════════════════════════════════════════"
echo "  Zag release: $VERSION"
echo "════════════════════════════════════════════════════════════════"

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "ERROR: release requires a clean worktree." >&2
    exit 1
fi

if ! grep -q "return \"$VERSION\"" selfhost/version.zag; then
    echo "ERROR: selfhost/version.zag does not report $VERSION." >&2
    exit 1
fi

# ── 1. Bootstrap: rebuild znc from seed ──────────────────────────────────────
echo ""
echo "── step 1: bootstrap (rebuild znc from seed) ──"
./bootstrap.sh

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

# ── 3. Native backend test suite ─────────────────────────────────────────────
echo ""
echo "── step 3: native backend suite (run_native.sh) ──"
if ! bash tests/run_native.sh; then
    echo "" >&2
    echo "ERROR: run_native.sh FAILED — release aborted." >&2
    exit 1
fi

# ── 4. Fixpoint check ────────────────────────────────────────────────────────
echo ""
echo "── step 4: byte-identical fixpoint check ──"
bash tests/check_native_bootstrap_repro.sh

echo ""
echo "── step 4b: semantic and diagnostic conformance ──"
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

# Primary release artifact: znc (the only supported compiler)
cp znc "$STAGING/"
cp bootstrap.sh run_tests.sh "$STAGING/"

# NOTE: zagc is NOT a release artifact — it is retained in the repository for
# differential testing only.  It is not copied to the release tarball.

# Source and tests
cp -r examples "$STAGING/" 2>/dev/null || true
cp -r tests    "$STAGING/" 2>/dev/null || true
cp -r selfhost "$STAGING/" 2>/dev/null || true
cp -r std      "$STAGING/" 2>/dev/null || true

# Docs
for f in README.md BOOTSTRAP.md INSTALL.md CHANGELOG.md; do
    [ -f "$f" ] && cp "$f" "$STAGING/" || true
done

# Strip generated artifacts from the tarball
find "$STAGING" \( \
    -name '*.zag.c' -o \
    -name '*.zag.out' -o \
    -name '*.zag.zir.c' -o \
    -name '*.o' \
    \) -delete 2>/dev/null || true

tar -czf "$TARNAME.tar.gz" -C /tmp "$TARNAME"
rm -rf "$STAGING"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Release $VERSION ready: $TARNAME.tar.gz"
echo "  Primary binary: znc (the only supported Zag v1 compiler)"
echo ""
echo "  Push with:"
echo "    git push origin HEAD v$VERSION"
echo "════════════════════════════════════════════════════════════════"
