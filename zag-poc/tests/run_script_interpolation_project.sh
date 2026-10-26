#!/usr/bin/env bash
# Keep parser/runtime and full Script driver integration together in the
# frozen first-release matrix's single interpolation integration stage.
set -euo pipefail
cd "$(dirname "$0")/.."
bash tests/run_script_interpolation_parser.sh
bash tests/run_script_interpolation.sh
echo 'typed interpolation projection integration: PASS'
