#!/usr/bin/env bash
# AArch64 self-hosting gate: the compiler must cross-compile itself to arm64,
# and that arm64 compiler (run natively on aarch64, else via qemu-user) must
# reproduce ITSELF byte-identically and emit binaries byte-identical to the
# x86-hosted compiler's output for both targets.
cd "$(dirname "$0")/.."    # zag-poc root
pass=0; fail=0

if [ "$(uname -m)" = "aarch64" ]; then
    QEMU=""
else
    QEMU="${QEMU:-qemu-aarch64-static}"
    if ! command -v "$QEMU" >/dev/null 2>&1; then
        echo "  XX  $QEMU not found (apt install qemu-user-static)"; exit 1
    fi
fi

if [ -z "${ZNC:-}" ]; then
    if ! ./znc selfhost/native/znc.zag -o /tmp/znc_ash >/tmp/ash_build 2>&1; then
        echo "  XX  znc driver build"; sed -n '1,20p' /tmp/ash_build
        echo "════ arm64-selfhost pass=0 fail=1 ════"; exit 1
    fi
    ZNC=/tmp/znc_ash
fi

echo "── arm64 self-hosting: cross-compile, fixpoint, output parity ──"

# gen1: x86-hosted compiler cross-compiles znc to arm64
if "$ZNC" selfhost/native/znc.zag --target arm64 -o /tmp/znc_a1 >/tmp/ash1 2>&1 \
   && file /tmp/znc_a1 | grep -q 'ARM aarch64'; then
    echo "  ok  cross-compile znc → arm64"; pass=$((pass+1))
else
    echo "  XX  cross-compile znc → arm64"; sed -n '1,10p' /tmp/ash1; fail=$((fail+1))
    echo "════ arm64-selfhost pass=$pass fail=$fail ════"; exit 1
fi

# gen2: the arm64 compiler compiles znc to arm64 — must equal gen1
if $QEMU /tmp/znc_a1 selfhost/native/znc.zag --target arm64 -o /tmp/znc_a2 >/tmp/ash2 2>&1 \
   && cmp -s /tmp/znc_a1 /tmp/znc_a2; then
    echo "  ok  arm64 fixpoint (gen2 byte-identical to gen1)"; pass=$((pass+1))
else
    echo "  XX  arm64 fixpoint (gen2 differs or build failed)"; sed -n '1,10p' /tmp/ash2; fail=$((fail+1))
fi

# output parity: arm64-hosted and x86-hosted compilers must emit identical
# binaries for the same source, for BOTH targets.
cat > /tmp/ash_prog.zag <<'EOF'
fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); }
fn main() i32 { let s: []u8 = _zag_str_concat("fib=", _zag_i64_to_str(fib(12) as i64)); _zag_println(s); return 0; }
EOF
"$ZNC" /tmp/ash_prog.zag -o /tmp/ash_x86_from_x86 >/dev/null 2>&1
$QEMU /tmp/znc_a1 /tmp/ash_prog.zag -o /tmp/ash_x86_from_arm >/dev/null 2>&1
if cmp -s /tmp/ash_x86_from_x86 /tmp/ash_x86_from_arm; then
    echo "  ok  x86 output parity (arm64-hosted == x86-hosted)"; pass=$((pass+1))
else
    echo "  XX  x86 output parity"; fail=$((fail+1))
fi
"$ZNC" /tmp/ash_prog.zag --target arm64 -o /tmp/ash_arm_from_x86 >/dev/null 2>&1
$QEMU /tmp/znc_a1 /tmp/ash_prog.zag --target arm64 -o /tmp/ash_arm_from_arm >/dev/null 2>&1
if cmp -s /tmp/ash_arm_from_x86 /tmp/ash_arm_from_arm; then
    echo "  ok  arm64 output parity (arm64-hosted == x86-hosted)"; pass=$((pass+1))
else
    echo "  XX  arm64 output parity"; fail=$((fail+1))
fi

# the parity binary must actually run
got=$($QEMU /tmp/ash_arm_from_arm 2>&1); ec=$?
if [ "$got" = "fib=144" ] && [ "$ec" = "0" ]; then
    echo "  ok  arm64-compiled program runs (fib=144)"; pass=$((pass+1))
else
    echo "  XX  arm64-compiled program (got '$got' exit=$ec)"; fail=$((fail+1))
fi

rm -f /tmp/znc_a1 /tmp/znc_a2 /tmp/ash_prog.zag /tmp/ash_x86_from_x86 /tmp/ash_x86_from_arm /tmp/ash_arm_from_x86 /tmp/ash_arm_from_arm
echo "════ arm64-selfhost pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
