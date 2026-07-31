#!/usr/bin/env bash
# tests/run_diag.sh — regression tests for structured diagnostic output.
#
# Each tests/diag/*.zag file is a deliberately-bad Zag program that must
# trigger exactly the structured error recorded in the paired *.expected file.
#
# Usage:
#   bash tests/run_diag.sh
#
# The ONLY supported compiler is ./znc (the native ELF backend).
# ./zagc is the legacy C bootstrap and is NOT used here.
#
# Exit: 0 = all passed, 1 = at least one mismatch.
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC="${ZNC:-./znc}"

if [ ! -x "$ZNC" ]; then
    echo "run_diag: $ZNC not found or not executable" >&2
    exit 1
fi

pass=0
fail=0

for expected in tests/diag/*.expected; do
    zag="${expected%.expected}.zag"
    if [ ! -f "$zag" ]; then
        echo "  SKIP  $expected (no matching .zag file)"
        continue
    fi

    # Run znc; capture combined stdout+stderr; ignore exit code (violations exit 1)
    actual=$("$ZNC" "$zag" -o /dev/null 2>&1 | grep -v "^znc:" || true)

    if diff -q <(echo "$actual") "$expected" >/dev/null 2>&1; then
        echo "  ok    $zag"
        pass=$((pass + 1))
    else
        echo "  FAIL  $zag"
        echo "  --- expected ---"
        cat "$expected"
        echo "  --- actual ---"
        echo "$actual"
        echo "  --- diff ---"
        diff "$expected" <(echo "$actual") || true
        fail=$((fail + 1))
    fi
done

echo "════ diag pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
