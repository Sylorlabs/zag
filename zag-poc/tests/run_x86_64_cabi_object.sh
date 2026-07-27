#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZNC=${ZNC:-"$ROOT/znc"}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zag-cabi-object.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

printf 'name = "cabiobject"\nversion = "0"\nedition = "2027"\n' >"$TMP/zag.mod"

ok() { printf 'ok - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'not ok - %s\n' "$1" >&2; fail=$((fail + 1)); }

cp "$ROOT/tests/fixtures/cabi_object_add.zag" "$TMP/main.zag"
"$ZNC" "$TMP/main.zag" --emit-obj -o "$TMP/add.o" --no-zagd --no-foreground-cache >"$TMP/build.log" 2>&1 || bad "emit ET_REL object"
if [ -f "$TMP/add.o" ] && readelf -h "$TMP/add.o" | grep -q 'REL (Relocatable file)' && readelf -h "$TMP/add.o" | grep -q 'Advanced Micro Devices X86-64'; then ok "object is ELF64 x86-64 ET_REL"; else bad "object ELF identity"; fi
if readelf -s "$TMP/add.o" | grep -Eq 'FUNC +GLOBAL +.*zag_add_i64'; then ok "public C ABI symbol exported"; else bad "public C ABI symbol"; fi
if readelf -r "$TMP/add.o" | grep -q 'There are no relocations'; then ok "object has no relocations"; else bad "object relocation boundary"; fi
if cc -fno-pie -no-pie "$ROOT/tests/fixtures/cabi_object_harness.c" "$TMP/add.o" -o "$TMP/harness" >"$TMP/link.log" 2>&1; then
    set +e; "$TMP/harness"; rc=$?; set -e
    if [ "$rc" = 42 ]; then ok "C caller executes Zag export"; else bad "C caller exit=$rc"; fi
else
    bad "C harness links object"
fi

cp "$ROOT/tests/fixtures/cabi_object_add.zag" "$TMP/noexport.zag"
sed -i 's/@cabi_export//' "$TMP/noexport.zag"
if "$ZNC" "$TMP/noexport.zag" --emit-obj -o "$TMP/noexport.o" --no-zagd --no-foreground-cache >"$TMP/noexport.log" 2>&1; then bad "object mode rejects missing export"; else ok "object mode rejects missing export"; fi

cp "$ROOT/tests/fixtures/cabi_object_float.zag" "$TMP/float.zag"
if "$ZNC" "$TMP/float.zag" --emit-obj -o "$TMP/float.o" --no-zagd --no-foreground-cache >"$TMP/float.log" 2>&1; then bad "object mode rejects float export"; else ok "object mode rejects float export"; fi

cp "$ROOT/tests/fixtures/cabi_object_main.zag" "$TMP/export-main.zag"
if "$ZNC" "$TMP/export-main.zag" --emit-obj -o "$TMP/export-main.o" --no-zagd --no-foreground-cache >"$TMP/export-main.log" 2>&1; then bad "object mode rejects exported main"; else ok "object mode rejects exported main"; fi

printf 'x86-64-cabi-object pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
