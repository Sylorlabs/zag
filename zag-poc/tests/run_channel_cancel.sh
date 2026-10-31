#!/usr/bin/env bash
# Focused cancellation-aware adapter for the bounded SPSC channel.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
# Keep this focused gate tied to the bounded timeout implementation rather
# than allowing an older compiler/cache to report only cancellation coverage.
grep -qF 'channel_i64_cancel_max_attempts()' "$root/std/channel_i64_cancel.zag"
grep -qF 'timeout=honored' "$root/tests/channel_i64_cancel.zag"
tmp=$(mktemp -d /tmp/zag-channel-cancel.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
project="$tmp/project"
mkdir -p "$project"
printf '%s\n' 'name = "channel-cancel"' 'version = "0"' 'edition = "2027"' >"$project/zag.mod"
cp "$root/tests/channel_i64_cancel.zag" "$project/main.zag"
(cd "$project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o "$tmp/app") >"$tmp/build.log" 2>&1
test -x "$tmp/app"
file "$tmp/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/app" | grep -q 'statically linked'
test "$(timeout 12 "$tmp/app")" = 'cancel-channel preflight=1 send=cancelled receive=cancelled timeout=honored'
echo 'channel cancellation adapter: pass (bounded SPSC wait cancellation)'
