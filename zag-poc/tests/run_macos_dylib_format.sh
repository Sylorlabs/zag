#!/usr/bin/env bash
# Low-level writer/reader witnesses complement the production CLI suite.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then exit 2; fi
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-dylib-format.XXXXXX")
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ] || [ "${ZAG_TEST_KEEP_WORK:-0}" = 1 ]; then
        printf 'macOS dylib format: retained test artifacts: %s\n' "$work" >&2
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
for probe in writer dependency; do
    zag_run_bounded 240 "$compiler" "tests/macos_dylib_$probe.zag" --target macos-arm64 \
        --no-zagd --no-analyze --no-foreground-cache -o "$work/$probe"
done
xcrun clang -Wall -Wextra -Werror tests/fixtures/macos_dylib_loader.c -o "$work/loader"
printf 'int cabi_answer(void) { return 42; }\n' >"$work/helper.c"
for arch in arm64 x86_64; do
    xcrun clang -Wall -Wextra -Werror -arch "$arch" -dynamiclib "$work/helper.c" \
        -Wl,-install_name,@rpath/libhelper.dylib -o "$work/libhelper-$arch.dylib"
done
xcrun lipo -create "$work/libhelper-arm64.dylib" "$work/libhelper-x86_64.dylib" \
    -output "$work/libhelper-universal.dylib"
for suffix in first repeat; do
    zag_run_bounded 30 "$work/writer" "$work/$suffix.dylib" >"$work/$suffix.log" 2>&1
done
cmp "$work/first.dylib" "$work/repeat.dylib"
codesign --verify --deep --strict "$work/first.dylib"
zag_run_bounded 30 "$work/loader" "$work/first.dylib"
for library in libhelper-arm64.dylib libhelper-universal.dylib; do
    zag_run_bounded 30 "$work/dependency" "$work/$library" _cabi_answer "$work/libhelper-x86_64.dylib"
done
zag_run_bounded 30 "$work/dependency" "$work/first.dylib" _zag_answer "$work/libhelper-x86_64.dylib"
echo 'macOS dylib format: PASS native deterministic signer, 305 exports, rebase/bind, 23 invalid writer inputs, dependency validation'
