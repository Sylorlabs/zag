#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf /tmp/zag_std_namespace
mkdir -p /tmp/zag_std_namespace
cp "$ROOT/tests/std_namespace.zag" /tmp/zag_std_namespace/main.zag
(cd /tmp/zag_std_namespace && "$ROOT/znc" main.zag -o app)
set +e
/tmp/zag_std_namespace/app
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "  XX  compiler-owned std namespace (exit $status)"
    exit 1
fi
if "$ROOT/znc" check <(printf '@import("std:../escape") fn main() i32 { return 0; }') >/tmp/zag_std_escape.out 2>&1; then
    echo "  XX  std namespace traversal was accepted"
    exit 1
fi
echo "  ok  compiler-owned std namespace resolves outside the project"
echo "  ok  std namespace rejects traversal"
