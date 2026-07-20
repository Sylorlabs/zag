#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zag-tzcnt.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
compiler=${ZNC_TZCNT_TEST:-"$(pwd)/znc"}
has_tzcnt(){ LC_ALL=C grep -q $'\xf3\x48\x0f\xbc' "$1"; }
run_expect(){ set +e; "$1"; local rc=$?; set -e; test "$rc" -eq 42; }
"$compiler" tests/x86_trailing_zeros.zag -o "$tmp/generic" --cpu=generic --no-zagd --no-analyze >/dev/null
run_expect "$tmp/generic"
if has_tzcnt "$tmp/generic"; then echo "generic binary contains forbidden TZCNT" >&2; exit 1; fi
"$compiler" tests/x86_trailing_zeros.zag -o "$tmp/runtime" --cpu=runtime --no-zagd --no-analyze >/dev/null
run_expect "$tmp/runtime"
has_tzcnt "$tmp/runtime"
if grep -qm1 -E '^flags.*(^| )bmi1( |$)' /proc/cpuinfo; then
  "$compiler" tests/x86_trailing_zeros.zag -o "$tmp/native" --cpu=native --no-zagd --no-analyze >/dev/null
  run_expect "$tmp/native"
  has_tzcnt "$tmp/native"
fi
echo "x86 trailing_zeros differential: pass"
