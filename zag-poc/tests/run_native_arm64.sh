#!/usr/bin/env bash
# AArch64 Linux backend suite: compile Zag to static EM_AARCH64 ELF, run via qemu-user.
cd "$(dirname "$0")/.."    # zag-poc root
pass=0; fail=0

QEMU="${QEMU:-qemu-aarch64-static}"
if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "  XX  $QEMU not found (apt install qemu-user-static)"; exit 1
fi

if [ -z "${ZNC:-}" ]; then
    if ! ./znc selfhost/native/znc.zag -o /tmp/znc_drv >/tmp/zn_build 2>&1; then
        echo "  XX  znc driver build"; sed -n '1,20p' /tmp/zn_build
        echo "════ arm64 pass=0 fail=1 ════"; exit 1
    fi
    ZNC=/tmp/znc_drv
fi

nt(){
    printf '%s' "$2" > nt_src.zag
    "$ZNC" nt_src.zag --target arm64 -o /tmp/nt_arm >/tmp/nt_out 2>&1
    if [ ! -x /tmp/nt_arm ]; then echo "  XX  $1 (compile failed)"; sed -n '1,8p' /tmp/nt_out; fail=$((fail+1)); return; fi
    if ! file /tmp/nt_arm | grep -q 'ARM aarch64'; then
        echo "  XX  $1 (not aarch64 ELF)"; fail=$((fail+1)); return
    fi
    "$QEMU" /tmp/nt_arm; local got=$?
    if [ "$got" = "$3" ]; then echo "  ok  $1 (exit $got)"; pass=$((pass+1));
    else echo "  XX  $1 (got $got, want $3)"; fail=$((fail+1)); fi
    rm -f /tmp/nt_arm
}

nto(){
    printf '%s' "$2" > nt_src.zag
    "$ZNC" nt_src.zag --target arm64 -o /tmp/nt_arm >/tmp/nt_out 2>&1
    if [ ! -x /tmp/nt_arm ]; then echo "  XX  $1 (compile failed)"; sed -n '1,8p' /tmp/nt_out; fail=$((fail+1)); return; fi
    local got; got=$("$QEMU" /tmp/nt_arm); local ec=$?
    if [ "$got" = "$3" ] && [ "$ec" = "$4" ]; then echo "  ok  $1 (stdout='$got' exit=$ec)"; pass=$((pass+1));
    else echo "  XX  $1 (got stdout='$got' exit=$ec, want '$3'/$4)"; fail=$((fail+1)); fi
    rm -f /tmp/nt_arm
}

echo "── arm64 backend: Zag → AArch64 ELF (qemu-user) ──"
nt "return literal"  'fn main() i32 { return 42; }' 42
nt "arithmetic"      'fn main() i32 { let a: i32 = 8; let b: i32 = 5; return a * b - 2; }' 38
nt "function call"   'fn add(a: i32, b: i32) i32 { return a + b; } fn main() i32 { return add(40, 2); }' 42
nt "while loop"      'fn main() i32 { let s: i32 = 0; let i: i32 = 1; while (i <= 10) { s = s + i; i = i + 1; } return s; }' 55
nt "if/else"         'fn main() i32 { let x: i32 = 7; if (x < 5) { return 1; } else { return 99; } }' 99
nt "recursion (fib)" 'fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); } fn main() i32 { return fib(10); }' 55
nt "factorial"       'fn fact(n: i32) i32 { if (n < 2) { return 1; } return n * fact(n - 1); } fn main() i32 { return fact(5); }' 120
nt "div and mod"     'fn main() i32 { return (100 / 7) + (100 % 7); }' 16
nt "unary minus"     'fn main() i32 { let a: i32 = 50; return 0 - a + 57; }' 7
nt "nested if/else"  'fn main() i32 { let x: i32 = 7; if (x < 5) { return 1; } else if (x < 10) { return 99; } else { return 2; } }' 99
nt "fwd mutual rec"  'fn bar() i32; fn foo() i32 { return bar(); } fn bar() i32 { return 42; } fn main() i32 { return foo(); }' 42
nt "logical ops"     'fn main() i32 { let a: i32 = 1; let b: i32 = 0; if (a == 1 && b == 0) { if (a == 0 || b == 0) { return 33; } } return 1; }' 33
nt "not op"          'fn main() i32 { let a: i32 = 0; if (!a) { return 21; } return 1; }' 21
nt "many args"       'fn s6(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32) i32 { return a + b + c + d + e + f; } fn main() i32 { return s6(1, 2, 3, 4, 5, 6); }' 21
nt "nested calls"    'fn add(a: i32, b: i32) i32 { return a + b; } fn main() i32 { return add(add(10, 20), add(5, 7)); }' 42

echo "── output (write syscall) ──"
nto "print_i32"      'fn main() i32 { print_i32(12345); return 0; }' "12345" 0
nto "print_int"      'fn main() i32 { print_int(42); return 0; }' "42" 0
nto "print_int zero" 'fn main() i32 { print_int(0); return 0; }' "0" 0
nto "print_int neg"  'fn main() i32 { print_i32(0 - 42); return 0; }' "-42" 0
nto "print computed" 'fn main() i32 { let s: i32 = 0; let i: i32 = 1; while (i <= 10) { s = s + i; i = i + 1; } print_int(s); return 0; }' "55" 0
nto "print big i64"  'fn main() i32 { print_int(123456789012); return 0; }' "123456789012" 0
nto "print_str"      'fn main() i32 { print_str("hello\n"); return 0; }' "hello" 0
nto "println str"    'fn main() i32 { _zag_println("world\n"); return 0; }' "world" 0

# static ELF, no interpreter
printf 'fn main() i32 { return 0; }' > nt_src.zag
"$ZNC" nt_src.zag --target arm64 -o /tmp/nt_elf >/dev/null 2>&1
if file /tmp/nt_elf | grep -q 'statically linked' && ! readelf -l /tmp/nt_elf 2>/dev/null | grep -q 'INTERP'; then
    echo "  ok  emitted ELF is static, no interpreter"; pass=$((pass+1))
else
    echo "  XX  emitted ELF static/no-interp check"; fail=$((fail+1))
fi
rm -f /tmp/nt_elf nt_src.zag

echo "════ arm64 pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]