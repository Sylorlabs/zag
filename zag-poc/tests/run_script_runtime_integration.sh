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
"$znc_bin" tests/script_frontend/println_int.zag -o "$tmp_dir/println-int" --no-analyze --no-zagd >/dev/null
test "$("$tmp_dir/println-int")" = '42'

cat >"$tmp_dir/file_path_runtime.zag" <<ZAG
script;
let path: []u8 = "$tmp_dir/runtime_file.txt";
let value: []u8 = "runtime";
if (write_file(path, value) != 0) { return 70; }
let data: []u8 = read_file(path);
if (!@strEq(data, value)) { return 71; }
if (!@strEq(path_join("tmp", "report.json"), "tmp/report.json")) { return 72; }
if (!@strEq(path_basename("/tmp/report.json"), "report.json")) { return 73; }
if (!@strEq(path_dirname("/tmp/report.json"), "/tmp")) { return 74; }
if (!@strEq(path_extension("/tmp/report.json"), ".json")) { return 75; }
return 0;
ZAG
"$znc_bin" "$tmp_dir/file_path_runtime.zag" -o "$tmp_dir/file-path-runtime" --no-analyze >/dev/null
if "$tmp_dir/file-path-runtime"; then :; else exit 1; fi

cat >"$tmp_dir/env_runtime.zag" <<'ZAG'
script;
if (!@strEq(env("ZAG_RUNTIME_SCRIPT_ENV"), "visible")) { return 80; }
let missing: []u8 = env("ZAG_RUNTIME_SCRIPT_MISSING");
if (missing.len != 0) { return 81; }
return 0;
ZAG
printf '%s\n' 'allow_filesystem_read=true' 'allow_filesystem_write=true' 'allow_process=false' 'environment_allow=ZAG_RUNTIME_SCRIPT_ENV,ZAG_RUNTIME_SCRIPT_MISSING' 'mode=off' >"$tmp_dir/.zagd.conf"
"$znc_bin" "$tmp_dir/env_runtime.zag" -o "$tmp_dir/env-runtime" --no-analyze --no-zagd >/dev/null
ZAG_RUNTIME_SCRIPT_ENV=visible "$tmp_dir/env-runtime"
printf '%s\n' 'allow_filesystem_read=true' 'allow_filesystem_write=true' 'allow_process=false' 'environment_allow=' 'mode=off' >"$tmp_dir/.zagd.conf"
if "$znc_bin" "$tmp_dir/env_runtime.zag" -o "$tmp_dir/env-runtime-denied" --no-analyze --no-zagd >"$tmp_dir/env-runtime-denied.out" 2>&1; then
    echo "environment allowlist unexpectedly accepted env() usage" >&2
    exit 1
fi
grep -q 'env("ZAG_RUNTIME_SCRIPT_ENV") denied' "$tmp_dir/env-runtime-denied.out"

cat >"$tmp_dir/process_runtime.zag" <<'ZAG'
script;
let fast = process_run_timeout("printf rt-ok", 1000, 16);
if (process_result_state(fast) != process_state_exited()) { return 90; }
if (!@strEq(process_result_output(fast), "rt-ok")) { return 91; }
let timed = process_run_timeout("sleep 2", 25, 16);
if (process_result_state(timed) != process_state_timed_out()) { return 92; }
let bounded = process_run_timeout("printf 123456789", 1000, 4);
if (process_result_state(bounded) != process_state_output_limit()) { return 93; }
return 0;
ZAG
printf '%s\n' 'allow_filesystem_read=true' 'allow_filesystem_write=true' 'allow_process=true' 'environment_allow=' 'mode=off' >"$tmp_dir/.zagd.conf"
"$znc_bin" "$tmp_dir/process_runtime.zag" -o "$tmp_dir/process-runtime" --no-analyze --no-zagd >/dev/null
if "$tmp_dir/process-runtime"; then :; else exit 1; fi

cat >"$tmp_dir/process_argv_runtime.zag" <<'ZAG'
script;
let argv = args();
if (argv.len != 1) { return 94; }
let value: []u8 = argv.data[0];
// args() is already a context-owned ScriptList[[]u8]. The runner supplies a
// controlled argv[0] for each case, so this exercises the descriptor ABI
// without relying on unsupported generic string-list literal inference.
if (@strEq(value, "literal;$(printf injected) `quoted`")) {
    let direct = process_run_argv("/usr/bin/printf", argv, 1000, 1024);
    if (process_result_state(direct) != process_state_exited()) { return 95; }
    if (!@strEq(process_result_output(direct), value)) { return 96; }
    return 0;
}
if (@strEq(value, "2")) {
    let timed = process_run_argv("/bin/sleep", argv, 25, 1024);
    if (process_result_state(timed) != process_state_timed_out()) { return 97; }
    return 0;
}
if (@strEq(value, "x")) {
    let capped = process_run_argv("/usr/bin/yes", argv, 1000, 4);
    if (process_result_state(capped) != process_state_output_limit()) { return 98; }
    return 0;
}
if (@strEq(value, "missing")) {
    let missing = process_run_argv("/definitely/missing/zag-script-process", argv, 1000, 1024);
    if (process_result_state(missing) != process_state_exited() ||
        process_result_status(missing) != 127) { return 99; }
    return 0;
}
if (@strEq(value, "invalid")) {
    let invalid = process_run_argv("", argv, 1000, 1024);
    if (process_result_state(invalid) != process_state_runtime_error()) { return 100; }
    return 0;
}
return 101;
ZAG
"$znc_bin" "$tmp_dir/process_argv_runtime.zag" -o "$tmp_dir/process-argv-runtime" --no-analyze --no-zagd >/dev/null
bash -c 'exec -a "$1" "$2"' zag-script 'literal;$(printf injected) `quoted`' "$tmp_dir/process-argv-runtime"
bash -c 'exec -a "$1" "$2"' zag-script 2 "$tmp_dir/process-argv-runtime"
bash -c 'exec -a "$1" "$2"' zag-script x "$tmp_dir/process-argv-runtime"
bash -c 'exec -a "$1" "$2"' zag-script missing "$tmp_dir/process-argv-runtime"
bash -c 'exec -a "$1" "$2"' zag-script invalid "$tmp_dir/process-argv-runtime"

echo "script runtime integration: PASS"
