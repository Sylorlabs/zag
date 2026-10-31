#!/usr/bin/env bash
# Focused gate for bounded typed multi-task/result transport. It proves
# wait-many readiness/value collection, cancellation masks, and fail-closed
# validation while retaining explicit affine awaits; it does not claim generic
# futures, scheduler behavior, or portable async support.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-task-i64-wait-many.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf '%s\n' 'name = "task-i64-wait-many"' 'version = "0"' \
    'edition = "2027"' >"$tmp/project/zag.mod"
cp "$root/tests/task_i64_wait_many.zag" "$tmp/project/main.zag"
(cd "$tmp/project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o app) >"$tmp/build.log" 2>&1
test -x "$tmp/project/app"
file "$tmp/project/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/project/app" | grep -q 'statically linked'
test "$(timeout 12 "$tmp/project/app")" = \
    'task-i64-wait-many tasks=6 completed=6 masks=3 fail-closed=3'

echo 'TaskI64 wait-many: pass (typed results, cancellation mask, bounded timeout validation)'
