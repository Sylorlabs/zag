#!/usr/bin/env bash
# Native Mach-O dyld binding regression: no host linker or ELF shim is used.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "macOS dyld import: skipped (requires Apple Silicon macOS)"
    exit 0
fi

compiler=${ZNC:-./znc}
test -x "$compiler"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-dyld.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$compiler" tests/macos_dyld_getpid.zag --target macos-arm64 --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/getpid"
file "$tmp/getpid" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict "$tmp/getpid"
otool -l "$tmp/getpid" | grep -q 'LC_DYLD_INFO_ONLY'
otool -l "$tmp/getpid" | grep -q '/usr/lib/libSystem.B.dylib'
set +e
"$tmp/getpid"
status=$?
set -e
test "$status" -eq 42
echo "macOS dyld import: pass"
