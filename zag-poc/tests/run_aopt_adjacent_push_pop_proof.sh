#!/usr/bin/env bash
# Optional, scoped solver proof for the adjacent AArch64 expression-stack copy.
set -euo pipefail
cd "$(dirname "$0")/.."
solver=${Z3:-z3}
command -v "$solver" >/dev/null || { echo 'z3 is required for this proof' >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/aopt-adjacent-proof.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$solver" -T:60 -smt2 tests/aopt_adjacent_push_pop_qfabv.smt2 >"$tmp/proof" 2>"$tmp/stderr"
printf 'unsat\nunsat\nunsat\nsat\n' >"$tmp/expected"
if [ -s "$tmp/stderr" ] || ! cmp -s "$tmp/expected" "$tmp/proof"; then
    cat "$tmp/stderr" "$tmp/proof" >&2
    echo 'aopt adjacent-pair mathematical proof: FAIL' >&2
    exit 1
fi
echo 'aopt adjacent-pair mathematical proof: PASS (3 unsat obligations, 1 memory-observation witness)'
