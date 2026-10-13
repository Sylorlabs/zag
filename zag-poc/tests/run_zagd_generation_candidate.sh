#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/portable.sh"
compiler=${ZNC:-$(zag_native_compiler "$root")}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-generation-candidate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" "$root/selfhost/zagd_generation_candidate_test.zag" -o "$tmp/test" --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log" >&2; exit 1; }
"$tmp/test"
if grep -Eq '_zag_exec_cmd|zagd_execute_finalist|_zag_raw_syscall' "$root/selfhost/zagd_generation_candidate.zag"; then echo 'generation candidate sandbox unexpectedly gained ambient execution primitives' >&2; exit 1; fi
echo 'zagd bounded sandboxed generation candidate authority: PASS'
