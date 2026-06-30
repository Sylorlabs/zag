#!/usr/bin/env bash
# Phase 3 — the @total div-by-zero proof, discharged by the ACTUAL ghost_engine.
#
# The Zag compiler emits an SMT-LIB2 verification condition per division and hands it to
# ghost_engine's Z3 bridge (ghost_engine/src/zag_verify.zig, built via `zig build zag-verify`,
# using the same Z3_eval_smtlib2_string path the engine's verified_swap.zig uses).
#
# Build the bridge once:
#   cd ../../ghost_engine && zig build zag-verify
cd "$(dirname "$0")"

if [ -n "${GHOST_ENGINE:-}" ] && [ -x "${GHOST_ENGINE}" ]; then
    echo "prover detected: ghost_engine (${GHOST_ENGINE})"
elif command -v zag_verify >/dev/null 2>&1; then
    echo "prover detected: ghost_engine (zag_verify in PATH)"
else
    echo "prover detected: none (conservative @total checking; legacy ./zagc differential path)"
fi
echo

echo "════════ WITHOUT a prover (forced) — conservative ════════"
echo "Same source, but no prover reachable -> the variable divisor must be rejected:"
GHOST_ENGINE=/nonexistent zagc check examples/total_guarded.zag 2>&1 | grep -E 'VIOLATED|note:'

echo
echo "════════ WITH ghost_engine — proven ════════"
for f in total_guarded total_nonzero; do
  echo "── $f ──"
  zagc build examples/$f.zag --run 2>&1 | grep -E '✓ proven|🔒|-- running|-- exit'
done
echo "── total_bad: ghost_engine returns a concrete counterexample ──"
zagc check examples/total_bad.zag 2>&1 | grep -E 'counterexample'
