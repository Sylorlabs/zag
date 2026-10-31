#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}";; esac
tmp=$(mktemp -d /tmp/zag-channel-mpmc.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
project="$tmp/project"
mkdir -p "$project"
printf '%s\n' 'name = "channel-mpmc"' 'version = "0"' 'edition = "2027"' >"$project/zag.mod"
cp tests/channel_mpmc_i64.zag "$project/main.zag"
(cd "$project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o app) >"$tmp/build.log" 2>&1
test -x "$project/app"
file "$project/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$project/app" | grep -q 'statically linked'
readelf -h "$project/app" | grep -Eq 'Type:[[:space:]]+EXEC'
readelf -h "$project/app" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
if readelf -l "$project/app" | grep -q INTERP; then exit 1; fi
if readelf -d "$project/app" 2>/dev/null | grep -q NEEDED; then exit 1; fi
timeout 10 "$project/app" >"$tmp/out" 2>"$tmp/err"
test ! -s "$tmp/out"
test ! -s "$tmp/err"
(cd "$project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o app2) >"$tmp/build2.log" 2>&1
cmp -s "$project/app" "$project/app2"
cp tests/channel_mpmc_concurrent.zag "$project/concurrent.zag"
(cd "$project" && "$compiler" concurrent.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o concurrent) >"$tmp/concurrent.log" 2>&1
test -x "$project/concurrent"
timeout 15 "$project/concurrent" >"$tmp/concurrent.out" 2>"$tmp/concurrent.err"
test ! -s "$tmp/concurrent.out"
test ! -s "$tmp/concurrent.err"
echo 'MPMC channel: pass=2 fail=0 (bounded try-only lock-free queue; 4-thread differential)'
