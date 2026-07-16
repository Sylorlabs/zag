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

if [ -f docs/V2_SAFETY_TOOLING.md ] && \
   rg -q 'rejects the proposed v2' docs/V2_SAFETY_TOOLING.md && \
   rg -q 'Current status remains unsupported' docs/V2_SAFETY_TOOLING.md; then
  ok "safety-tooling document is explicit about unsupported status"
else
  bad "safety-tooling document is missing or overclaims implementation"
fi

if [ -f docs/V2_SUPPORT_MATRIX.generated.md ] && \
   rg -q 'REQUIRED FAILURE: UNSUPPORTED' docs/V2_SUPPORT_MATRIX.generated.md; then
  ok "generated support matrix retains required unsupported failures"
else
  bad "generated support matrix is missing or masks unsupported requirements"
fi

if [ -f docs/V2_MIGRATION.md ] && \
   rg -q 'v1 is frozen' docs/V2_MIGRATION.md && \
   rg -q 'intentionally blocked by E0201' docs/V2_MIGRATION.md; then
  ok "migration guide preserves frozen-v1 and fail-closed boundary"
else
  bad "migration guide is missing or permits an unsupported v2 migration"
fi

if [ -f docs/V2_FFI_GUIDE.md ] && [ -f docs/V2_CONCURRENCY_GUIDE.md ] && \
   [ -f docs/V2_ALLOCATOR_GUIDE.md ] && \
   rg -q 'not implemented' docs/V2_FFI_GUIDE.md && \
   rg -q 'not implemented' docs/V2_CONCURRENCY_GUIDE.md && \
   rg -q 'not implemented' docs/V2_ALLOCATOR_GUIDE.md; then
  ok "low-level guides exist without claiming unimplemented APIs"
else
  bad "low-level guides are missing or overclaim implementation"
fi

if [ -f docs/V2_GPU_GUIDE.md ] && [ -f docs/V2_CPU_CONTROL_GUIDE.md ] && \
   rg -q 'does not currently execute a GPU kernel' docs/V2_GPU_GUIDE.md && \
   rg -q 'not implemented in v2' docs/V2_CPU_CONTROL_GUIDE.md; then
  ok "GPU and CPU-control guides distinguish plans from implementation"
else
  bad "GPU or CPU-control guide is missing or overclaims support"
fi

if [ -f docs/V2_TARGET_SUPPORT.md ] && \
   rg -q 'not a GPU execution backend' docs/V2_TARGET_SUPPORT.md && \
   rg -q '| Vulkan compute | no runtime implementation | unsupported |' docs/V2_TARGET_SUPPORT.md; then
  ok "target support matrix marks GPU runtime targets unsupported"
else
  bad "target support matrix is missing or overclaims GPU runtime support"
fi

echo "════ docs-consistency pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
