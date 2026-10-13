#!/usr/bin/env bash
# Native Apple-Silicon evidence for the ARM64 checked-pointer and bounded
# memory-sanitizer modes. The fixtures intentionally mirror the Linux ARM64
# contract while asserting that every executable is signed Mach-O.
set -euo pipefail

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/portable.sh"

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS checked safety: unsupported host (requires Apple Silicon macOS)' >&2
    exit 2
fi

compiler="${ZNC:-./znc-macos-arm64}"
case "$compiler" in /*) ;; *) compiler="$(pwd)/${compiler#./}" ;; esac
if [ ! -x "$compiler" ]; then
    echo "macOS checked safety: compiler is not executable: $compiler" >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-safety.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
pass=0

make_case() {
    name=$1
    source=$2
    mkdir -p "$work/$name"
    printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$name" \
        >"$work/$name/zag.mod"
    printf '%s\n' "$source" >"$work/$name/main.zag"
}

compile_case() {
    name=$1
    mode=$2
    shift 2
    if ! (
        cd "$work/$name"
        "$compiler" main.zag --target macos-arm64 "$mode" "$@" \
            --no-zagd --no-analyze -o out >build.log 2>&1
    ); then
        echo "macOS checked safety: $name failed to compile in $mode" >&2
        sed -n '1,100p' "$work/$name/build.log" >&2
        return 1
    fi
    zag_assert_native_executable "$work/$name/out"
}

expect_exit() {
    name=$1
    mode=$2
    expected=$3
    shift 3
    compile_case "$name" "$mode" "$@"
    set +e
    "$work/$name/out" >"$work/$name/out.log" 2>"$work/$name/err.log"
    actual=$?
    set -e
    if [ "$actual" -ne "$expected" ]; then
        echo "macOS checked safety: $name exited $actual, expected $expected" >&2
        sed -n '1,12p' "$work/$name/build.log" >&2
        sed -n '1,12p' "$work/$name/err.log" >&2
        exit 1
    fi
    pass=$((pass + 1))
}

expect_trap() {
    name=$1
    mode=$2
    diagnostic=$3
    shift 3
    compile_case "$name" "$mode" "$@"
    set +e
    "$work/$name/out" >"$work/$name/out.log" 2>"$work/$name/err.log"
    actual=$?
    set -e
    if [ "$actual" -eq 0 ] || ! grep -Fq "$diagnostic" "$work/$name/err.log"; then
        echo "macOS checked safety: $name did not produce the required trap" >&2
        sed -n '1,12p' "$work/$name/build.log" >&2
        sed -n '1,12p' "$work/$name/err.log" >&2
        exit 1
    fi
    pass=$((pass + 1))
}

expect_memory_fault() {
    name=$1
    mode=$2
    shift 2
    compile_case "$name" "$mode" "$@"
    set +e
    "$work/$name/out" >"$work/$name/out.log" 2>"$work/$name/err.log"
    actual=$?
    set -e
    # Darwin reports a PROT_NONE data access as SIGBUS or SIGSEGV depending on
    # the exact VM fault path. Bash exposes those as 128+signal.
    case "$actual" in
        138|139) ;;
        *)
            echo "macOS checked safety: $name did not fault on protected memory (exit=$actual)" >&2
            sed -n '1,12p' "$work/$name/build.log" >&2
            sed -n '1,12p' "$work/$name/err.log" >&2
            exit 1
            ;;
    esac
    pass=$((pass + 1))
}

make_case checked_null \
    'fn main() i32 { unsafe { let p:*const i32=null as *const i32; return p.*; } }'
expect_trap checked_null --safety=checked \
    'zag safety: null raw pointer access'

make_case checked_live \
    'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p[0]=42; let value:i8=p[0]; _zag_free(p); return value as i32; } }'
expect_exit checked_live --safety=checked 42

make_case checked_misaligned \
    'fn main() i32 { unsafe { let bytes:*i8=_zag_malloc(32) as *i8; let p:*const i32=(&bytes[1]) as *const i32; let value:i32=p.*; _zag_free(bytes); return value; } }'
expect_trap checked_misaligned --safety=checked \
    'zag safety: misaligned raw pointer access'

make_case checked_oob \
    'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; let value:i32=p[16] as i32; _zag_free(p); return value; } }'
expect_trap checked_oob --safety=checked \
    'zag safety: allocator pointer access out of bounds'

make_case checked_index_overflow \
    'fn main() i32 { unsafe { let p:*i64=_zag_malloc(8) as *i64; let i:i64=2305843009213693952; let value:i32=p[i] as i32; _zag_free(p); return value; } }'
expect_trap checked_index_overflow --safety=checked \
    'zag safety: raw pointer index arithmetic overflow'

make_case checked_uaf \
    'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; let saved:i64=(p as i64)+0; _zag_free(p); let stale:*i8=saved as *i8; return stale.* as i32; } }'
expect_trap checked_uaf --safety=checked \
    'zag safety: use after free of allocator pointer'

make_case checked_stack \
    'fn main() i32 { unsafe { let x:i32=42; let p:*const i32=(&x) as *const i32; return p.*; } }'
expect_exit checked_stack --safety=checked 42

# Edition-2027 scalar globals use the same PIE-relative writable image that
# holds the macOS safety registry; this catches a silent v1-lowering fallback.
make_case checked_global \
    'global let counter:i32; fn main() i32 { counter=42; return counter; }'
expect_exit checked_global --safety=checked 42

# Checked alignment guards must preserve the live pointer register used by
# ARM64 LL/SC atomics. This caught a prior x10/mask scratch alias that turned
# a valid pointer into address 0x7 immediately before LDAXR.
make_case checked_atomic "$(cat tests/macos_v2/atomic_rmw.zag)"
expect_exit checked_atomic --safety=checked 42

# Keep allocator and global storage independent, and exercise both direct
# accesses and address-taking under each native runtime policy.
global_source=$(cat tests/macos_globals.zag)
make_case globals_unchecked "$global_source"
expect_exit globals_unchecked --no-foreground-cache 42
make_case globals_checked "$global_source"
expect_exit globals_checked --safety=checked 42
make_case globals_sanitized "$global_source"
expect_exit globals_sanitized --sanitize=memory 42

make_case sanitize_released \
    'extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; fn main() i32 { let p:*u8=_zag_malloc(16); _zag_free(p); return 37; }'
expect_exit sanitize_released --sanitize=memory 37

make_case sanitize_logical_oob \
    'fn main() i32 { unsafe { let p:*i8=_zag_malloc(1) as *i8; p[1]=7; _zag_free(p); return 0; } }'
expect_trap sanitize_logical_oob --sanitize=memory \
    'zag safety: allocator pointer access out of bounds'

# The sanitizer reserves a physical canary beyond the logical allocation.
# Use the already-audited libSystem qsort callback path to sort the final live
# byte together with the first canary byte. qsort performs the swap outside
# Zag's checked raw-access lowering, so free must catch the damaged canary.
make_case sanitize_small_redzone \
    'extern fn qsort(base:*u8,n:i64,size:i64,cmp:fn(*u8,*u8)i32) void @cabi @borrows_mut; extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; fn compare(a:*u8,b:*u8) i32 { unsafe { if(a.* < b.*){return -1;} if(a.* > b.*){return 1;} return 0; } } fn main() i32 { unsafe { let p:*u8=_zag_malloc(16); p[15]=255; let tail:*u8=((p as i64)+15) as *u8; qsort(tail,2,1,compare); _zag_free(p); return 42; } }'
expect_trap sanitize_small_redzone --sanitize=memory \
    'zag sanitizer: small allocation trailing red zone corrupted' --dynamic

# Quarantined small payloads are overwritten with the same deterministic A5
# byte pattern as the native x86-64 sanitizer. The payload starts with zero;
# after free, the already-audited libSystem strlen path must see at least the
# full 16-byte payload before it can encounter a zero outside the allocation.
make_case sanitize_small_poison \
    'extern fn strlen(text:*i8)i64 @cabi @borrows; extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p[0]=0; let stale_address:i64=(p as i64)+0; _zag_free(p as *u8); let stale:*i8=stale_address as *i8; let observed:i64=strlen(stale); if(observed>=16){return 42;} return 1; } }'
expect_exit sanitize_small_poison --sanitize=memory 42 --dynamic

# 600000 exceeds the 512 KiB arena ceiling, so sanitizer mode must take the
# dedicated mapping path, install its trailing 16 KiB guard, and reconstruct
# that same physical length during release.
make_case sanitize_large_guard_release \
    'extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; fn main() i32 { unsafe { let p:*u8=_zag_malloc(600000); p.*=9; _zag_free(p); return 41; } }'
expect_exit sanitize_large_guard_release --sanitize=memory 41

# Isolate the Darwin raw mprotect adapter from the sanitizer allocator. A
# normal 600000-byte dedicated mapping spans through base+606208 after native
# page rounding; protect the final full payload page at base+589824, then make
# libSystem touch it. This must fault if syscall 74 and its arguments are wired
# correctly on Apple Silicon.
make_case raw_mprotect_fault \
    'extern fn qsort(base:*u8,n:i64,size:i64,cmp:fn(*u8,*u8)i32) void @cabi @borrows_mut; extern fn _zag_raw_syscall(num:i64,a1:i64,a2:i64,a3:i64,a4:i64,a5:i64,a6:i64)i64; extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; fn compare(a:*u8,b:*u8) i32 { unsafe { if(a.* < b.*){return -1;} if(a.* > b.*){return 1;} return 0; } } fn main() i32 { unsafe { let p:*u8=_zag_malloc(600000); let page:*u8=((p as i64)+589816) as *u8; let rc:i64=_zag_raw_syscall(10,page as i64,16384,0,0,0,0); qsort(page,2,1,compare); _zag_free(p); if(rc==0){return 42;} return 3; } }'
expect_memory_fault raw_mprotect_fault --no-foreground-cache --dynamic

# For a 600000-byte payload, round_up(header+payload, 16384) is 606208 bytes;
# the protected page therefore starts 606200 bytes after the user pointer.
# The already-audited libSystem qsort path reaches the page outside Zag's
# checked-access lowering. If the allocator returned an unguarded mapping this
# would continue and exit 42; the required hardware backstop instead terminates
# when qsort/comparator touches the PROT_NONE page.
make_case sanitize_large_guard_fault \
    'extern fn qsort(base:*u8,n:i64,size:i64,cmp:fn(*u8,*u8)i32) void @cabi @borrows_mut; extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; fn compare(a:*u8,b:*u8) i32 { unsafe { if(a.* < b.*){return -1;} if(a.* > b.*){return 1;} return 0; } } fn main() i32 { unsafe { let p:*u8=_zag_malloc(600000); let guard:*u8=((p as i64)+606200) as *u8; qsort(guard,2,1,compare); _zag_free(p); return 42; } }'
expect_memory_fault sanitize_large_guard_fault --sanitize=memory --dynamic

make_case sanitize_leak \
    'extern fn _zag_malloc(n:i64)*u8; fn main() i32 { let p:*u8=_zag_malloc(16); if(p==null as *u8){return 2;} return 0; }'
# A known owner leak must be caught before code generation, not weakened to
# permit a runtime-only test. Foreign contract mismatch is exercised separately.
if (
    cd "$work/sanitize_leak"
    "$compiler" main.zag --target macos-arm64 --sanitize=memory \
        --no-zagd --no-analyze -o out >build.log 2>&1
); then
    echo 'macOS checked safety: statically visible leak was accepted' >&2
    exit 1
fi
grep -q 'error\[E0204\]' "$work/sanitize_leak/build.log"
test ! -e "$work/sanitize_leak/out"
pass=$((pass + 1))

make_case sanitize_foreign_contract "$(cat tests/macos_v2/sanitizer_escape_leak.zag)"
expect_trap sanitize_foreign_contract --sanitize=memory \
    'zag safety: memory leak detected at exit' --dynamic

printf 'macOS checked safety: pass=%d fail=0\n' "$pass"
