#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-i686-link.XXXXXX)
trap 'find "$tmp" -type f -delete; rmdir "$tmp"' EXIT

"$ZNC" tests/i686_link_driver.zag -o "$tmp/link-driver" --no-analyze --no-zagd >/dev/null
"$tmp/link-driver" --fixtures "$tmp/entry.o" "$tmp/helper.o" "$tmp/duplicate.o" "$tmp/libhelper.a"

"$tmp/link-driver" "$tmp/multi" "$tmp/entry.o" "$tmp/helper.o"
set +e; "$tmp/multi"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  cross-object PC32 call and R_386_32 data relocation execute"

"$tmp/link-driver" "$tmp/archive" "$tmp/entry.o" "$tmp/libhelper.a"
set +e; "$tmp/archive"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  archive extracts only the first member satisfying an unresolved symbol"

if "$tmp/link-driver" "$tmp/dup" "$tmp/entry.o" "$tmp/helper.o" "$tmp/duplicate.o" >"$tmp/dup.log" 2>&1; then
    echo "  XX  duplicate definition was accepted"; exit 1
fi
grep -q 'duplicate symbol: helper' "$tmp/dup.log"
echo "  ok  duplicate global definition rejects with its symbol name"

if "$tmp/link-driver" "$tmp/missing" "$tmp/entry.o" >"$tmp/missing.log" 2>&1; then
    echo "  XX  undefined symbol was accepted"; exit 1
fi
grep -q 'undefined symbol: helper' "$tmp/missing.log"
echo "  ok  missing definition rejects with its symbol name"

echo "i686 multi-object: pass=4 fail=0"
