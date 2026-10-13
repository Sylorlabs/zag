#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "XX macOS scalar-intrinsic gate requires native Apple Silicon" >&2
    exit 2
fi

ZNC=${ZNC:-./znc-macos-arm64}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-scalar-intrinsics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compile_run() {
    local name=$1 expected=$2
    "$ZNC" "tests/$name.zag" --target macos-arm64 --cpu=native \
        --no-zagd --no-analyze -o "$tmp/$name" >/dev/null
    file "$tmp/$name" | grep -q 'Mach-O 64-bit executable arm64'
    codesign --verify --deep --strict --verbose=2 "$tmp/$name" >/dev/null
    set +e
    "$tmp/$name"
    local rc=$?
    set -e
    if [ "$rc" -ne "$expected" ]; then
        echo "XX macOS scalar intrinsic $name returned $rc (expected $expected)" >&2
        exit 1
    fi
    otool -tvV "$tmp/$name" >"$tmp/$name.disassembly"
}

compile_run x86_popcount 8
grep -Eq $'fmov[[:space:]]+d0, x0' "$tmp/x86_popcount.disassembly"
grep -Eq $'cnt\.16b[[:space:]]+v0, v0' "$tmp/x86_popcount.disassembly"
grep -Eq $'addv\.16b[[:space:]]+b0, v0' "$tmp/x86_popcount.disassembly"
grep -Eq $'umov\.b[[:space:]]+w0, v0\[0\]' "$tmp/x86_popcount.disassembly"
echo "  ok  popcount executes through mandatory AArch64 Advanced SIMD"

compile_run x86_andn 42
grep -Eq $'bic[[:space:]]+x0, x1, x0' "$tmp/x86_andn.disassembly"
echo "  ok  andn executes through AArch64 BIC with x86-compatible operand order"

compile_run x86_leading_zeros 42
grep -Eq $'clz[[:space:]]+x0, x0' "$tmp/x86_leading_zeros.disassembly"
echo "  ok  leading_zeros executes through baseline AArch64 CLZ"

compile_run x86_trailing_zeros 42
grep -Eq $'rbit[[:space:]]+x0, x0' "$tmp/x86_trailing_zeros.disassembly"
grep -Eq $'clz[[:space:]]+x0, x0' "$tmp/x86_trailing_zeros.disassembly"
echo "  ok  trailing_zeros executes through baseline AArch64 RBIT + CLZ"

compile_run x86_byte_swap 42
grep -Eq $'rev[[:space:]]+x0, x0' "$tmp/x86_byte_swap.disassembly"
echo "  ok  byte_swap64 executes through baseline AArch64 REV"

echo "macos-scalar-intrinsics pass=5 fail=0"
