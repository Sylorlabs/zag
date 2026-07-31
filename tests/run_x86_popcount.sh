#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zag-popcount.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
compiler=${ZNC_POPCOUNT_TEST:-"$(pwd)/znc"}
"$compiler" tests/x86/x86_popcount.zag -o "$tmp/generic" --cpu=generic --no-zagd --no-analyze >/dev/null
set +e
"$tmp/generic"
generic_rc=$?
set -e
test "$generic_rc" -eq 8
if LC_ALL=C grep -q $'\xf3\x48\x0f\xb8' "$tmp/generic"; then
    echo "generic binary contains forbidden POPCNT" >&2; exit 1
fi
if grep -qm1 -E '^flags.*(^| )popcnt( |$)' /proc/cpuinfo; then
    "$compiler" tests/x86/x86_popcount.zag -o "$tmp/native" --cpu=native --no-zagd --no-analyze >/dev/null
    set +e
    "$tmp/native"
    native_rc=$?
    set -e
    test "$native_rc" -eq "$generic_rc"
    LC_ALL=C grep -q $'\xf3\x48\x0f\xb8' "$tmp/native"
fi
"$compiler" tests/x86/x86_popcount.zag -o "$tmp/runtime" --cpu=runtime --no-zagd --no-analyze >/dev/null
set +e
"$tmp/runtime"
runtime_rc=$?
set -e
test "$runtime_rc" -eq "$generic_rc"
LC_ALL=C grep -q $'\xf3\x48\x0f\xb8' "$tmp/runtime"
echo "x86 popcount differential: pass"
