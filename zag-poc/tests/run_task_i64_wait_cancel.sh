#!/usr/bin/env bash
# Bounded cancellation-token bridge over the Linux/x86-64 TaskI64 ABI.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
grep -qF 'fn task_i64_wait_cancel(' "$root/std/task_i64.zag"
grep -qF 'task-wait-cancel preflight=1 bridge=1 success=1' \
    "$root/tests/task_i64_wait_cancel.zag"
tmp=$(mktemp -d /tmp/zag-task-i64-wait-cancel.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' 'name = "task-i64-wait-cancel"' 'version = "0"' \
    'edition = "2027"' >"$tmp/zag.mod"
cp "$root/tests/task_i64_wait_cancel.zag" "$tmp/main.zag"
(cd "$tmp" && "$compiler" main.zag --safety=checked --analyze-strict \
    --no-zagd --no-foreground-cache -o app) >"$tmp/build.log" 2>&1
test -x "$tmp/app"
file "$tmp/app" | grep -q 'ELF 64-bit LSB executable, x86-64'
file "$tmp/app" | grep -q 'statically linked'
test "$(timeout 12 "$tmp/app")" = \
    'task-wait-cancel preflight=1 bridge=1 success=1'
echo 'TaskI64 cancellation bridge: pass (token propagation, bounded wait, affine await)'
