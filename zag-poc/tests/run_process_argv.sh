#!/usr/bin/env bash
# Direct, shell-free argv process boundary for the Linux x86-64 runtime.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-process-argv.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

grep -qF 'process_run_argv_bounded' "$root/selfhost/std/process.zag"
grep -qF 'literal;$(printf injected)' "$root/tests/process_argv_native.zag"

"$compiler" "$root/tests/process_argv_native.zag" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/process" \
    >"$tmp/build.log" 2>&1
test -x "$tmp/process"
file "$tmp/process" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/process" | grep -q 'statically linked'
timeout 10 "$tmp/process" >"$tmp/out" 2>"$tmp/err"
test ! -s "$tmp/out"
if [[ -s "$tmp/err" ]]; then
    # GNU yes reports the expected EPIPE after the bounded capture closes.
    # No compiler/runtime diagnostic is permitted.
    grep -qx '/usr/bin/yes: standard output: Resource temporarily unavailable' "$tmp/err"
fi

echo 'direct process argv: pass (no shell expansion, bounded timeout/output, missing-exec and validation status)'
