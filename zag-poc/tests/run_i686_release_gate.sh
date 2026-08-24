#!/usr/bin/env bash
# Authoritative low-memory gate for the implemented Linux/i686 milestone.
#
# Mandatory results use only znc's ELF32 emitter, archive writer, and linker.
# readelf, objdump, host ld/ar/cc, and similar reference tools are disabled.
# Execution is native when the kernel supports i386 and otherwise uses
# qemu-i386. This certifies the documented target subset, not full language,
# public C ABI, dynamic/TLS, or ARM parity.
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-i686-authority.XXXXXX)
trap 'find "$tmp" -type f -delete; rmdir "$tmp"' EXIT

fail() {
    echo "  XX  $1" >&2
    exit 1
}

elf_identity() {
    local path=$1 expected_class=$2 expected_machine=$3
    local class machine
    class=$(od -An -tu1 -j4 -N1 "$path" | tr -d ' ')
    machine=$(od -An -tu1 -j18 -N2 "$path" | xargs)
    test "$class" = "$expected_class" || fail "$path has ELF class $class, expected $expected_class"
    test "$machine" = "$expected_machine" || fail "$path has machine $machine, expected $expected_machine"
}

i686_exec() {
    "$@" 2>"$tmp/i686-loader.stderr"
    local rc=$?
    if { [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; } && command -v qemu-i386 >/dev/null 2>&1; then
        qemu-i386 "$@"
        rc=$?
    elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
        cat "$tmp/i686-loader.stderr" >&2
        fail "i386 execution unavailable: neither native compatibility nor qemu-i386 worked"
    fi
    return "$rc"
}

reject_without_artifact() {
    local source=$1 artifact=$2 pattern=$3
    if "$ZNC" "$source" --target i686 --emit-obj -o "$artifact" --no-analyze --no-zagd >"$artifact.log" 2>&1; then
        fail "$source unexpectedly compiled"
    fi
    test ! -e "$artifact" || fail "$source left an artifact after rejection"
    grep -q "$pattern" "$artifact.log" || {
        cat "$artifact.log" >&2
        fail "$source did not report the expected bounded-target diagnostic"
    }
}

echo "════ Linux/i686 authority gate ════"
echo "Mandatory host ld/ar/cc/readelf/objdump use: disabled"

echo
echo "── [1/4] compiler and target identity"
version=$("$ZNC" version)
case "$version" in
    "znc "*" (edition "*) ;;
    *) fail "unexpected compiler identity: $version" ;;
esac
echo "  ok  compiler identity: $version"

for alias in i686 x86 linux-i686; do
    "$ZNC" tests/i686_literal.zag --target "$alias" -o "$tmp/$alias" --no-analyze --no-zagd >/dev/null
    elf_identity "$tmp/$alias" 1 "3 0"
    set +e
    i686_exec "$tmp/$alias"
    rc=$?
    set -e
    test "$rc" -eq 42 || fail "--target $alias execution status=$rc"
done
echo "  ok  i686/x86/linux-i686 select executable ELF32 EM_386"

"$ZNC" tests/i686_literal.zag --target x86_64 -o "$tmp/x86_64" --no-analyze --no-zagd >/dev/null
elf_identity "$tmp/x86_64" 2 "62 0"
echo "  ok  x86_64 remains distinct ELF64 EM_X86_64"

if "$ZNC" tests/i686_literal.zag --target unsupported-host-alias -o "$tmp/unknown" --no-analyze --no-zagd >"$tmp/unknown.log" 2>&1; then
    fail "unknown target unexpectedly compiled"
fi
test ! -e "$tmp/unknown" || fail "unknown target left an output artifact"
grep -q 'unsupported target: unsupported-host-alias' "$tmp/unknown.log" ||
    fail "unknown target did not fail closed with target identity"
echo "  ok  unknown targets cannot fall back to the 64-bit host"

echo
echo "── [2/4] ELF32, pointer/usize, scalar/aggregate/wide ABI, spills, and int-0x80 runtime"
ZAG_I686_REFERENCE_TOOLS=0 ZNC_REAL="$ZNC" ZNC=tests/i686_znc_no_zagd.sh \
    bash tests/run_i686_minimal.sh

echo
echo "── [3/4] pure-Zag object, archive, relocation, and multi-object link path"
ZAG_I686_REFERENCE_TOOLS=0 ZNC_REAL="$ZNC" ZNC=tests/i686_znc_no_zagd.sh \
    bash tests/run_i686_multi_object.sh

echo
echo "── [4/4] bounded small-register model and artifact-negative target limits"
reject_without_artifact \
    tests/i686_reject_call_area_limit.zag \
    "$tmp/call-area.o" \
    'i386 call argument area exceeds the bounded 64 KiB stack-spill limit'
echo "  ok  outgoing i386 call area fails closed above 64 KiB"
reject_without_artifact \
    tests/i686_reject_frame_limit.zag \
    "$tmp/frame.o" \
    'i386 local spill frame exceeds the bounded 1 MiB limit'
echo "  ok  local i386 spill frame fails closed above 1 MiB"

echo
echo "Certified: ELF32 EM_386; implemented SysV i386 scalar, aggregate, narrow,"
echo "wide-integer, float, slice, and error-union boundaries; 32-bit pointer/usize;"
echo "bounded stack-spill behavior; Linux int-0x80 exit/write/mmap2/munmap;"
echo "pure-Zag ET_REL/archive/multi-object linking; fail-closed target identity;"
echo "and native-or-qemu execution."
echo "Not certified: full language/public C ABI parity, dynamic/TLS linking, ARM,"
echo "or external 32-bit distribution compatibility."
echo "════ Linux/i686 authority gate: PASS ════"
