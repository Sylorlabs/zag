#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-json.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_json.zag -o "$tmp_dir/json-test" --no-analyze --no-zagd >/dev/null
"$tmp_dir/json-test"
echo "script JSON: PASS"
