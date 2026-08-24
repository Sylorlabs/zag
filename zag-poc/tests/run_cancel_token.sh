#!/usr/bin/env bash
# Focused Linux/x86-64 cooperative cancellation-token contract.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-cancel-token.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
project="$tmp/project"
mkdir -p "$project"
printf '%s\n' 'name = "cancel-token"' >"$project/zag.mod"
printf '%s\n' 'version = "0"' >>"$project/zag.mod"
printf '%s\n' 'edition = "2027"' >>"$project/zag.mod"
cp "$root/tests/cancel_token_i64.zag" "$project/main.zag"

(cd "$project" && "$compiler" main.zag \
    --safety=checked --analyze-strict --no-zagd --no-foreground-cache \
    -o "$tmp/app") >"$tmp/build.log" 2>&1
test -x "$tmp/app"
file "$tmp/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/app" | grep -q 'statically linked'
test "$(timeout 10 "$tmp/app")" = 'cancel-token requested=1 observed=1 one-shot=1'

(cd "$project" && "$compiler" main.zag \
    --safety=checked --analyze-strict --no-zagd --no-foreground-cache \
    -o "$tmp/app-second") >"$tmp/build-second.log" 2>&1
cmp -s "$tmp/app" "$tmp/app-second"
echo 'cancel token: pass (release/acquire one-shot cooperative cancellation)'
