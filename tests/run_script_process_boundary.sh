#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-process-boundary.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/process_timeout_blocker.zag -o "$tmp_dir/blocker" --no-analyze --no-zagd >/dev/null
"$tmp_dir/blocker"

long_command=$(printf '%02048d' 0 | tr '0' 'x')
cat >"$tmp_dir/command_allocation_failure_fds.zag" <<ZAG
script;
let fill = script_alloc(1047013);
let i:i32 = 0;
while (i < 36) {
    let result = process_run_timeout("$long_command", 100, 16);
    i = i + 1;
}
let final_result = process_run_timeout("printf ok", 1000, 16);
if (process_result_state(final_result) != process_state_exited()) { return 2; }
if (!@strEq(process_result_output(final_result), "ok")) { return 4; }
return 0;
ZAG
# Leave 1563 bytes after a deliberate bounded fill. Each failure charges
# pair+argv (40 bytes); the 2049-byte command copy always fails after pipe2 and
# before fork. The final 123 bytes are exactly enough for one successful
# bounded process result, proving the earlier failures did not exhaust fds.
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/.zagd.conf"
"$znc_bin" "$tmp_dir/command_allocation_failure_fds.zag" \
    -o "$tmp_dir/command_allocation_failure_fds" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
(ulimit -n 64; "$tmp_dir/command_allocation_failure_fds") \
    >"$tmp_dir/command_allocation_failure_fds.out" \
    2>"$tmp_dir/command_allocation_failure_fds.err"

cat >"$tmp_dir/capture_allocation_failure_fds.zag" <<'ZAG'
script;
let fill = script_alloc(1044163);
let i:i32 = 0;
while (i < 65) {
    let result = process_run_timeout(":", 100, 5000);
    i = i + 1;
}
let final_result = process_run_timeout("printf ok", 1000, 16);
if (process_result_state(final_result) != process_state_exited()) { return 2; }
if (!@strEq(process_result_output(final_result), "ok")) { return 4; }
return 0;
ZAG
# Leave 4413 bytes after a deliberate bounded fill. Each failure charges
# pair+command+argv+status+sleep (66 bytes). The 5001-byte capture reservation
# always fails after fork; the final 123 bytes prove that every earlier read fd
# was closed before the early return.
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/.zagd.conf"
"$znc_bin" "$tmp_dir/capture_allocation_failure_fds.zag" \
    -o "$tmp_dir/capture_allocation_failure_fds" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
(ulimit -n 64; "$tmp_dir/capture_allocation_failure_fds") \
    >"$tmp_dir/capture_allocation_failure_fds.out" \
    2>"$tmp_dir/capture_allocation_failure_fds.err"

echo "script process boundary: PASS"
