#!/usr/bin/env bash
# Native bounded HTTP/1.1 loopback reference service.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"

native_platform=$(zag_native_platform)
compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
target_args=()
case "$native_platform" in
    linux-arm64) target_args=(--target arm64) ;;
    macos-arm64) target_args=(--target macos-arm64) ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-http-service.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/http_service/main.zag"

build_one() {
    local output=$1
    (
        # Source-tree std: imports resolve from the checkout even when the
        # compiler under test is a staged binary in a temporary directory.
        cd "$root"
        zag_run_bounded 240 "$compiler" "$source_file" \
            "${target_args[@]}" -o "$output" \
            --no-zagd --no-analyze --no-foreground-cache
    ) >"$tmp/build.out" 2>"$tmp/build.err"
}

build_one "$tmp/http-service-a"
build_one "$tmp/http-service-b"
test -x "$tmp/http-service-a"
zag_assert_native_executable "$tmp/http-service-a"
zag_assert_native_executable "$tmp/http-service-b"
cmp -s "$tmp/http-service-a" "$tmp/http-service-b"
zag_run_bounded 30 "$tmp/http-service-a" >"$tmp/app.out" 2>"$tmp/app.err"
printf 'http service: status=200 body=42 negatives=4\n' | cmp -s - "$tmp/app.out"
test ! -s "$tmp/app.err"

echo 'HTTP service reference app: pass=6 fail=0'
