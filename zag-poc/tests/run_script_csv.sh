#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
test_tmp_root=${ZAG_TEST_TMPDIR:-/tmp}
mkdir -p "$test_tmp_root"
tmp_dir=$(mktemp -d "${test_tmp_root%/}/zag-script-csv.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

znc_bin=${ZNC:-./znc}
tmp_bin="$tmp_dir/script-csv"

"$znc_bin" tests/script_csv.zag -o "$tmp_bin" --no-zagd --no-analyze > /dev/null
"$tmp_bin"
echo "script CSV: PASS"
