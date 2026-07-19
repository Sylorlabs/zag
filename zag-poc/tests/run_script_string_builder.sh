#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-builder.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_frontend/string_builder.zag -o "$tmp_dir/script" --no-analyze --no-zagd >/dev/null
"$tmp_dir/script"
"$znc_bin" tests/script_frontend/string_builder_limit.zag -o "$tmp_dir/limit" --no-analyze --no-zagd >/dev/null
"$tmp_dir/limit"
"$znc_bin" tests/string_builder_strict.zag -o "$tmp_dir/strict" --no-analyze --no-zagd >/dev/null
"$tmp_dir/strict"
echo "script string builder: PASS"
