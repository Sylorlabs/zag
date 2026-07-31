#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zag-andn.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
compiler=${ZNC_ANDN_TEST:-"$(pwd)/znc"}
has_andn(){ od -An -tx1 -v "$1" | tr -d ' \n' | grep -q 'c4e2..f2'; }
"$compiler" tests/x86/x86_andn.zag -o "$tmp/generic" --cpu=generic --no-zagd --no-analyze >/dev/null
set +e; "$tmp/generic"; generic_rc=$?; set -e
test "$generic_rc" -eq 42
if has_andn "$tmp/generic"; then echo "generic binary contains forbidden ANDN" >&2; exit 1; fi
"$compiler" tests/x86/x86_andn.zag -o "$tmp/runtime" --cpu=runtime --no-zagd --no-analyze >/dev/null
set +e; "$tmp/runtime"; runtime_rc=$?; set -e
test "$runtime_rc" -eq "$generic_rc"
has_andn "$tmp/runtime"
if grep -qm1 -E '^flags.*(^| )bmi1( |$)' /proc/cpuinfo; then
  "$compiler" tests/x86/x86_andn.zag -o "$tmp/native" --cpu=native --no-zagd --no-analyze >/dev/null
  set +e; "$tmp/native"; native_rc=$?; set -e
  test "$native_rc" -eq "$generic_rc"
  has_andn "$tmp/native"
fi
echo "x86 ANDN differential: pass"
