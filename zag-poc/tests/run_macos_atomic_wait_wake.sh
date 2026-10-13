#!/usr/bin/env bash
# Apple-Silicon Darwin wait/wake evidence. The public language surface matches
# Linux's raw i32 wait/wake contract while the native mechanism is pthread
# mutex/condition-variable based rather than Linux futex(2).
set -euo pipefail

cd "$(dirname "$0")/.."
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS wait/wake gate requires physical Apple Silicon' >&2
    exit 1
fi

ZNC=${ZNC:-./znc-macos-arm64}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
if [ ! -x "$ZNC" ]; then
    echo "macOS wait/wake compiler not executable: $ZNC" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-wait.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

project() {
    mkdir -p "$tmp/$1"
    printf 'name = "wait-%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$tmp/$1/zag.mod"
}

project valid
cp tests/macos_atomic_wait_wake.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && zag_run_bounded 180 "$ZNC" main.zag --target macos-arm64 --dynamic \
    --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
zag_assert_native_executable "$tmp/valid/app"
codesign --verify --strict "$tmp/valid/app"
for symbol in pthread_mutex_init pthread_mutex_lock pthread_mutex_unlock pthread_cond_init pthread_cond_wait pthread_cond_signal pthread_cond_destroy; do
    dyld_info -opcodes "$tmp/valid/app" | grep -q "SET_SYMBOL_TRAILING_FLAGS_IMM.*_${symbol}"
done
set +e
zag_run_bounded 15 "$tmp/valid/app"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
    echo "macOS wait/wake witness returned $rc" >&2
    sed -n '1,100p' "$tmp/valid/log" >&2
    exit 1
fi

project unsafe
printf 'fn main() i32 { let x:i32=0; let p:*const i32=(&x) as *const i32; return @atomicWake32(p,1) as i32; }\n' >"$tmp/unsafe/main.zag"
if (cd "$tmp/unsafe" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/unsafe/log" 2>&1 || [ -e "$tmp/unsafe/out" ]; then
    echo "wait/wake outside unsafe unexpectedly compiled" >&2; exit 1
fi
grep -q 'atomic wait/wake operation requires unsafe' "$tmp/unsafe/log"

project type
printf 'fn main() i32 { unsafe { let x:i64=0; let p:*const i64=(&x) as *const i64; return @atomicWait32(p,0) as i32; } }\n' >"$tmp/type/main.zag"
if (cd "$tmp/type" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/type/log" 2>&1 || [ -e "$tmp/type/out" ]; then
    echo "non-i32 wait pointer unexpectedly compiled" >&2; exit 1
fi
grep -q 'wait/wake operation requires an explicitly aligned' "$tmp/type/log"

project value
printf 'fn main() i32 { unsafe { let x:i32=0; let p:*const i32=(&x) as *const i32; let wrong:i64=0; return @atomicWait32(p,wrong) as i32; } }\n' >"$tmp/value/main.zag"
if (cd "$tmp/value" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/value/log" 2>&1 || [ -e "$tmp/value/out" ]; then
    echo "non-i32 wait value unexpectedly compiled" >&2; exit 1
fi
grep -q 'wait/wake expected value/count must be i32' "$tmp/value/log"

project pure
printf 'fn bad() i64 @pure { unsafe { let x:i32=0; let p:*const i32=(&x) as *const i32; return @atomicWake32(p,1); } } fn main() i32 { return 0; }\n' >"$tmp/pure/main.zag"
if (cd "$tmp/pure" && "$ZNC" main.zag --target macos-arm64 --dynamic --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/pure/log" 2>&1 || [ -e "$tmp/pure/out" ]; then
    echo "pure wait/wake unexpectedly compiled" >&2; exit 1
fi
grep -q 'capability violation.*pure' "$tmp/pure/log"

project null
printf 'fn main() i32 { unsafe { let p:*const i32=0 as *const i32; return @atomicWake32(p,1) as i32; } }\n' >"$tmp/null/main.zag"
(cd "$tmp/null" && "$ZNC" main.zag --target macos-arm64 --dynamic --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
"$tmp/null/app" >"$tmp/null/stdout" 2>"$tmp/null/stderr"
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! grep -q 'zag safety: null raw pointer access' "$tmp/null/stderr"; then
    echo "null wait/wake pointer did not trap explicitly" >&2; exit 1
fi

project misaligned
printf 'fn main() i32 { unsafe { let bytes:*i8=_zag_malloc(8) as *i8; let p:*const i32=(&bytes[1]) as *const i32; let rc:i64=@atomicWake32(p,1); _zag_free(bytes); return rc as i32; } }\n' >"$tmp/misaligned/main.zag"
(cd "$tmp/misaligned" && "$ZNC" main.zag --target macos-arm64 --dynamic --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
"$tmp/misaligned/app" >"$tmp/misaligned/stdout" 2>"$tmp/misaligned/stderr"
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! grep -q 'zag safety: misaligned raw pointer access' "$tmp/misaligned/stderr"; then
    echo "misaligned wait/wake pointer did not trap explicitly" >&2; exit 1
fi

echo "macOS ARM64 wait/wake: blocking address match, exact wake count, raw mismatch result, and fail-closed boundary pass"
