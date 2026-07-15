#!/usr/bin/env bash
# Documentation guardrails supplement executable tests; they never count as
# GPU/runtime evidence.  They prevent known false support claims from returning
# while the implementation matrix remains fail-closed.
set -eu
cd "$(dirname "$0")/.."
pass=0 fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

if [ -f docs/V2_FINAL_VERIFICATION.md ] && \
   rg -q 'Do not release Zag v2' docs/V2_FINAL_VERIFICATION.md; then
  ok "v2 verification matrix is present and fail-closed"
else
  bad "v2 verification matrix is missing or release-positive"
fi

if rg -q 'GPU MLIR output is not a GPU executable or dispatch runtime' README.md && \
   rg -q 'GPU MLIR is not physical GPU execution' README.md; then
  ok "public compiler documentation labels GPU output as frontend-only"
else
  bad "public compiler documentation lacks GPU frontend-only boundary"
fi

if ! rg -q 'real launch_func' tests/run_native_gpu.sh && \
   rg -q 'frontend structure only; no runtime launch' tests/run_native_gpu.sh; then
  ok "GPU frontend test does not claim a runtime launch"
else
  bad "GPU frontend test label overclaims execution"
fi

if rg -q 'No physical GPU execution was performed or implemented' docs/V2_AUDIT.md && \
   rg -q 'GPU target binary and physical dispatch.*UNSUPPORTED' docs/V2_FINAL_VERIFICATION.md; then
  ok "audit and verification matrix agree on physical GPU status"
else
  bad "GPU status disagrees between audit and verification matrix"
fi

echo "════ docs-consistency pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
