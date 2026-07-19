#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-runtime.XXXXXX)
trap 'rm -rf "$tmp_dir" /tmp/zag_script_top_return /tmp/zag_script_uncaught /tmp/zag_script_alloc_limit /tmp/zag_script_explicit_alloc /tmp/zag_script_custom_limit' EXIT

"$znc_bin" selfhost/native/script_lowering_native_test.zag \
    -o "$tmp_dir/generator" --no-analyze >/dev/null
"$tmp_dir/generator"

"$znc_bin" selfhost/script_parser_probe.zag \
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
/tmp/zag_script_custom_limit
custom_limit_status=$?
set -e

test "$return_status" -eq 23
test "$error_status" -eq 1
test "$alloc_status" -eq 0
test "$explicit_status" -eq 19
test "$custom_limit_status" -eq 0
grep -q 'uncaught Zag Script error code 1' "$tmp_dir/uncaught.err"
grep -q 'uncaught Zag Script error name: Failure' "$tmp_dir/uncaught.err"
grep -q 'operation: root script top-level try call `fail`' "$tmp_dir/uncaught.err"

"$znc_bin" tests/script_frontend/uncaught_error.zag -o "$tmp_dir/direct-uncaught" --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/direct-uncaught" 2>"$tmp_dir/direct-uncaught.err"
direct_error_status=$?
set -e
test "$direct_error_status" -eq 1
grep -q 'uncaught Zag Script error name: ScriptFailure' "$tmp_dir/direct-uncaught.err"
grep -q 'source: tests/script_frontend/uncaught_error.zag' "$tmp_dir/direct-uncaught.err"
grep -q 'operation: root script top-level try call `fail`' "$tmp_dir/direct-uncaught.err"

"$znc_bin" tests/script_frontend/prelude.zag -o "$tmp_dir/prelude" --no-analyze --no-zagd >/dev/null
test "$("$tmp_dir/prelude")" = 'prelude:file-data'
"$znc_bin" tests/script_frontend/prelude_override.zag -o "$tmp_dir/prelude-override" --no-analyze --no-zagd >/dev/null
test "$("$tmp_dir/prelude-override")" = 'override:yes'
"$znc_bin" tests/script_frontend/args_strings.zag -o "$tmp_dir/args-strings" --no-analyze --no-zagd >/dev/null
test "$("$tmp_dir/args-strings" value)" = 'arg:value'
echo "script runtime integration: PASS"
