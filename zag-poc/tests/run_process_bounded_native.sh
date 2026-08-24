#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-process-bounded.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/process_bounded_native.zag -o "$tmp_dir/process" --no-analyze --no-zagd >/dev/null
"$tmp_dir/process"
"$znc_bin" tests/script_frontend/process_bounded.zag -o "$tmp_dir/script-process" --no-analyze --no-zagd >/dev/null
"$tmp_dir/script-process"
echo "bounded process native: PASS"
