#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-process-result-abi.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" selfhost/native/process_result_abi_native_test.zag -o "$tmp_dir/generator" --no-analyze --no-zagd >/dev/null
"$tmp_dir/generator"
/tmp/zag_process_result_abi
rm -f /tmp/zag_process_result_abi
echo "process result ABI: PASS"
