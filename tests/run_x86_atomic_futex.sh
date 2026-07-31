#!/usr/bin/env bash
# Bounded Linux/x86-64 futex execution evidence.  This is deliberately not a
# thread or race suite: it proves actual FUTEX_WAIT/FUTEX_WAKE syscalls, their
# deterministic nonblocking mismatch result, checked pointer validation, and
# fail-closed type/effect boundaries.
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-x86-futex.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/valid"
printf 'name = "futexvalid"\nversion = "0"\nedition = "2027"\n' >"$tmp/valid/zag.mod"
cp tests/x86/x86_atomic_futex.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
strace -qq -e trace=futex -o "$tmp/valid/futex.log" "$tmp/valid/app"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
    echo "futex witness returned $rc" >&2
    sed -n '1,20p' "$tmp/valid/log" >&2
    exit 1
fi
grep -Eq 'futex\(.*FUTEX_WAIT, 8.*EAGAIN' "$tmp/valid/futex.log"
grep -Eq 'futex\(.*FUTEX_WAKE, 1\).* = 0' "$tmp/valid/futex.log"

mkdir -p "$tmp/unsafe"
printf 'name = "futexunsafe"\nversion = "0"\nedition = "2027"\n' >"$tmp/unsafe/zag.mod"
printf 'fn main() i32 { let x:i32=0; let p:*const i32=(&x) as *const i32; return @atomicWake32(p,1) as i32; }\n' >"$tmp/unsafe/main.zag"
if (cd "$tmp/unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/unsafe/log" 2>&1 || [ -e "$tmp/unsafe/out" ]; then
    echo "futex outside unsafe unexpectedly compiled" >&2
    exit 1
fi
grep -q 'atomic futex operation requires unsafe' "$tmp/unsafe/log"

mkdir -p "$tmp/type"
printf 'name = "futextype"\nversion = "0"\nedition = "2027"\n' >"$tmp/type/zag.mod"
printf 'fn main() i32 { unsafe { let x:i64=0; let p:*const i64=(&x) as *const i64; return @atomicWait32(p,0) as i32; } }\n' >"$tmp/type/main.zag"
if (cd "$tmp/type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/type/log" 2>&1 || [ -e "$tmp/type/out" ]; then
    echo "non-i32 futex pointer unexpectedly compiled" >&2
    exit 1
fi
grep -q 'futex operation requires an explicitly aligned' "$tmp/type/log"

mkdir -p "$tmp/value"
printf 'name = "futexvalue"\nversion = "0"\nedition = "2027"\n' >"$tmp/value/zag.mod"
printf 'fn main() i32 { unsafe { let x:i32=0; let p:*const i32=(&x) as *const i32; let wrong:i64=0; return @atomicWait32(p,wrong) as i32; } }\n' >"$tmp/value/main.zag"
if (cd "$tmp/value" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/value/log" 2>&1 || [ -e "$tmp/value/out" ]; then
    echo "non-i32 futex value unexpectedly compiled" >&2
    exit 1
fi
grep -q 'futex expected value/count must be i32' "$tmp/value/log"

mkdir -p "$tmp/pure"
printf 'name = "futexpure"\nversion = "0"\nedition = "2027"\n' >"$tmp/pure/zag.mod"
printf 'fn bad() i64 @pure { unsafe { let x:i32=0; let p:*const i32=(&x) as *const i32; return @atomicWake32(p,1); } } fn main() i32 { return 0; }\n' >"$tmp/pure/main.zag"
if (cd "$tmp/pure" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/pure/log" 2>&1 || [ -e "$tmp/pure/out" ]; then
    echo "pure futex operation unexpectedly compiled" >&2
    exit 1
fi
grep -q 'capability violation.*pure' "$tmp/pure/log"

mkdir -p "$tmp/null"
printf 'name = "futexnull"\nversion = "0"\nedition = "2027"\n' >"$tmp/null/zag.mod"
printf 'fn main() i32 { unsafe { let p:*const i32=0 as *const i32; return @atomicWake32(p,1) as i32; } }\n' >"$tmp/null/main.zag"
(cd "$tmp/null" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
"$tmp/null/app" >"$tmp/null/stdout" 2>"$tmp/null/stderr"
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! grep -q 'zag atomic: null i32 futex word' "$tmp/null/stderr"; then
    echo "null futex pointer did not trap explicitly" >&2
    sed -n '1,20p' "$tmp/null/stderr" >&2
    exit 1
fi

mkdir -p "$tmp/misaligned"
printf 'name = "futexmisaligned"\nversion = "0"\nedition = "2027"\n' >"$tmp/misaligned/zag.mod"
printf 'fn main() i32 { unsafe { let bytes:*i8=_zag_malloc(8) as *i8; let p:*const i32=(&bytes[1]) as *const i32; let rc:i64=@atomicWake32(p,1); _zag_free(bytes); return rc as i32; } }\n' >"$tmp/misaligned/main.zag"
(cd "$tmp/misaligned" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o app >log 2>&1)
set +e
"$tmp/misaligned/app" >"$tmp/misaligned/stdout" 2>"$tmp/misaligned/stderr"
rc=$?
set -e
if [ "$rc" -eq 0 ] || ! grep -q 'zag atomic: misaligned i32 futex word' "$tmp/misaligned/stderr"; then
    echo "misaligned futex pointer did not trap explicitly" >&2
    sed -n '1,20p' "$tmp/misaligned/stderr" >&2
    exit 1
fi

echo "x86 Linux futex wait/wake: kernel syscall, checked pointer, and fail-closed boundary pass"
