#!/usr/bin/env bash
# Public std:metal_loader physical Apple-Silicon gate.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "XX  std:metal_loader requires physical Apple Silicon" >&2
    exit 1
fi

compiler=${ZNC:-./znc-macos-arm64}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
if [ ! -x "$compiler" ]; then
    echo "XX  native macOS compiler not executable: $compiler" >&2
    exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/zag-metal-loader.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

"$compiler" tests/macos_metal_loader_public.zag --target macos-arm64 \
    --dynamic --no-zagd --no-analyze -o "$tmpdir/metal-loader"

file "$tmpdir/metal-loader" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict "$tmpdir/metal-loader"
otool -L "$tmpdir/metal-loader" | grep -q '/Metal.framework/'
otool -L "$tmpdir/metal-loader" | grep -q '/usr/lib/libobjc.A.dylib'

# Importing the public adapter must not make a Linux target silently select a
# substitute runtime.  Its platform externs remain unresolved and no artifact
# is allowed to survive that rejection.
if "$compiler" tests/macos_metal_loader_public.zag --target arm64 \
    --no-zagd --no-analyze -o "$tmpdir/not-metal" >"$tmpdir/nonmac.log" 2>&1; then
    echo "XX  Linux arm64 accepted the native Metal adapter" >&2
    exit 1
fi
test ! -e "$tmpdir/not-metal"
grep -q 'unknown function: MTLCreateSystemDefaultDevice' "$tmpdir/nonmac.log"

set +e
"$tmpdir/metal-loader" >"$tmpdir/runtime.log" 2>&1
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "XX  public Metal adapter exited $status" >&2
    cat "$tmpdir/runtime.log" >&2
    exit 1
fi

echo "  ok  std:metal_loader device capabilities and 4 KiB shared-memory roundtrip"
echo "  ok  std:metal_loader signed Mach-O bounded compute/readback/cleanup"
echo "  ok  non-macOS target fails closed without an artifact"
echo "════ macos-metal-loader pass=3 fail=0 ════"
