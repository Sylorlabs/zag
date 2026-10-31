#!/usr/bin/env bash
# Contract test for the documentation tree in a source release archive.
# This only stages files under a temporary directory; it never runs release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! grep -Fq 'cp -r docs "$STAGING/"' release.sh; then
    echo 'release.sh is missing the authoritative docs staging command' >&2
    exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/zag-release-docs.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/docs"
cp -r docs/. "$stage/docs/"

missing=0
while IFS= read -r target; do
    if [[ ! -f "$stage/$target" ]]; then
        echo "missing staged README/INSTALL documentation target: $target" >&2
        missing=1
    fi
done < <(grep -hoE 'docs/[A-Za-z0-9_.-]+\.md' README.md INSTALL.md | sort -u)

# These are release-boundary docs even when a future README/INSTALL edit does
# not link every one directly.
for target in \
    docs/SUPPORT.md \
    docs/ZAGSCRIPT_GUIDE.md \
    docs/ZAGSCRIPT_SEMANTICS.md \
    docs/ZAGSCRIPT_HARDENING.md \
    docs/ZAGSCRIPT_IMPLEMENTATION_AUDIT.md \
    docs/ZAGSCRIPT_1_0_CAPABILITIES.generated.md \
    docs/DEPENDENCIES.md \
    docs/LOCAL_PACKAGE_IMPORTS.md \
    docs/PACKAGE_SIGNATURES.md
do
    if [[ ! -f "$stage/$target" ]]; then
        echo "missing staged required release documentation: $target" >&2
        missing=1
    fi
done

if (( missing != 0 )); then
    exit 1
fi
echo 'release archive documentation contract: pass'
