#!/usr/bin/env bash
# Focused gate for the bounded, non-consuming TaskI64 selector.  This proves
# scheduler-shaped ready selection over a fixed set while retaining the
# TaskI64 affine await boundary; it does not claim generic futures/executors.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-task-i64-select.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf '%s\n' 'name = "task-i64-select"' 'version = "0"' \
    'edition = "2027"' >"$tmp/project/zag.mod"
cp "$root/tests/task_i64_select.zag" "$tmp/project/main.zag"
(cd "$tmp/project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o app) >"$tmp/build.log" 2>&1
test -x "$tmp/project/app"
file "$tmp/project/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/project/app" | grep -q 'statically linked'
test "$(timeout 8 "$tmp/project/app")" = \
    'task-i64-select handles=3 ready=2 timeout=1'

echo 'TaskI64 selector: pass (bounded ready selection, timeout observation, affine awaits)'
