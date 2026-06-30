#!/usr/bin/env bash
# Dispatch SMT-LIB2 to ghost_engine zag_verify, z3, or conservative unknown.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMT="${1:?usage: prove_smt.sh <file.smt2>}"
OUT="${SMT%.smt2}.out"
RC="${SMT%.smt2}.rc"
if [ -n "${ZAG_NO_PROVER:-}" ] || [ "${GHOST_ENGINE:-}" = /nonexistent ]; then
  echo 2 >"$RC"
  exit 0
fi
P=""
if [ -n "${GHOST_ENGINE:-}" ] && [ -x "${GHOST_ENGINE}" ]; then
  P="${GHOST_ENGINE}"
fi
if [ -z "$P" ]; then
  for candidate in \
    "$SCRIPT_DIR/../../ghost_engine/zig-out/bin/zag_verify" \
    "$SCRIPT_DIR/../ghost_engine/zig-out/bin/zag_verify"; do
    if [ -x "$candidate" ]; then P="$candidate"; break; fi
  done
fi
if [ -z "$P" ] && command -v zag_verify >/dev/null 2>&1; then
  P=zag_verify
fi
if [ -z "$P" ] && command -v z3 >/dev/null 2>&1; then
  P="z3 -smt2"
fi
if [ -z "$P" ]; then
  echo 2 >"$RC"
  exit 0
fi
set +e
# shellcheck disable=SC2086
$P "$SMT" >"$OUT" 2>&1
ec=$?
set -e
if [ "$P" = "z3 -smt2" ]; then
  if grep -q unsat "$OUT"; then ec=0
  elif grep -q sat "$OUT"; then ec=1
  else ec=2
  fi
fi
echo "$ec" >"$RC"