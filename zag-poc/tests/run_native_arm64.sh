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

echo "── output (write syscall) ──"
nto "print_i32"      'fn main() i32 { print_i32(12345); return 0; }' "12345" 0
nto "print_int"      'fn main() i32 { print_int(42); return 0; }' "42" 0
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