#!/usr/bin/env bash
# Phase 3 — the @total div-by-zero proof, discharged by ghost_engine zag_verify.
#
# The Zag compiler emits an SMT-LIB2 verification condition per division and hands it to
# ghost_engine's Z3 bridge (ghost_engine/src/zag_verify.zig, built via `zig build zag-verify`).
#
# Build the bridge once:
#   cd ../../ghost_engine && zig build zag-verify
cd "$(dirname "$0")"

if [ -x ../../ghost_engine/zig-out/bin/zag_verify ]; then
    echo "prover detected: ghost_engine (../../ghost_engine/zig-out/bin/zag_verify)"
elif [ -n "${GHOST_ENGINE:-}" ] && [ -x "${GHOST_ENGINE}" ]; then
    echo "prover detected: ghost_engine (${GHOST_ENGINE})"
elif command -v zag_verify >/dev/null 2>&1; then
    echo "prover detected: ghost_engine (zag_verify in PATH)"
elif command -v z3 >/dev/null 2>&1; then
    echo "prover detected: z3"
else
    echo "prover detected: none (conservative @total checking only)"
fi
echo

echo "════════ WITHOUT a prover (forced) — conservative where SMT needed ════════"
echo "total_guarded still passes (path-sensitive); total_bad still rejected:"
ZAG_NO_PROVER=1 GHOST_ENGINE=/nonexistent ./znc check examples/total_guarded.zag 2>&1 | grep -E 'OK|VIOLATED|note:' || true
ZAG_NO_PROVER=1 GHOST_ENGINE=/nonexistent ./znc check examples/total_bad.zag 2>&1 | grep -E 'VIOLATED|note:|counterexample' || true

echo
echo "════════ WITH ghost_engine — proven via ./znc ════════"
for f in total_guarded total_nonzero; do
  echo "── $f ──"
  ./znc examples/$f.zag -o /tmp/prove_$f 2>&1 | grep -E '✓ proven|znc: wrote'
  /tmp/prove_$f; echo "-- exit $?"
done
echo "── total_bad: ghost_engine returns a concrete counterexample ──"
./znc check examples/total_bad.zag 2>&1 | grep -E 'counterexample|VIOLATED|note:'