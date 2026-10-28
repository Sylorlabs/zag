#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
solver=${Z3:-z3}
command -v "$solver" >/dev/null 2>&1 || { echo 'z3 required for power-of-two remainder proof' >&2; exit 2; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
"$solver" -T:60 -smt2 tests/pow2_remainder_qfbv.smt2 >"$tmp"
expected=$(printf 'unsat\n%.0s' {1..7}; printf 'sat\n')
if [ "$(cat "$tmp")" != "$expected" ]; then
  echo 'pow2 unsigned remainder proof failed' >&2
  cat "$tmp" >&2
  exit 1
fi
echo 'pow2 unsigned remainder QF_BV: PASS (7 unsat identities, 1 signed counterexample)'
