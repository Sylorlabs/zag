#!/usr/bin/env bash
# Keep parser/runtime and full Script driver integration together in the
# frozen first-release matrix's single interpolation integration stage.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
export ZNC=${ZNC:-$(zag_native_compiler .)}
bash tests/run_script_interpolation_parser.sh
bash tests/run_script_interpolation.sh
bash tests/run_script_projection.sh
echo 'typed interpolation projection integration: PASS'
