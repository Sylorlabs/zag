#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
test_tmp_root=${ZAG_TEST_TMPDIR:-/tmp}
mkdir -p "$test_tmp_root"
tmp_dir=$(mktemp -d "${test_tmp_root%/}/zag-script-json.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_json.zag -o "$tmp_dir/json-test" --no-analyze --no-zagd >/dev/null
"$tmp_dir/json-test"
"$(dirname "$0")/run_script_json_bool_array.sh"
"$(dirname "$0")/run_script_json_float_array.sh"
echo "script JSON: PASS"
