#!/usr/bin/env bash
# Proves selected QF_BV identities and exercises the matching test-only ZIR
# constant folds. This optional check is outside the v2 release gate.
# Manual: ZNC=./znc-macos-arm64 bash tests/run_zopt_signed_divmod_proof.sh
# On Linux, use the matching source-built native compiler for ZNC.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
solver=${Z3:-z3}
command -v "$solver" >/dev/null || { echo 'z3 is required for QF_BV proof' >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zopt-signed-divmod.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
if ! "$solver" -T:60 -smt2 tests/zopt_signed_divmod_qfbv.smt2 \
     >"$tmp/proof" 2>"$tmp/solver-stderr"; then
    cat "$tmp/solver-stderr" "$tmp/proof" >&2
    echo 'Z3 QF_BV proof failed' >&2
    exit 1
fi
# Require the full ordered answer sequence, with no unknown, timeout,
# solver diagnostics, additional output, or missing checks.
printf 'unsat\nunsat\nunsat\nunsat\nunsat\nunsat\nunsat\nsat\n' >"$tmp/expected"
if [ -s "$tmp/solver-stderr" ] || ! cmp -s "$tmp/expected" "$tmp/proof"; then
    cat "$tmp/solver-stderr" "$tmp/proof" >&2
    echo 'unexpected Z3 proof result' >&2
    exit 1
fi
"$compiler" selfhost/native/zopt_signed_divmod_test.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/test"
echo 'zopt-signed-divmod QF_BV: unsat=7 sat-overflow-witness=1'
