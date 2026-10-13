#!/usr/bin/env bash
# macOS/ARM64 compiler-lowered thread evidence. This proves the same bounded,
# unsafe, join-only language surface as Linux while using supported pthreads.
set -euo pipefail

cd "$(dirname "$0")/.."
. tests/portable.sh

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "XX  macOS thread gate requires physical Apple Silicon" >&2
    exit 1
fi

ZNC=${ZNC:-./znc-macos-arm64}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
if [ ! -x "$ZNC" ]; then
    echo "XX  native macOS compiler not executable: $ZNC" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-thread.XXXXXX")
cleanup() {
    if [ "${KEEP_TMP:-0}" = 1 ]; then
        echo "kept $tmp" >&2
    else
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT

project() {
    mkdir -p "$tmp/$1"
    printf 'name = "thread-%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$tmp/$1/zag.mod"
}

project smoke
cp tests/macos_thread_smoke.zag "$tmp/smoke/main.zag"
(cd "$tmp/smoke" && zag_run_bounded 180 "$ZNC" main.zag --target macos-arm64 --dynamic \
    --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
zag_run_bounded 10 "$tmp/smoke/app"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
    echo "macOS one-worker trampoline smoke returned $rc" >&2
    sed -n '1,100p' "$tmp/smoke/log" >&2
    exit 1
fi

project valid
cp tests/macos_thread_spawn.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && zag_run_bounded 180 "$ZNC" main.zag --target macos-arm64 --dynamic \
    --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
file "$tmp/valid/app" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict "$tmp/valid/app"
dyld_info -opcodes "$tmp/valid/app" | grep -q 'SET_SYMBOL_TRAILING_FLAGS_IMM.*_pthread_create'
dyld_info -opcodes "$tmp/valid/app" | grep -q 'SET_SYMBOL_TRAILING_FLAGS_IMM.*_pthread_join'
otool -L "$tmp/valid/app" | grep -q '/usr/lib/libSystem.B.dylib'
set +e
zag_run_bounded 10 "$tmp/valid/app"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
    echo "macOS thread witness returned $rc" >&2
    sed -n '1,100p' "$tmp/valid/log" >&2
    exit 1
fi

project scalar-arg
printf '%s\n' \
    'global let thread_arg_total:i64;' \
    'fn add_worker(value:i64) void { unsafe { let p:*mut i64=(&thread_arg_total) as *mut i64; let _old:i64=@atomicFetchAdd64(p,value); } }' \
    'fn main() i32 { unsafe { let h:*opaque=@threadSpawn(add_worker,42); @threadJoin(h); let p:*const i64=(&thread_arg_total) as *const i64; if(@atomicLoad64(p)==42){return 42;} return 1; } }' \
    >"$tmp/scalar-arg/main.zag"
(cd "$tmp/scalar-arg" && zag_run_bounded 180 "$ZNC" main.zag --target macos-arm64 --dynamic \
    --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
zag_run_bounded 10 "$tmp/scalar-arg/app"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
    echo "macOS thread scalar argument witness returned $rc" >&2
    sed -n '1,100p' "$tmp/scalar-arg/log" >&2
    exit 1
fi

project unsafe
printf 'fn worker() void {} fn main() i32 { let h:*opaque=@threadSpawn(worker); @threadJoin(h); return 0; }\n' >"$tmp/unsafe/main.zag"
if (cd "$tmp/unsafe" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/unsafe/log" 2>&1 || [ -e "$tmp/unsafe/out" ]; then
    echo "thread spawn outside unsafe unexpectedly compiled" >&2; exit 1
fi
grep -q 'thread spawn requires unsafe' "$tmp/unsafe/log"

project worker
printf 'fn wrong(x:i32) void {} fn main() i32 { unsafe { let h:*opaque=@threadSpawn(wrong); @threadJoin(h); return 0; } }\n' >"$tmp/worker/main.zag"
if (cd "$tmp/worker" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/worker/log" 2>&1 || [ -e "$tmp/worker/out" ]; then
    echo "thread spawn accepted an invalid worker" >&2; exit 1
fi
grep -q 'direct non-generic captureless fn() void or fn(i64) void worker' "$tmp/worker/log"

project argument-shape
printf 'fn worker(x:i64) void {} fn main() i32 { unsafe { let h:*opaque=@threadSpawn(worker); @threadJoin(h); return 0; } }\n' >"$tmp/argument-shape/main.zag"
if (cd "$tmp/argument-shape" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/argument-shape/log" 2>&1 || [ -e "$tmp/argument-shape/out" ]; then
    echo "thread spawn accepted an i64 worker without its required argument" >&2; exit 1
fi
grep -q 'direct non-generic captureless fn() void or fn(i64) void worker' "$tmp/argument-shape/log"

project argument-type
printf 'fn worker(x:i64) void {} fn main() i32 { unsafe { let bad:i32=1; let h:*opaque=@threadSpawn(worker,bad); @threadJoin(h); return 0; } }\n' >"$tmp/argument-type/main.zag"
if (cd "$tmp/argument-type" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/argument-type/log" 2>&1 || [ -e "$tmp/argument-type/out" ]; then
    echo "thread spawn accepted a non-i64 worker argument" >&2; exit 1
fi
grep -q 'worker argument must be i64' "$tmp/argument-type/log"

project handle
printf 'fn worker() void {} fn main() i32 { unsafe { let x:i64=0; @threadJoin(x); return 0; } }\n' >"$tmp/handle/main.zag"
if (cd "$tmp/handle" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/handle/log" 2>&1 || [ -e "$tmp/handle/out" ]; then
    echo "thread join accepted a non-handle" >&2; exit 1
fi
grep -q 'requires the named \*opaque handle' "$tmp/handle/log"

project pure
printf 'fn worker() void {} fn bad() void @pure { unsafe { let h:*opaque=@threadSpawn(worker); @threadJoin(h); } } fn main() i32 { return 0; }\n' >"$tmp/pure/main.zag"
if (cd "$tmp/pure" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/pure/log" 2>&1 || [ -e "$tmp/pure/out" ]; then
    echo "pure thread spawn unexpectedly compiled" >&2; exit 1
fi
grep -q 'capability violation.*pure' "$tmp/pure/log"

project leak
printf 'fn worker() void {} fn main() i32 { unsafe { let h:*opaque=@threadSpawn(worker); return 0; } }\n' >"$tmp/leak/main.zag"
if (cd "$tmp/leak" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/leak/log" 2>&1 || [ -e "$tmp/leak/out" ]; then
    echo "unjoined thread handle unexpectedly compiled" >&2; exit 1
fi
grep -q 'owned allocation.*neither released nor returned' "$tmp/leak/log"

echo "macOS ARM64 thread spawn/join: pthread trampoline, atomic work, scalar argument, and fail-closed ownership boundary pass"
