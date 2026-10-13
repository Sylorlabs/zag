#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

scope=docs/ZAGSCRIPT_1_0_SCOPE.md
matrix=tests/zagscript_1_0_capabilities.tsv
test -s "$scope"
test -s "$matrix"

grep -q 'collection/text boundary' "$scope"
grep -q 'network boundary' "$scope"
grep -q 'concurrency boundary' "$scope"
grep -q 'package boundary' "$scope"
grep -q 'optimizer boundary' "$scope"
grep -q 'Deployment authority is platform-scoped' "$scope"

tmp=$(mktemp "${TMPDIR:-/tmp}/zagscript-scope.XXXXXX")
trap 'rm -f "$tmp"' EXIT
bash tests/generate_zagscript_1_0_matrix.sh > "$tmp"
diff -u docs/ZAGSCRIPT_1_0_CAPABILITIES.generated.md "$tmp"

echo 'ZagScript 1.0 support boundary: PASS'
