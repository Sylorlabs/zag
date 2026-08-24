#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
cd "$root_dir"
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-json-csv-profile.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$script_dir/run_script_json.sh"
"$script_dir/run_script_csv.sh"

"$znc_bin" tests/script_json_csv_profile.zag \
    -o "$tmp_dir/profile" --no-zagd --no-analyze >/dev/null
"$tmp_dir/profile"

echo "script JSON and CSV (including script profile): PASS"
