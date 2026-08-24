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
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-incremental.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/zagd_incremental_test.zag -o "$tmp/test" --no-zagd --no-analyze >/dev/null
"$tmp/test"
