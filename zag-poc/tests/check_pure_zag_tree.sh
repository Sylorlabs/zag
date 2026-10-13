#!/usr/bin/env bash
# Reject retired implementation languages and compiler paths in the current tree.
set -eu
cd "$(dirname "$0")/.."

fail=0

# These two external-loader fixtures provide independent C ABI oracles. Keep
# the exceptions exact: production compiler and runtime code remains Zag.
forbidden_files=
while IFS= read -r file; do
    case "$file" in
        ./tests/reference_apps/dynamic_plugin/answer_plugin.c|./tests/fixtures/macos_dylib_loader.c) ;;
        *) forbidden_files=$'\n'"$file"$forbidden_files ;;
    esac
done <<EOF
$(find . \( -path './.git' -o -path './build' \) -prune -o -type f \
    \( -iname '*.c' -o -iname '*.h' -o -iname '*.py' -o -iname '*.zig' -o \
       -iname '*.rs' -o -iname '*.js' -o -iname 'Cargo.toml' -o -iname 'Cargo.lock' \) -print)
EOF

if [ -n "$forbidden_files" ]; then
    echo "XX forbidden non-Zag implementation/oracle files in the working tree:"
    echo "$forbidden_files"
    fail=1
else
    echo "ok no non-Zag implementation files; only the two explicit C ABI fixtures are allowed"
fi

for path in zagc selfhost/zagc selfhost/zagc.zag selfhost/codegen.zag std/runtime.c \
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
