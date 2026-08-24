#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-generic-metadata.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$compiler" "$root/selfhost/native/ncodegen_generics_metadata_test.zag" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/metadata-test"

set +e
"$tmp/metadata-test"
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "generic metadata: regression witness exited $status, expected 42" >&2
    exit 1
fi

echo "generic metadata: template visibility, layout, and annotations preserved"
