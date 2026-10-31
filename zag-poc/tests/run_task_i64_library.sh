#!/usr/bin/env bash
# Typed façade over the bounded compiler-owned TaskI64 ABI.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-task-i64-library.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

grep -Fq 'struct TaskI64JoinResult' std/task_i64.zag
grep -Fq 'fn task_i64_await_into' std/task_i64.zag
grep -Fq 'task_i64_poll_status_invalid_output' std/task_i64.zag
grep -Fq 'task_i64_await_into' tests/task_i64_library.zag

printf 'name = "task-i64-library"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
cp tests/task_i64_library.zag "$tmp/main.zag"
(cd "$tmp" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze \
    --no-foreground-cache -o app >build.log 2>&1)
test -x "$tmp/app"
file "$tmp/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
(cd "$tmp" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze \
    --no-foreground-cache -o app-second >build-second.log 2>&1)
test -x "$tmp/app-second"
cmp -s "$tmp/app" "$tmp/app-second"
set +e
timeout 8 "$tmp/app" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
test "$rc" -eq 42
test ! -s "$tmp/err"
test ! -s "$tmp/out" || test "$(cat "$tmp/out")" = ''

cat >"$tmp/double_await.zag" <<'ZAG'
@import("std:task_i64") as task
fn worker(raw:i64) i64 { unsafe { return @taskInput(raw as *opaque); } }
fn main() i32 {
    unsafe {
        let handle:*opaque = @taskSpawn(worker, 1);
        let first:i64 = @taskAwait(handle);
        let second:i64 = @taskAwait(handle);
        return (first + second) as i32;
    }
}
ZAG
if "$ZNC" "$tmp/double_await.zag" --safety=checked --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/double-await" \
    >"$tmp/double-await.log" 2>&1; then
    echo 'double TaskI64 await unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/double-await"
grep -Eq 'already released|use after|owned allocation.*released|neither released' \
    "$tmp/double-await.log"

cat >"$tmp/bad-ready.zag" <<'ZAG'
fn main() i32 {
    unsafe { let value:i32 = @taskReady(1); return value; }
}
ZAG
if "$ZNC" "$tmp/bad-ready.zag" --safety=checked --no-zagd \
    --no-analyze --no-foreground-cache -o "$tmp/bad-ready" \
    >"$tmp/bad-ready.log" 2>&1; then
    echo 'invalid TaskI64 ready handle unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-ready"
grep -Eq 'task handle operation requires a \*opaque handle|task handle operation expects' \
    "$tmp/bad-ready.log"

echo 'task i64 library: typed borrow/cancel façade, cascaded cancellation, typed consuming completion result, and direct await pass'
