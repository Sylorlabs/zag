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

echo "== rebuilding the native compiler (znc) — CC-FREE (znc builds itself) =="
# The native compiler self-bootstraps with ZERO external tools: no cc, as, ld,
# libc, or Zig. znc emits ELF directly via raw syscalls. This is the genuinely
# from-scratch path — only the CPU ISA, the ELF format, and the kernel syscalls
# sit beneath it.
if [ -x ./znc ]; then
    ./znc selfhost/native/znc.zag -o znc.new && mv -f znc.new znc
    echo "   ./znc rebuilt by ./znc — zero external tools (cc/as/ld/libc/Zig all absent)"
else
    ./zagc build selfhost/native/znc.zag && cp selfhost/native/znc.zag.out znc
    echo "   ./znc bootstrapped via ./zagc (no seed znc was present)"
fi

# Tidy intermediates.
rm -f selfhost/zagc.zag.c selfhost/zagc.zag.out \
      selfhost/native/znc.zag.c selfhost/native/znc.zag.out znc.new 2>/dev/null || true

echo "== done. Zag built Zag — zero Zig, zero LLVM. =="
echo "   ./zagc  — C-backend compiler (full language: numerics, effects, GPU MLIR; uses cc)"
echo "   ./znc   — native x86-64 compiler (Zag → ELF; CC-FREE, self-bootstrapping)"
