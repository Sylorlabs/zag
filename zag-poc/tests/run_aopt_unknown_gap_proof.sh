#!/usr/bin/env bash
# Scoped SMT obligations for the nonadjacent unknown-value transfer.
set -euo pipefail
cd "$(dirname "$0")/.."
solver=${Z3:-z3}
command -v "$solver" >/dev/null || { echo 'z3 is required for this proof' >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/aopt-unknown-gap-proof.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$solver" -T:60 -smt2 tests/aopt_unknown_gap_qfabv.smt2 >"$tmp/proof" 2>"$tmp/stderr"
printf 'unsat\nunsat\nunsat\nunsat\nsat\nsat\nsat\n' >"$tmp/expected"
if [ -s "$tmp/stderr" ] || ! cmp -s "$tmp/expected" "$tmp/proof"; then
    cat "$tmp/stderr" "$tmp/proof" >&2
    echo 'aopt nonadjacent-gap proof: FAIL' >&2
    exit 1
fi
echo 'aopt nonadjacent-gap proof: PASS (4 unsat obligations, 3 counterexample witnesses)'
