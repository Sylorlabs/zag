#!/usr/bin/env bash
# bootstrap.sh — rebuild the supported Zag v1 compiler seeds from source.
#
# Produces one release artifact:
#   ./znc — native x86-64 compiler with GPU MLIR + WASM backends
#           (selfhost/native/znc.zag; mlir.zag is lean, no codegen.zag)
#
# ./znc reads Zag and writes a static x86-64 ELF, GPU MLIR, or WASM directly.
# Neither path invokes cc, as,
# ld, or libc. The historical C emitter (`./zagc`, `selfhost/codegen.zag`) is
# not part of this workflow.
#
# Like every self-hosted language (Rust/Go/Zig), you bootstrap from trusted
# seed binaries — you cannot compile from absolutely nothing.
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

echo "== done. Supported compiler: ./znc (native + gpu + wasm) =="
echo "   see BOOTSTRAP.md for the legacy C differential oracle."
