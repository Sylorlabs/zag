#!/usr/bin/env bash
# tests/run_diag.sh — regression tests for structured diagnostic output.
#
# Each tests/diag/*.zag file is a deliberately-bad Zag program that must
# trigger exactly the structured error recorded in the paired *.expected file.
#
# Usage:
#   bash tests/run_diag.sh
#
# The selected checkout-native compiler is the only supported compiler.
# Retired bootstrap implementations are not used here.
#
# Exit: 0 = all passed, 1 = at least one mismatch.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh

ZNC="${ZNC:-$(zag_native_compiler "$PWD")}"

if [ ! -x "$ZNC" ]; then
    echo "run_diag: $ZNC not found or not executable" >&2
    exit 1
fi

pass=0
fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-diag.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
case_id=0

for expected in tests/diag/*.expected; do
    zag="${expected%.expected}.zag"
    if [ ! -f "$zag" ]; then
        echo "  SKIP  $expected (no matching .zag file)"
        continue
    fi

    artifact="$tmp/out-$case_id"
    case_id=$((case_id + 1))
    set +e
    raw=$("$ZNC" "$zag" -o "$artifact" 2>&1)
    rc=$?
    set -e
    actual=$(printf '%s\n' "$raw" | sed '/^znc:/d')

    if [ "$rc" -eq 1 ] && [ ! -e "$artifact" ] && diff -q <(echo "$actual") "$expected" >/dev/null 2>&1; then
        echo "  ok    $zag"
        pass=$((pass + 1))
    else
        echo "  FAIL  $zag (exit $rc, artifact=$([ -e "$artifact" ] && echo yes || echo no))"
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
