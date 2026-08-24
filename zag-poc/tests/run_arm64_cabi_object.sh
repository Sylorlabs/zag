#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/tests/portable.sh"
ZNC=${ZNC:-$(zag_native_compiler "$ROOT")}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zag-arm64-cabi-object.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

ELF_TOOL=""
ELF_KIND=""
if command -v readelf >/dev/null 2>&1; then
    ELF_TOOL=$(command -v readelf)
    ELF_KIND=readelf
elif command -v llvm-objdump >/dev/null 2>&1; then
    ELF_TOOL=$(command -v llvm-objdump)
    ELF_KIND=llvm-objdump
elif command -v xcrun >/dev/null 2>&1 && xcrun --find llvm-objdump >/dev/null 2>&1; then
    ELF_TOOL=$(xcrun --find llvm-objdump)
    ELF_KIND=llvm-objdump
else
    echo "arm64-cabi-object: readelf or llvm-objdump is required" >&2
    exit 1
fi

elf_symbols() {
    if [ "$ELF_KIND" = readelf ]; then "$ELF_TOOL" -sW "$1"; else "$ELF_TOOL" --syms "$1"; fi
}

elf_relocs() {
    if [ "$ELF_KIND" = readelf ]; then "$ELF_TOOL" -rW "$1"; else "$ELF_TOOL" --reloc "$1"; fi
}

elf_defined_symbol() {
    if [ "$ELF_KIND" = readelf ]; then
        "$ELF_TOOL" -sW "$1" | grep -Eq "FUNC[[:space:]]+GLOBAL[[:space:]]+DEFAULT[[:space:]]+[0-9]+[[:space:]]+$2$"
    else
        "$ELF_TOOL" --syms "$1" | grep -Eq "[[:space:]]g[[:space:]]+F[[:space:]]+\.text.*[[:space:]]$2$"
    fi
}

elf_undefined_symbol() {
    if [ "$ELF_KIND" = readelf ]; then
        "$ELF_TOOL" -sW "$1" | grep -Eq "FUNC[[:space:]]+GLOBAL[[:space:]]+DEFAULT[[:space:]]+UND[[:space:]]+$2$"
    else
        "$ELF_TOOL" --syms "$1" | grep -Eq "\*UND\*.*[[:space:]]$2$"
    fi
}

mkdir -p "$TMP/project"
printf 'name = "arm64-cabi-object"\nversion = "0"\nedition = "2027"\n' >"$TMP/project/zag.mod"
cp "$ROOT/tests/fixtures/cabi_object_add.zag" "$TMP/project/add.zag"
cp "$ROOT/tests/fixtures/cabi_object_import.zag" "$TMP/project/import.zag"
cp "$ROOT/tests/fixtures/cabi_object_narrow.zag" "$TMP/project/narrow.zag"
cp "$ROOT/tests/fixtures/cabi_object_after_iface.zag" "$TMP/project/after_iface.zag"

"$ZNC" "$TMP/project/add.zag" --target arm64 --emit-obj \
    --no-zagd --no-analyze --no-foreground-cache -o "$TMP/add.o" \
    >"$TMP/add.log" 2>&1

test -f "$TMP/add.o"
file "$TMP/add.o" | grep -Eq 'ELF 64-bit LSB relocatable.*(ARM aarch64|AArch64)'
elf_defined_symbol "$TMP/add.o" zag_add_i64
if elf_relocs "$TMP/add.o" | grep -Eq 'R_AARCH64|R_ARM'; then
    echo "arm64-cabi-object: relocation-free object unexpectedly has relocations" >&2
    exit 1
fi
if elf_symbols "$TMP/add.o" | grep -Eq '[[:space:]]main$|[[:space:]]_start$'; then
    echo "arm64-cabi-object: process entrypoint leaked into ET_REL" >&2
    exit 1
fi

"$ZNC" "$TMP/project/import.zag" --target arm64 --emit-obj \
    --no-zagd --no-analyze --no-foreground-cache -o "$TMP/import.o" \
    >"$TMP/import.log" 2>&1
