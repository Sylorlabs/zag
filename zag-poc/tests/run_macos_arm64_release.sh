#!/usr/bin/env bash
# Native macOS Apple-Silicon release gate.  This intentionally exercises the
# Darwin kernel, Mach-O loader, and embedded signature rather than assuming
# that the Linux/AArch64 ELF tests prove the macOS target.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "XX  macos-arm64 release gate requires native Apple Silicon (got $(uname -s) $(uname -m))" >&2
    exit 2
fi

ZNC="${ZNC:-$PWD/znc}"
if [ ! -x "$ZNC" ]; then
    echo "XX  compiler is not executable: $ZNC" >&2
    exit 2
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-arm64.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
pass=0

require_macho_arm64() {
    local artifact="$1"
    file "$artifact" | grep -q 'Mach-O 64-bit executable arm64'
}

require_signed() {
    local artifact="$1"
    codesign --verify --deep --strict --verbose=2 "$artifact" >/dev/null
}

echo "── native macOS arm64 release gate ──"

# Build the compiler with an explicit Darwin target.  Do not rely solely on
# the host-default rule: this catches target selection regressions too.
"$ZNC" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/znc-gen1"
require_macho_arm64 "$tmpdir/znc-gen1"
require_signed "$tmpdir/znc-gen1"
echo "  ok  signed Mach-O arm64 self-host compiler"; pass=$((pass + 1))

# A compiler executing natively on Darwin must reproduce itself exactly.
"$tmpdir/znc-gen1" selfhost/native/znc.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/znc-gen2"
require_macho_arm64 "$tmpdir/znc-gen2"
require_signed "$tmpdir/znc-gen2"
cmp -s "$tmpdir/znc-gen1" "$tmpdir/znc-gen2"
echo "  ok  native Darwin self-host fixpoint"; pass=$((pass + 1))

# Exercise the signer independently of the compiler-sized artifact.
"$tmpdir/znc-gen1" selfhost/native/macho_arm64_test.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/macho-sign-test"
require_macho_arm64 "$tmpdir/macho-sign-test"
require_signed "$tmpdir/macho-sign-test"
"$tmpdir/macho-sign-test"
echo "  ok  Mach-O SHA-256 signer regression"; pass=$((pass + 1))

# This fixture covers Darwin entry arguments, PIE data addresses, heap,
# write/read/exists, process execution, stdout, and exit status.
"$tmpdir/znc-gen1" tests/macos_arm64_runtime.zag --target macos-arm64 --no-zagd --no-analyze -o "$tmpdir/runtime"
require_macho_arm64 "$tmpdir/runtime"
require_signed "$tmpdir/runtime"
output="$("$tmpdir/runtime" alpha beta)"
[ "$output" = "macos-arm64-ok" ]
[ "$(cat /tmp/zag_macos_arm64_runtime.txt)" = "darwin-roundtrip" ]
rm -f /tmp/zag_macos_arm64_runtime.txt
echo "  ok  Darwin runtime: argv, heap, file I/O, process, stdout"; pass=$((pass + 1))

echo "════ macos-arm64-release pass=$pass fail=0 ════"
