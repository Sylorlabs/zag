#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/run_zir_authority_portable.sh
bash tests/run_script_auto.sh
bash tests/run_script_auto_cli.sh
bash tests/run_zagd_benchmark_policy.sh
echo 'ZagScript proof/differential optimizer authority: PASS'
