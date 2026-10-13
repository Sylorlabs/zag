#!/usr/bin/env bash
# ZagScript 1.0 bounded async/await authority. The language surface is safe;
# the compiler owns the native thread adapter and the affine task handle.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/portable.sh
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
test -x "$ZNC"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-async.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' 'name = "zagscript-async"' 'version = "0"' 'edition = "2027"' >"$tmp/zag.mod"
target_args=()
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then target_args=(--target macos-arm64 --dynamic); fi
cat >"$tmp/ok.zag" <<'ZAG'
global let async_total:i64;
global let saw_cancel:i64;
global let raw_cancel_seen:i64;
fn one_worker() void { unsafe { let p:*mut i64=(&async_total) as *mut i64; let _old:i64=@atomicFetchAdd64(p,1); } }
fn add_worker(value:i64) void { unsafe { let p:*mut i64=(&async_total) as *mut i64; let _old:i64=@atomicFetchAdd64(p,value); } }
fn cancellable_worker() void {
    let keep0:i64 = 11;
    let keep1:i64 = 22;
    let keep2:i64 = 33;
    let keep3:i64 = 44;
    while (cancelled() == false) { }
    if (keep0 + keep1 + keep2 + keep3 == 110) {
        unsafe { let p:*mut i64=(&saw_cancel) as *mut i64; let _old:i64=@atomicFetchAdd64(p,1); }
    }
}
fn auto_cancel_scope() void {
    let first = async cancellable_worker();
    let second = async cancellable_worker();
    return;
}
fn skipped_async_scope() void {
    if (false) { let skipped = async cancellable_worker(); }
}
fn raw_worker() void {
    if (cancelled()) {
        unsafe { let p:*mut i64=(&raw_cancel_seen) as *mut i64; let _old:i64=@atomicFetchAdd64(p,1); }
    }
}
fn raw_roundtrip() void {
    unsafe {
        let task:*opaque = @threadSpawn(raw_worker);
        @threadJoin(task);
    }
}
script;
if (cancelled()) { return 2; }
let first = async one_worker();
await first;
let second = async add_worker(41);
await second;
auto_cancel_scope();
skipped_async_scope();
raw_roundtrip();
if (async_total == 42 && saw_cancel == 2 && raw_cancel_seen == 0) { return 42; }
return 1;
ZAG
if ! zag_run_bounded 180 "$ZNC" "$tmp/ok.zag" "${target_args[@]}" --safety=checked --no-zagd --no-analyze --no-foreground-cache -o "$tmp/ok" >"$tmp/ok.log" 2>&1; then
  cat "$tmp/ok.log" >&2
  exit 1
fi
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
  file "$tmp/ok" | grep -q 'Mach-O 64-bit executable arm64'
  codesign --verify --strict "$tmp/ok"
  dyld_info -opcodes "$tmp/ok" | grep -q 'SET_SYMBOL_TRAILING_FLAGS_IMM.*_pthread_create'
  dyld_info -opcodes "$tmp/ok" | grep -q 'SET_SYMBOL_TRAILING_FLAGS_IMM.*_pthread_join'
fi
set +e
zag_run_bounded 10 "$tmp/ok"
rc=$?
set -e
test "$rc" -eq 42
reject() {
  name=$1; pattern=$2; shift 2
  printf '%s\n' "$@" >"$tmp/$name.zag"
  if "$ZNC" "$tmp/$name.zag" "${target_args[@]}" --no-zagd --no-analyze --no-foreground-cache -o "$tmp/$name" >"$tmp/$name.log" 2>&1 || [ -e "$tmp/$name" ]; then
    echo "ZagScript async negative case unexpectedly compiled: $name" >&2; exit 1
  fi
  grep -E -q "$pattern" "$tmp/$name.log"
}
reject cancelled_arg 'cancelled expects no arguments|@asyncCancelled expects no arguments' 'script;' 'let bad = cancelled(1);' 'return 0;'
reject copy_task 'cannot escape or be copied' 'fn worker() void {}' 'script;' 'let task = async worker();' 'let copy = task;' 'return 0;'
reject return_task 'cannot escape or be copied' 'fn worker() void {}' 'fn leak() *opaque { let task = async worker(); return task; }' 'script;' 'let leaked = leak();' 'await leaked;' 'return 0;'
reject pass_task 'cannot escape or be copied' 'fn worker() void {}' 'fn sink(task:*opaque) void {}' 'script;' 'let task = async worker();' 'sink(task);' 'return 0;'
reject loop_task 'async task declarations inside repeating loops' 'fn worker() void {}' 'script;' 'let keep:bool = false;' 'while (keep) { let task = async worker(); }' 'return 0;'
reject double_await 'double free|use after free' 'fn worker() void {}' 'script;' 'let task = async worker();' 'await task;' 'await task;' 'return 0;'
reject wrong_worker 'direct non-generic captureless fn\(\) void or fn\(i64\) void worker' 'fn wrong(x:i32) void {}' 'script;' 'let task = async wrong();' 'await task;' 'return 0;'
reject missing_arg 'direct non-generic captureless fn\(\) void or fn\(i64\) void worker' 'fn worker(value:i64) void {}' 'script;' 'let task = async worker();' 'await task;' 'return 0;'
reject bad_arg 'worker argument must be i64' 'fn worker(value:i64) void {}' 'script;' 'let bad:i32 = 1;' 'let task = async worker(bad);' 'await task;' 'return 0;'
reject await_non_task 'named \*opaque handle|requires.*\*opaque|task handle' 'script;' 'let value:i64 = 1;' 'await value;' 'return 0;'
reject indirect_worker '(@threadSpawn|`async`/@threadSpawn) requires a direct non-generic captureless' 'fn worker() void {}' 'script;' 'let f = worker;' 'let task = async f();' 'await task;' 'return 0;'
reject raw_thread_still_unsafe 'thread spawn requires unsafe' 'fn worker() void {}' 'fn bad() i32 { let task:*opaque=@threadSpawn(worker); @threadJoin(task); return 0; }'
echo 'ZagScript async/await: explicit join, automatic cancellation+join, affine tasks, native execution, and fail-closed shapes PASS'
