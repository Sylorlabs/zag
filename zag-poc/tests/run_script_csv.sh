#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir=$(mktemp -d /tmp/zag-script-csv.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

znc_bin=${ZNC:-./znc}
tmp_bin="$tmp_dir/script-csv"

"$znc_bin" tests/script_csv.zag -o "$tmp_bin" --no-zagd --no-analyze > /dev/null
"$tmp_bin"
echo "script CSV: PASS"
