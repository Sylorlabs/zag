#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir=$(mktemp -d /tmp/zag-script-runtime.XXXXXX)
trap 'rm -rf "$tmp_dir" /tmp/zag_script_top_return /tmp/zag_script_uncaught' EXIT

./znc selfhost/native/script_lowering_native_test.zag \
    -o "$tmp_dir/generator" --no-analyze >/dev/null
"$tmp_dir/generator"

./znc selfhost/script_parser_probe.zag \
    -o "$tmp_dir/parser-probe" --no-analyze >/dev/null
if "$tmp_dir/parser-probe" tests/script_frontend/reserved_symbol.zag \
    >"$tmp_dir/reserved.out" 2>&1; then
    echo "compiler-owned script symbol unexpectedly accepted" >&2
    exit 1
fi
grep -q 'compiler-owned script symbol' "$tmp_dir/reserved.out"

set +e
/tmp/zag_script_top_return
return_status=$?
/tmp/zag_script_uncaught
error_status=$?
set -e

test "$return_status" -eq 23
test "$error_status" -eq 1
echo "script runtime integration: PASS"
