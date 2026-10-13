#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS OS services: unsupported host (requires Apple Silicon macOS)' >&2
    exit 2
fi

compiler=${ZNC:-./znc-macos-arm64}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
test -x "$compiler"

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-os-macos.XXXXXX")
trap 'rm -rf "$work"' EXIT
printf '%s\n' 'macOS native clone payload' >"$work/source.txt"

build() {
    zag_run_bounded 180 "$compiler" tests/os_macos_services.zag \
        --target macos-arm64 --dynamic --no-zagd --no-analyze \
        --no-foreground-cache -o "$1" >/dev/null
}

build "$work/os-macos-services"
build "$work/os-macos-services-repeat"
cmp "$work/os-macos-services" "$work/os-macos-services-repeat"
zag_assert_native_executable "$work/os-macos-services"
codesign --verify --strict "$work/os-macos-services"

dyld_info -opcodes "$work/os-macos-services" >"$work/binds"
for symbol in clock_gettime arc4random_buf mach_continuous_time clonefile; do
    grep -q "SET_SYMBOL_TRAILING_FLAGS_IMM.*_${symbol}" "$work/binds"
done
otool -L "$work/os-macos-services" >"$work/deps"
grep -Fq '/usr/lib/libSystem.B.dylib' "$work/deps"

set +e
zag_run_bounded 15 "$work/os-macos-services" \
    "$work/source.txt" "$work/cloned.txt"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
    echo "macOS OS services witness returned $rc" >&2
    exit 1
fi
cmp "$work/source.txt" "$work/cloned.txt"

echo 'macOS OS services: PASS clock + secure entropy + continuous-time + clonefile'
