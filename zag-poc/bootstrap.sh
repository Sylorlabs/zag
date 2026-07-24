#!/usr/bin/env bash
# bootstrap.sh — rebuild the supported Zag v1 compiler seeds from source.
#
# Produces the compiler and its automatic, correctness-independent planner:
#   ./znc — native x86-64 compiler with GPU MLIR + WASM backends
#           (selfhost/native/znc.zag)
#
# ./znc reads Zag and writes a static x86-64 ELF, GPU MLIR, or WASM directly.
# No path invokes Python, C, Zig, cc, as, ld, or libc.
#
# Like every self-hosted language, you bootstrap from trusted
# seed binaries — you cannot compile from absolutely nothing.
set -e
cd "$(dirname "$0")"

if [ ! -x ./znc ]; then
    echo "bootstrap: native seed ./znc is missing; restore the committed seed." >&2
    echo "bootstrap: no non-Zag fallback exists; restore the committed znc seed." >&2
    exit 1
fi

echo "== native bootstrap: Zag -> x86-64 ELF (no cc/as/ld/libc) =="
./znc selfhost/native/znc.zag -o znc.new --no-foreground-cache
mv -f znc.new znc
echo "   ./znc rebuilt itself from selfhost/native/znc.zag"

./znc selfhost/zagd_daemon.zag -o zagd.new --no-analyze --no-zagd
chmod +x zagd.new
mv -f zagd.new zagd
echo "   ./zagd built from selfhost/zagd_daemon.zag"

echo "== done. Supported compiler: ./znc; automatic planner: ./zagd =="
echo "   retired bootstrap implementations are available only through Git history."
