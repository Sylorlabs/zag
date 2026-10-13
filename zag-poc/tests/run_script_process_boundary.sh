#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-process-boundary.XXXXXX)
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$tmp_dir"; else echo "process boundary artifacts retained: $tmp_dir" >&2; fi' EXIT

compile_fixture() {
    local name=$1
    echo "process boundary: compile $name"
    "$znc_bin" "$tmp_dir/$name.zag" -o "$tmp_dir/$name" \
        --no-analyze --no-zagd --no-foreground-cache >"$tmp_dir/$name.compile.out" 2>"$tmp_dir/$name.compile.err" || {
        local rc=$?
        echo "process boundary: compiler failed for $name (exit=$rc; see $tmp_dir/$name.compile.err)" >&2
        return "$rc"
    }
}

run_fixture() {
    local name=$1
    echo "process boundary: run $name (fd limit=64)"
    (ulimit -n 64; "$tmp_dir/$name") >"$tmp_dir/$name.out" 2>"$tmp_dir/$name.err" || {
        local rc=$?
        echo "process boundary: executable failed for $name (exit=$rc; see $tmp_dir/$name.err)" >&2
        return "$rc"
    }
}

"$znc_bin" tests/process_timeout_blocker.zag -o "$tmp_dir/blocker" --no-analyze --no-zagd >/dev/null
"$tmp_dir/blocker"

long_command=$(printf '%02048d' 0 | tr '0' 'x')
cat >"$tmp_dir/command_allocation_failure_fds.zag" <<ZAG
script;
let fill = script_alloc(1046733);
if (script_alloc_used() != 1046733) { return 10; }
let i:i32 = 0;
while (i < 36) {
    let result = process_run_timeout("$long_command", 100, 16);
    if (process_result_state(result) != process_state_runtime_error() ||
        process_result_status(result) != -1 || process_result_output(result).len != 0) { return 11; }
    i = i + 1;
    if (script_alloc_used() != 1046733 + (i as i64) * 48) { return 12; }
}
let final_result = process_run_timeout("printf ok", 1000, 16);
if (process_result_state(final_result) != process_state_exited()) { return 2; }
if (!@strEq(process_result_output(final_result), "ok")) { return 4; }
if (script_alloc_used() != 1048576) { return 13; }
return 0;
ZAG
# Leave 1843 bytes: 36 * (pair 8 + argv 32 + envp 8) + 115.
# The 2049-byte command copy always fails after pipe and before fork.
# The final 115 bytes are exactly enough for one successful
# bounded process result, proving the earlier failures did not exhaust fds.
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/.zagd.conf"
compile_fixture command_allocation_failure_fds
run_fixture command_allocation_failure_fds

cat >"$tmp_dir/capture_allocation_failure_fds.zag" <<'ZAG'
script;
let fill = script_alloc(1044691);
if (script_alloc_used() != 1044691) { return 10; }
let i:i32 = 0;
while (i < 65) {
    let result = process_run_timeout(":", 100, 5000);
    if (process_result_state(result) != process_state_runtime_error() ||
        process_result_status(result) != -1 || process_result_output(result).len != 0) { return 11; }
    i = i + 1;
    if (script_alloc_used() != 1044691 + (i as i64) * 58) { return 12; }
}
let final_result = process_run_timeout("printf ok", 1000, 16);
if (process_result_state(final_result) != process_state_exited()) { return 2; }
if (!@strEq(process_result_output(final_result), "ok")) { return 4; }
if (script_alloc_used() != 1048576) { return 13; }
return 0;
ZAG
# Leave 3885 bytes: 65 * (pair 8 + command 2 + argv 32 + envp 8 + status 8) + 115.
# The 5001-byte capture reservation always fails after fork; the final 115 bytes
# prove that every earlier read fd
# was closed before the early return.
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/.zagd.conf"
compile_fixture capture_allocation_failure_fds
run_fixture capture_allocation_failure_fds

# Even with no budget left for setup or a result header, the public getters
# must report a runtime error rather than dereference a null handle.
cat >"$tmp_dir/exhausted_process.zag" <<'ZAG'
script;
let fill = script_alloc(1048576);
let result = process_run_timeout("printf must-not-run", 1000, 16);
if (process_result_state(result) != process_state_runtime_error() ||
    process_result_status(result) != -1 || process_result_output(result).len != 0) { return 1; }
if (script_alloc_used() != 1048576) { return 2; }
return 0;
ZAG
compile_fixture exhausted_process
run_fixture exhausted_process

# Let command execution succeed but leave only 31 bytes for the 32-byte result
# header. This exercises the backend constructor's allocation-failure path.
cat >"$tmp_dir/exhausted_result_header.zag" <<'ZAG'
script;
let fill = script_alloc(1048470);
let result = process_run_timeout(":", 1000, 16);
if (process_result_state(result) != process_state_runtime_error() ||
    process_result_status(result) != -1 || process_result_output(result).len != 0) { return 1; }
if (script_alloc_used() != 1048545) { return 2; }
return 0;
ZAG
compile_fixture exhausted_result_header
run_fixture exhausted_result_header

echo "script process boundary: PASS"
