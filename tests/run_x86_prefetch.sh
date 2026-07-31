#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
compiler=${ZNC:-"$PWD/znc"}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}";; esac
tmp=$(mktemp -d /tmp/zag-prefetch.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "x86prefetch"\nversion = "0"\nedition = "2027"\n' > "$tmp/project/zag.mod"
cp tests/x86/x86_prefetch.zag "$tmp/project/main.zag"
"$compiler" "$tmp/project/main.zag" -o "$tmp/app" --cpu=generic --no-zagd --no-analyze >/dev/null
set +e; "$tmp/app"; rc=$?; set -e
if [ "$rc" -ne 42 ]; then echo "x86 prefetch execution failed: $rc" >&2; exit 1; fi
LC_ALL=C grep -q $'\x0f\x18\x88\x00\x00\x00\x00' "$tmp/app"
echo "x86 prefetch: baseline PREFETCHT0 execution and opcode pass"
