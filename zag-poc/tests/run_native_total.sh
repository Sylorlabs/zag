#!/usr/bin/env bash
# @total SMT proof suite for the supported ./znc native compiler.
# Requires ghost_engine zag_verify (built via: cd ../../ghost_engine && zig build zag-verify)
# or z3 on PATH. Tests run from zag-poc root so prove_smt.sh resolves correctly.
set -eu
cd "$(dirname "$0")/.."

pass=0
fail=0

prover=""
if [ -x ../../ghost_engine/zig-out/bin/zag_verify ]; then
  prover=../../ghost_engine/zig-out/bin/zag_verify
elif command -v zag_verify >/dev/null 2>&1; then
  prover=zag_verify
elif command -v z3 >/dev/null 2>&1; then
  prover=z3
fi

if [ -n "$prover" ]; then
  echo "── @total proofs (prover: $prover) ──"
else
  echo "── @total proofs (no external prover — conservative + algebraic paths only) ──"
fi

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

# total_guarded: path-sensitive discharge; with prover also prints ✓ proven via SMT
tc "total_guarded compiles" 0 ./znc check examples/total_guarded.zag
tc "total_guarded build" 0 ./znc examples/total_guarded.zag -o /tmp/total_guarded
if [ -n "$prover" ]; then
  if ./znc examples/total_guarded.zag -o /tmp/total_guarded >/tmp/total_proven_out 2>&1 && \
     grep -q '✓ proven' /tmp/total_proven_out; then
    echo "  ok  total_guarded prints ✓ proven with prover"
    pass=$((pass + 1))
  else
    echo "  XX  total_guarded missing ✓ proven with prover"
    sed -n '1,12p' /tmp/total_proven_out
    fail=$((fail + 1))
  fi
fi

# total_nonzero: algebraic n*n+1 discharge OR SMT; must compile with or without prover
tc "total_nonzero compiles" 0 ./znc check examples/total_nonzero.zag
ZAG_NO_PROVER=1 GHOST_ENGINE=/nonexistent tc "total_nonzero without prover" 0 ./znc check examples/total_nonzero.zag

# total_bad: must reject; with prover, emit a concrete counterexample
if [ -n "$prover" ]; then
  if ./znc check examples/total_bad.zag >/tmp/total_bad_out 2>&1; then
    echo "  XX  total_bad rejected (expected failure)"
    fail=$((fail + 1))
  else
    if grep -q 'counterexample' /tmp/total_bad_out; then
      echo "  ok  total_bad rejected with counterexample"
      pass=$((pass + 1))
    else
      echo "  XX  total_bad rejected but no counterexample from prover"
      sed -n '1,12p' /tmp/total_bad_out
      fail=$((fail + 1))
    fi
  fi
else
  if ./znc check examples/total_bad.zag >/tmp/total_bad_out 2>&1; then
    echo "  XX  total_bad rejected (expected failure)"
    fail=$((fail + 1))
  else
    echo "  ok  total_bad rejected (no prover)"
    pass=$((pass + 1))
  fi
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