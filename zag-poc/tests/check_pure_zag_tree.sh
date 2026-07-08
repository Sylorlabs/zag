#!/usr/bin/env bash
# Reject retired implementation languages and compiler paths in the current tree.
set -eu
cd "$(dirname "$0")/.."

fail=0

forbidden_files=$(find . -path './.git' -prune -o -type f \
    \( -iname '*.c' -o -iname '*.h' -o -iname '*.py' -o -iname '*.zig' \) -print)
if [ -n "$forbidden_files" ]; then
    echo "XX forbidden C/Python/Zig files in the working tree:"
    echo "$forbidden_files"
    fail=1
else
    echo "ok no C, header, Python, or Zig source files"
fi

for path in zagc selfhost/zagc.zag selfhost/codegen.zag std/runtime.c \
    run_tests.sh tests/run_selfhost.sh tests/run_selfhost_features.sh; do
    if [ -e "$path" ]; then
        echo "XX retired compiler path exists: $path"
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "ok retired compiler and oracle paths remain absent"
fi

exit "$fail"
