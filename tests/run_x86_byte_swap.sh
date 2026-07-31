#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
compiler=${ZNC:-"$PWD/znc"}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}";; esac
tmp=$(mktemp -d /tmp/zag-bswap.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" tests/x86/x86_byte_swap.zag -o "$tmp/app" --cpu=generic --no-zagd --no-analyze >/dev/null
set +e; "$tmp/app"; rc=$?; set -e
if [ "$rc" -ne 42 ]; then echo "x86 byte_swap64 execution failed: $rc" >&2; exit 1; fi
LC_ALL=C grep -q $'\x48\x0f\xc8' "$tmp/app"
echo "x86 byte_swap64: baseline BSWAP execution and opcode pass"
