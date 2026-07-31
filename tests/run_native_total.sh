#!/usr/bin/env bash
# @total SMT proof suite for the supported ./znc native compiler.
# Uses the solver embedded in znc. No external prover or compiler is permitted.
set -eu
cd "$(dirname "$0")/.."

pass=0
fail=0

echo "── @total proofs (embedded Zag solver) ──"

# tc <name> <expect> <cmd...>
tc() {
  local name=$1 expect=$2
  shift 2
  if "$@" >/tmp/total_out 2>&1; then
    local got=0
  else
    local got=$?
  fi
  if [ "$got" = "$expect" ]; then
    echo "  ok  $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "  XX  $name (got exit $got, want $expect)"
    sed -n '1,12p' /tmp/total_out
    fail=$((fail + 1))
  fi
}

# total_guarded: path-sensitive discharge through the embedded solver
tc "total_guarded compiles" 0 ./znc check examples/total_guarded.zag
tc "total_guarded build" 0 ./znc examples/total_guarded.zag -o /tmp/total_guarded

# total_nonzero: algebraic n*n+1 discharge OR SMT; must compile with or without prover
tc "total_nonzero compiles" 0 ./znc check examples/total_nonzero.zag
ZAG_NO_PROVER=1 GHOST_ENGINE=/nonexistent tc "total_nonzero without prover" 0 ./znc check examples/total_nonzero.zag

# total_bad must be rejected by the embedded solver.
if ./znc check examples/total_bad.zag >/tmp/total_bad_out 2>&1; then
  echo "  XX  total_bad rejected (expected failure)"
  fail=$((fail + 1))
else
  echo "  ok  total_bad rejected"
  pass=$((pass + 1))
fi

# Without prover: guarded example still passes via path-sensitive analysis
ZAG_NO_PROVER=1 GHOST_ENGINE=/nonexistent tc "total_guarded without prover" 0 ./znc check examples/total_guarded.zag

# Without prover: total_bad must still be rejected (conservative, no counterexample required)
if ZAG_NO_PROVER=1 GHOST_ENGINE=/nonexistent ./znc check examples/total_bad.zag >/tmp/total_bad_noprover 2>&1; then
  echo "  XX  total_bad without prover should be rejected"
  fail=$((fail + 1))
else
  echo "  ok  total_bad rejected without prover (conservative)"
  pass=$((pass + 1))
fi

# znc check subcommand exists
if ./znc check examples/total_guarded.zag 2>&1 | grep -q 'OK'; then
  echo "  ok  znc check subcommand"
  pass=$((pass + 1))
else
  echo "  XX  znc check subcommand"
  fail=$((fail + 1))
fi

echo "════ @total pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
