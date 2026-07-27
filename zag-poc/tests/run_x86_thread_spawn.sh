#!/usr/bin/env bash
# Linux/x86-64 compiler-lowered thread evidence.  This is intentionally a
# narrow, unsafe, join-only boundary: it proves clone child control flow and
# clear-TID futex join, not a general safe concurrency or race-free model.
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-x86-thread.XXXXXX)
cleanup() { if [ "${KEEP_TMP:-0}" != 1 ]; then rm -rf "$tmp"; else echo "kept $tmp" >&2; fi; }
trap cleanup EXIT

project() {
  mkdir -p "$tmp/$1"
  printf 'name = "thread-%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$tmp/$1/zag.mod"
}

project valid
cp tests/x86_thread_spawn.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
timeout 5 strace -f -qq -e trace=clone,futex -o "$tmp/valid/thread.log" "$tmp/valid/app"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
  echo "thread witness returned $rc" >&2
  sed -n '1,80p' "$tmp/valid/log" >&2
  exit 1
fi
grep -q 'clone(' "$tmp/valid/thread.log"
grep -q 'FUTEX_WAIT' "$tmp/valid/thread.log"

project unsafe
printf 'fn worker() void {} fn main() i32 { let h:*opaque=@threadSpawn(worker); @threadJoin(h); return 0; }\n' >"$tmp/unsafe/main.zag"
if (cd "$tmp/unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/unsafe/log" 2>&1 || [ -e "$tmp/unsafe/out" ]; then
  echo "thread spawn outside unsafe unexpectedly compiled" >&2; exit 1
fi
grep -q 'thread spawn requires unsafe' "$tmp/unsafe/log"

project worker
printf 'fn wrong(x:i32) void {} fn main() i32 { unsafe { let h:*opaque=@threadSpawn(wrong); @threadJoin(h); return 0; } }\n' >"$tmp/worker/main.zag"
if (cd "$tmp/worker" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/worker/log" 2>&1 || [ -e "$tmp/worker/out" ]; then
  echo "thread spawn accepted a nonzero-argument worker" >&2; exit 1
fi
grep -q 'direct non-generic captureless fn() void worker' "$tmp/worker/log"

project handle
printf 'fn worker() void {} fn main() i32 { unsafe { let x:i64=0; @threadJoin(x); return 0; } }\n' >"$tmp/handle/main.zag"
if (cd "$tmp/handle" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/handle/log" 2>&1 || [ -e "$tmp/handle/out" ]; then
  echo "thread join accepted a non-handle" >&2; exit 1
fi
grep -q 'requires the named \*opaque handle' "$tmp/handle/log"

project pure
printf 'fn worker() void {} fn bad() void @pure { unsafe { let h:*opaque=@threadSpawn(worker); @threadJoin(h); } } fn main() i32 { return 0; }\n' >"$tmp/pure/main.zag"
if (cd "$tmp/pure" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/pure/log" 2>&1 || [ -e "$tmp/pure/out" ]; then
  echo "pure thread spawn unexpectedly compiled" >&2; exit 1
fi
grep -q 'capability violation.*pure' "$tmp/pure/log"

project leak
printf 'fn worker() void {} fn main() i32 { unsafe { let h:*opaque=@threadSpawn(worker); return 0; } }\n' >"$tmp/leak/main.zag"
if (cd "$tmp/leak" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/leak/log" 2>&1 || [ -e "$tmp/leak/out" ]; then
  echo "unjoined thread handle unexpectedly compiled" >&2; exit 1
fi
grep -q 'owned allocation.*neither released nor returned' "$tmp/leak/log"

echo "x86 Linux thread spawn/join: clone child trampoline, clear-TID futex join, and fail-closed ownership boundary pass"
