#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for suite in tests/run_script_cli.sh tests/run_script_interpolation.sh tests/run_script_map_explicit.sh tests/run_script_records.sh tests/run_script_python_shape.sh tests/run_zagscript_views.sh; do bash "$suite"; done
echo 'ZagScript explicit strict-Zag authority: PASS'