elf_relocs "$TMP/import.o" | grep -Eq 'R_AARCH64_CALL26.*cabi_mul3'
elf_undefined_symbol "$TMP/import.o" cabi_mul3

"$ZNC" "$TMP/project/narrow.zag" --target arm64 --emit-obj \
    --no-zagd --no-analyze --no-foreground-cache -o "$TMP/narrow.o" \
    >"$TMP/narrow.log" 2>&1
for symbol in zag_narrow_i8 zag_narrow_u8 zag_narrow_i16 zag_narrow_u16 \
    zag_narrow_i32 zag_narrow_u32 zag_narrow_stack; do
    elf_defined_symbol "$TMP/narrow.o" "$symbol"
done
for symbol in cabi_narrow_i8 cabi_narrow_u8 cabi_narrow_i16 cabi_narrow_u16 \
    cabi_narrow_i32 cabi_narrow_u32 cabi_narrow_stack; do
    elf_relocs "$TMP/narrow.o" | grep -Eq "R_AARCH64_CALL26.*$symbol"
done

# Interface declarations are metadata pseudo-functions and consume no encoder
# label. An export after one must still resolve to its own function entry.
if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    if "$ZNC" "$TMP/project/after_iface.zag" --target arm64 --emit-obj \
        --no-zagd --no-analyze --no-foreground-cache -o "$TMP/after_iface.o" \
        >"$TMP/after_iface.log" 2>&1; then
        echo "arm64-cabi-object: interface metadata unexpectedly accepted on Darwin" >&2
        exit 1
    fi
    test ! -e "$TMP/after_iface.o"
    grep -q 'does not yet support interface metadata declarations' "$TMP/after_iface.log"
else
    "$ZNC" "$TMP/project/after_iface.zag" --target arm64 --emit-obj \
        --no-zagd --no-analyze --no-foreground-cache -o "$TMP/after_iface.o" \
        >"$TMP/after_iface.log" 2>&1
    test -f "$TMP/after_iface.o"
    elf_defined_symbol "$TMP/after_iface.o" zag_after_iface
    if elf_symbols "$TMP/after_iface.o" | grep -q '__iface_'; then
        echo "arm64-cabi-object: interface metadata leaked into ET_REL symbols" >&2
        exit 1
    fi
fi

# Native AArch64 Linux supplies the bidirectional ABI witness. Cross-host runs
# still validate the compiler-owned ELF identity, symbol table, and relocation
# boundary; the native-hardware CI job runs this same gate with the same object.
case "$(uname -s):$(uname -m)" in
    Linux:aarch64|Linux:arm64)
        command -v cc >/dev/null 2>&1 || {
            echo "arm64-cabi-object: native AArch64 C compiler is required" >&2
            exit 1
        }
        cat >"$TMP/harness.c" <<'HARNESS'
#include <stdint.h>

extern int64_t zag_add_i64(int64_t, int64_t);
extern int64_t zag_then_c(int64_t);
extern int64_t zag_after_iface(int64_t);
extern int8_t zag_narrow_i8(int8_t);
extern uint8_t zag_narrow_u8(uint8_t);
extern int16_t zag_narrow_i16(int16_t);
extern uint16_t zag_narrow_u16(uint16_t);
extern int32_t zag_narrow_i32(int32_t);
extern uint32_t zag_narrow_u32(uint32_t);
extern uint8_t zag_narrow_stack(int64_t, int64_t, int64_t, int64_t, int64_t,
    int64_t, int64_t, int64_t, uint8_t);

int64_t cabi_mul3(int64_t value) {
    return value * 3;
}

int8_t cabi_narrow_i8(int8_t value) { return (int8_t)(value - 3); }
uint8_t cabi_narrow_u8(uint8_t value) { return (uint8_t)(value + 3); }
int16_t cabi_narrow_i16(int16_t value) { return (int16_t)(value - 300); }
uint16_t cabi_narrow_u16(uint16_t value) { return (uint16_t)(value + 300); }
int32_t cabi_narrow_i32(int32_t value) { return value - 70000; }
uint32_t cabi_narrow_u32(uint32_t value) { return value + 70000U; }
uint8_t cabi_narrow_stack(int64_t a0, int64_t a1, int64_t a2, int64_t a3,
    int64_t a4, int64_t a5, int64_t a6, int64_t a7, uint8_t tail) {
    return (uint8_t)(tail + a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7);
}

