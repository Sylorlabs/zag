#!/usr/bin/env bash
# Focused gate for poll-driven parent-to-child cancellation propagation over
# bounded TaskI64 handles. It does not claim background scheduling, generic
# futures, implicit destructors, portable targets, or forced cancellation.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-task-i64-scope.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf '%s\n' 'name = "task-i64-scope"' 'version = "0"' \
    'edition = "2027"' >"$tmp/project/zag.mod"
cp "$root/tests/task_i64_scope.zag" "$tmp/project/main.zag"
(cd "$tmp/project" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o app) >"$tmp/build.log" 2>&1
test -x "$tmp/project/app"
file "$tmp/project/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/project/app" | grep -q 'statically linked'
test "$(timeout 10 "$tmp/project/app")" = \
    'task-i64-scope parent=1 propagated=1 children=2 ready=2'

echo 'TaskI64 scope: pass (poll-driven propagation, bounded wait, affine child removal/await)'
