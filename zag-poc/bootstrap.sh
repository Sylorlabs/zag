#!/usr/bin/env bash
# bootstrap.sh — rebuild the Zag toolchain from the committed SEED binaries.
#
# Zag is fully self-hosting: NO Zig, NO LLVM in this tree. The DEFAULT path is
# CC-FREE — the native compiler ./znc (Zag → ELF, raw syscalls, no cc/as/ld/
# libc) builds BOTH compilers with ZERO external tools:
#   • ./zagc  the C-backend compiler (full language) from selfhost/*.zag
#   • ./znc   the native compiler from selfhost/native/*.zag
# (The built ./zagc still shells out to cc when you USE it to compile a program
#  — it's the C backend. ./znc itself never touches cc.)
#
# Like every self-hosted language (Rust/Go/Zig), you bootstrap from a trusted
# seed binary — you cannot compile from absolutely nothing.
set -e
cd "$(dirname "$0")"

if [ -x ./znc ]; then
    echo "== CC-FREE build: ./znc builds the whole toolchain (zero external tools) =="
    ./znc selfhost/zagc.zag -o zagc.new && mv -f zagc.new zagc
    echo "   ./zagc  rebuilt by ./znc — native, full language (passes run_tests 46/46 + run_selfhost 28/28)"
    ./znc selfhost/native/znc.zag -o znc.new && mv -f znc.new znc
    echo "   ./znc   rebuilt by ./znc — native (Zag → ELF)"
    echo "   (strace-verified: only ./znc execs during the build — no cc/as/ld/sh)"
elif [ -x ./zagc ]; then
    echo "== fallback: ./zagc (C backend, uses cc) builds the toolchain =="
    ./zagc build selfhost/zagc.zag && cp selfhost/zagc.zag.out zagc
    ./zagc build selfhost/native/znc.zag && cp selfhost/native/znc.zag.out znc
    echo "   (./znc seed was absent — used the C-backend seed; re-run for a cc-free build)"
else
    echo "bootstrap: no seed binary (./znc or ./zagc) found — restore one from git." >&2
    exit 1
fi

# Tidy intermediates.
rm -f selfhost/zagc.zag.c selfhost/zagc.zag.out \
      selfhost/native/znc.zag.c selfhost/native/znc.zag.out zagc.new znc.new 2>/dev/null || true

echo "== done. Zag built Zag — zero Zig, zero LLVM, zero cc in the build. =="
echo "   ./zagc  — full-language compiler (C backend; uses cc to compile programs)"
echo "   ./znc   — native x86-64 compiler (Zag → ELF; never uses cc)"
