#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
ZNC="${ZNC:-$(zag_native_compiler "$PWD")}"
case "$ZNC" in
    /*) ;;
    *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-gpu-isolation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$ZNC" tests/gpu_isolation.zag -o "$tmp/test"
"$tmp/test"
