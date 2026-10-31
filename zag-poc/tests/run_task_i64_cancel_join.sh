#!/usr/bin/env bash
# Focused gate for the consuming TaskI64 cancellation cleanup seam. It proves
# typed join output and invalid-handle/output paths while preserving the
# cooperative Linux x86-64 boundary; it does not claim forced cancellation or
# generic future/error transport.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-task-i64-cancel-join.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf '%s\n' 'name = "task-i64-cancel-join"' 'version = "0"' \
    'edition = "2027"' >"$tmp/project/zag.mod"
cp "$root/tests/task_i64_cancel_join.zag" "$tmp/project/main.zag"
(cd "$tmp/project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o app) >"$tmp/build.log" 2>&1
test -x "$tmp/project/app"
file "$tmp/project/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/project/app" | grep -q 'statically linked'
test "$(timeout 10 "$tmp/project/app")" = \
    'task-i64-cancel-join consumed=2 typed=1 invalid=2'

echo 'TaskI64 cancel-join: pass (consuming cleanup, typed join result, invalid paths)'
