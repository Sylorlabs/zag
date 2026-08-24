#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
native_compiler=./znc
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) native_compiler=./znc-macos-arm64 ;;
    Linux:aarch64|Linux:arm64) native_compiler=./znc-linux-arm64 ;;
esac
compiler=${ZNC:-$native_compiler}
test -x "$compiler"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-executor.XXXXXX")
trap 'find "$tmp" -depth -delete' EXIT
"$compiler" tests/zagd_executor.zag -o "$tmp/test" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_witness.zag -o "$tmp/witness" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_slow.zag -o "$tmp/slow" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_noisy.zag -o "$tmp/noisy" --no-zagd --no-analyze >/dev/null
"$tmp/test" "$tmp/witness" "$tmp/slow" "$tmp/noisy"
echo 'zagd direct executor: pass'
