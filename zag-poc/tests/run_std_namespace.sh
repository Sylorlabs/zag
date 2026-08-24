#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/portable.sh"
ZNC="${ZNC:-$(zag_native_compiler "$ROOT")}"
case "$ZNC" in
    /*) ;;
    *) ZNC="$ROOT/${ZNC#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-std-namespace.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp "$ROOT/tests/std_namespace.zag" "$tmp/main.zag"
(cd "$tmp" && "$ZNC" main.zag -o app)
set +e
"$tmp/app"
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "  XX  compiler-owned std namespace (exit $status)"
    exit 1
fi
printf '@import("std:../escape")\nfn main() i32 { return 0; }\n' >"$tmp/escape.zag"
if "$ZNC" check "$tmp/escape.zag" >"$tmp/escape.out" 2>&1; then
    echo "  XX  std namespace traversal was accepted"
    exit 1
fi
echo "  ok  compiler-owned std namespace resolves outside the project"
echo "  ok  std namespace rejects traversal"
