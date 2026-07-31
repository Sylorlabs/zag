#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
compiler=${ZNC:-"$PWD/znc"}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}";; esac
tmp=$(mktemp -d /tmp/zag-lzcnt.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" tests/x86_leading_zeros.zag -o "$tmp/app" --cpu=generic --no-zagd --no-analyze >/dev/null
set +e; "$tmp/app"; rc=$?; set -e
if [ "$rc" -ne 42 ]; then echo "x86 leading_zeros execution failed: $rc" >&2; exit 1; fi
LC_ALL=C grep -q $'\x48\x0f\xbd\xc0' "$tmp/app"
echo "x86 leading_zeros: baseline BSR execution and opcode pass"
