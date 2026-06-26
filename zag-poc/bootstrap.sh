#!/usr/bin/env bash
# bootstrap.sh — rebuild the Zag toolchain from the committed SEED binary.
#
# Zag is fully self-hosting: there is NO Zig and NO external compiler-generator
# in this tree. The committed `./zagc` binary is the seed. It rebuilds:
#   • itself           (the C-backend compiler)  from selfhost/*.zag
#   • ./znc            (the native x86-64 compiler) from selfhost/native/*.zag
# The C backend still shells out to `cc` (the accepted bootstrap path); the
# NATIVE compiler `znc` emits ELF with zero external tools (cc/as/ld/libc).
#
# Like every self-hosted language (Rust/Go/Zig), you bootstrap from a trusted
# seed binary — you cannot compile from absolutely nothing.
set -e
cd "$(dirname "$0")"

if [ ! -x ./zagc ]; then
    echo "bootstrap: missing seed ./zagc — restore it from git (it is the committed seed)." >&2
    exit 1
fi

echo "== rebuilding the C-backend compiler from the seed =="
./zagc build selfhost/zagc.zag
cp selfhost/zagc.zag.out zagc
echo "   ./zagc rebuilt from selfhost/zagc.zag (no Zig)"

echo "== rebuilding the native compiler (znc) =="
./zagc build selfhost/native/znc.zag
cp selfhost/native/znc.zag.out znc
echo "   ./znc rebuilt from selfhost/native/znc.zag (no Zig)"

# Tidy intermediates.
rm -f selfhost/zagc.zag.c selfhost/zagc.zag.out \
      selfhost/native/znc.zag.c selfhost/native/znc.zag.out 2>/dev/null || true

echo "== done. Zag built Zag — zero Zig, zero LLVM. =="
echo "   ./zagc  — C-backend compiler (full language: numerics, effects, GPU MLIR, ...)"
echo "   ./znc   — native x86-64 compiler (Zag → ELF, no cc/as/ld/libc)"
