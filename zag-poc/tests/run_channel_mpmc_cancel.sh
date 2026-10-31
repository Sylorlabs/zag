#!/usr/bin/env bash
# Focused cancellation-aware waits for the bounded MPMC i64 channel.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
grep -qF 'channel_mpmc_i64_cancel_max_attempts()' \
    "$root/std/channel_mpmc_i64_cancel.zag"
grep -qF 'mpmc-cancel preflight=1' "$root/tests/channel_mpmc_i64_cancel.zag"
tmp=$(mktemp -d /tmp/zag-channel-mpmc-cancel.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
project="$tmp/project"
mkdir -p "$project"
printf '%s\n' 'name = "channel-mpmc-cancel"' 'version = "0"' \
    'edition = "2027"' >"$project/zag.mod"
cp "$root/tests/channel_mpmc_i64_cancel.zag" "$project/main.zag"
(cd "$project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o "$tmp/app") >"$tmp/build.log" 2>&1
test -x "$tmp/app"
file "$tmp/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/app" | grep -q 'statically linked'
test "$(timeout 12 "$tmp/app")" = \
    'mpmc-cancel preflight=1 send=cancelled receive=cancelled timeout=honored'
echo 'MPMC channel cancellation adapter: pass (bounded waits and cancellation)'