int main(void) {
    return zag_add_i64(19, 23) == 42 && zag_then_c(7) == 22 &&
        zag_after_iface(33) == 42 &&
        zag_narrow_i8(-120) == -123 && zag_narrow_u8(250) == 253 &&
        zag_narrow_i16(-32000) == -32300 && zag_narrow_u16(65000) == 65300 &&
        zag_narrow_i32(-2000000000) == -2000070000 &&
        zag_narrow_u32(4000000000U) == 4000070000U &&
        zag_narrow_stack(1, 2, 3, 4, 5, 6, 7, 8, 200) == 236 ? 42 : 1;
}
HARNESS
        cc -fno-pie -no-pie "$TMP/harness.c" "$TMP/add.o" "$TMP/import.o" \
            "$TMP/narrow.o" "$TMP/after_iface.o" -o "$TMP/harness" \
            >"$TMP/link.log" 2>&1
        set +e
        "$TMP/harness"
        rc=$?
        set -e
        if [ "$rc" -ne 42 ]; then
            echo "arm64-cabi-object: C caller exited $rc, expected 42" >&2
            exit 1
        fi
        ;;
esac

# The reserved allocator cells keep data.len at exactly 16, so this case proves
# the instruction-kind scan catches AK_DATA_ADDR independently of the byte-count
# guard. Neither unsupported form may leave a partial object behind.
for fixture in cabi_object_allocator cabi_object_data; do
    cp "$ROOT/tests/fixtures/$fixture.zag" "$TMP/project/$fixture.zag"
    if "$ZNC" "$TMP/project/$fixture.zag" --target arm64 --emit-obj \
        --no-zagd --no-analyze --no-foreground-cache -o "$TMP/$fixture.o" \
        >"$TMP/$fixture.log" 2>&1; then
        echo "arm64-cabi-object: unsupported $fixture unexpectedly compiled" >&2
        exit 1
    fi
    grep -q 'arm64 --emit-obj does not yet support compiler-owned data sections' \
        "$TMP/$fixture.log"
    test ! -e "$TMP/$fixture.o"
done

# ET_REL must not silently inherit executable or dynamic-loader state.
for flags in '--emit-obj --dynamic' \
    '--emit-obj --needed libc.so.6' \
    '--emit-obj --dynamic --needed libc.so.6'; do
    set -- $flags
    tag=$(printf '%s' "$flags" | tr ' ./-' '____')
    if "$ZNC" "$TMP/project/add.zag" --target arm64 "$@" \
        --no-zagd --no-analyze --no-foreground-cache -o "$TMP/$tag.o" \
        >"$TMP/$tag.log" 2>&1; then
        echo "arm64-cabi-object: incompatible flags unexpectedly compiled: $flags" >&2
        exit 1
    fi
    grep -q 'arm64 --emit-obj cannot be combined with --dynamic or --needed' "$TMP/$tag.log"
    test ! -e "$TMP/$tag.o"
done

# argc/argv exist only because executable startup initializes x27. Referencing
# either runtime helper from a callable ET_REL function must fail closed.
for helper in argc arg; do
    cp "$ROOT/tests/fixtures/cabi_object_$helper.zag" "$TMP/project/$helper.zag"
    if "$ZNC" "$TMP/project/$helper.zag" --target arm64 --emit-obj \
        --no-zagd --no-analyze --no-foreground-cache -o "$TMP/$helper.o" \
        >"$TMP/$helper.log" 2>&1; then
        echo "arm64-cabi-object: executable-only _zag_$helper helper unexpectedly compiled" >&2
        exit 1
    fi
    grep -q "_zag_$helper is executable-startup-only and is unavailable in object mode" "$TMP/$helper.log"
    test ! -e "$TMP/$helper.o"
done

echo "arm64-cabi-object: PASS — normalized scalar ET_REL with fail-closed mode and startup boundaries"
