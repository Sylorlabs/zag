#!/usr/bin/env bash
# Optional test-only proof and behavioral regression for reflexive integer cmpi.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
solver=${Z3:-z3}
command -v "$solver" >/dev/null || { echo 'z3 required' >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zopt-reflexive-cmpi.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
if ! "$solver" -T:60 -smt2 tests/zopt_reflexive_cmpi_qfbv.smt2 \
     >"$tmp/proof" 2>"$tmp/stderr"; then
    cat "$tmp/stderr" "$tmp/proof" >&2
    echo 'Z3 QF_BV reflexive comparison proof failed' >&2
    exit 1
fi
printf 'unsat\n%.0s' {1..12} >"$tmp/expected"
if [ -s "$tmp/stderr" ] || ! cmp -s "$tmp/expected" "$tmp/proof"; then
    cat "$tmp/stderr" "$tmp/proof" >&2
    echo 'unexpected reflexive comparison proof result' >&2
    exit 1
fi
"$compiler" selfhost/native/zopt_reflexive_cmp_test.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/test"
echo 'zopt-reflexive-cmpi QF_BV: unsat=12 (6 predicates x 2 widths)'
