#!/usr/bin/env bash
# bootstrap.sh — rebuild the supported Zag v1 compiler from its native seed.
#
# The supported path is entirely Zag-owned: ./znc reads Zag and writes a static
# x86-64 ELF directly. It does not invoke cc, as, ld, or libc. The historical
# C emitter (`./zagc`, `selfhost/codegen.zag`) is not part of this workflow.
#
# Like every self-hosted language (Rust/Go/Zig), you bootstrap from a trusted
# seed binary — you cannot compile from absolutely nothing.
set -e
cd "$(dirname "$0")"

if [ ! -x ./znc ]; then
    echo "bootstrap: native seed ./znc is missing; restore the committed seed." >&2
    echo "bootstrap: the legacy C backend is intentionally not an accepted fallback." >&2
    exit 1
fi

echo "== native bootstrap: Zag -> x86-64 ELF (no cc/as/ld/libc) =="
./znc selfhost/native/znc.zag -o znc.new
mv -f znc.new znc
echo "   ./znc rebuilt itself from selfhost/native/znc.zag"

echo "== done. Supported compiler: ./znc =="
echo "   see BOOTSTRAP.md for the legacy C differential oracle."
