#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir=$(mktemp -d /tmp/zag-script-runtime.XXXXXX)
trap 'rm -rf "$tmp_dir" /tmp/zag_script_top_return /tmp/zag_script_uncaught /tmp/zag_script_alloc_limit /tmp/zag_script_explicit_alloc' EXIT

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
/tmp/zag_script_uncaught 2>"$tmp_dir/uncaught.err"
error_status=$?
/tmp/zag_script_alloc_limit
alloc_status=$?
/tmp/zag_script_explicit_alloc
explicit_status=$?
set -e

test "$return_status" -eq 23
test "$error_status" -eq 1
test "$alloc_status" -eq 0
test "$explicit_status" -eq 19
grep -q 'uncaught Zag Script error code 1' "$tmp_dir/uncaught.err"
grep -q 'root script top-level execution' "$tmp_dir/uncaught.err"
echo "script runtime integration: PASS"
