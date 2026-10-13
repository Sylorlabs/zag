#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for suite in tests/run_collections_unicode.sh tests/run_script_map.sh tests/run_script_map_literals.sh tests/run_script_interpolation.sh tests/run_script_allocation_accounting.sh; do bash "$suite"; done
echo 'ZagScript collections/Unicode authority: PASS'
