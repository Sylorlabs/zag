#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/run_zir_authority_portable.sh
bash tests/run_script_auto.sh
bash tests/run_script_auto_cli.sh
if command -v "${Z3:-z3}" >/dev/null 2>&1; then
    bash tests/run_bv_superopt.sh
    bash tests/run_pow2_remainder_proof.sh
fi
bash tests/run_zagd_benchmark_policy.sh
echo 'ZagScript proof/differential optimizer authority: PASS'
