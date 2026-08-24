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
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-core.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$compiler" tests/zagd_core.zag -o "$tmp/zagd_core" --no-zagd --no-analyze
"$tmp/zagd_core"
"$compiler" selfhost/zagd_store_test.zag -o "$tmp/zagd_store_test" --no-zagd --no-analyze
"$tmp/zagd_store_test"
"$compiler" tests/raw_fs_syscall_adapter.zag -o "$tmp/raw_fs_syscall_adapter" --no-zagd --no-analyze
set +e
"$tmp/raw_fs_syscall_adapter"
raw_fs_status=$?
set -e
test "$raw_fs_status" -eq 42
echo "zagd core pass"
