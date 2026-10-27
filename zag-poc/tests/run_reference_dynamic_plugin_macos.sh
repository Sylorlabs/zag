#!/usr/bin/env bash
# Apple Silicon counterpart to the Linux bounded dlopen/dlsym/call/dlclose
# reference application. The plugin is a native Mach-O dylib and the host binds
# only libSystem's dynamic-loader API; the plugin itself is discovered at run
# time and is not an LC_LOAD_DYLIB dependency of the host.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS dynamic plugin reference requires Apple Silicon macOS' >&2
    exit 2
fi

compiler=${ZNC:-"$root/znc-macos-arm64"}
case "$compiler" in /*) ;; *) compiler="$root/${compiler#./}" ;; esac
test -x "$compiler"
real_compiler=$compiler
cc_bin=${CC:-clang}
command -v "$cc_bin" >/dev/null

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-dynamic-plugin-macos.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# A freshly rebuilt compiler commonly lives in an isolated temporary directory.
# Stage its executable beside the current std/selfhost trees so absolute-source
# builds resolve imports identically from the repository and unrelated CWDs.
mkdir -p "$tmp/compiler"
# A release gate may pass a compiler wrapper with a relative znc-real sibling.
# Calling the original absolute path preserves artifact logging and avoids
# recursively executing a relocated wrapper as its own znc-real.
printf '#!/bin/bash\nexec %q "$@"\n' "$real_compiler" >"$tmp/compiler/znc"
chmod +x "$tmp/compiler/znc"
ln -s "$root/std" "$tmp/compiler/std"
ln -s "$root/selfhost" "$tmp/compiler/selfhost"
compiler="$tmp/compiler/znc"
fixture="$root/tests/reference_apps/dynamic_plugin"
library="$tmp/libzag_answer_plugin.dylib"
app="$tmp/dynamic-plugin-host"
app_repro="$tmp/dynamic-plugin-host-repro"

"$cc_bin" -arch arm64 -dynamiclib \
    -Wl,-install_name,@rpath/libzag_answer_plugin.dylib \
    "$fixture/answer_plugin.c" -o "$library"
codesign --force --sign - "$library" >/dev/null 2>&1
file -b "$library" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64'

build() {
    zag_run_bounded 180 "$compiler" "$fixture/main.zag" \
        --target macos-arm64 --dynamic --no-zagd --no-analyze \
        --no-foreground-cache -o "$1" >/dev/null
}
build "$app"
(cd /tmp && build "$app_repro")
cmp "$app" "$app_repro"
zag_assert_native_executable "$app"
codesign --verify --strict "$app"

dyld_info -opcodes "$app" >"$tmp/binds"
for symbol in dlopen dlsym dlclose; do
    grep -q "SET_SYMBOL_TRAILING_FLAGS_IMM.*_${symbol}" "$tmp/binds"
done
otool -L "$app" >"$tmp/deps"
grep -Fq '/usr/lib/libSystem.B.dylib' "$tmp/deps"
if grep -Fq 'libzag_answer_plugin' "$tmp/deps"; then
    echo 'macOS plugin host unexpectedly linked the runtime plugin eagerly' >&2
    exit 1
fi

run_success() {
    local artifact=$1
    local label=$2
    zag_run_bounded 30 "$artifact" "$library" >"$tmp/$label.out" 2>"$tmp/$label.err"
    printf 'dynamic plugin: answer=42 unloads=1\n' | cmp -s - "$tmp/$label.out"
    test ! -s "$tmp/$label.err"
}
run_success "$app" success
run_success "$app_repro" repro

set +e
zag_run_bounded 30 "$app" "$tmp/missing-plugin.dylib" >/dev/null 2>"$tmp/missing.err"
missing_status=$?
zag_run_bounded 30 "$app" "$library" definitely_missing_symbol >/dev/null 2>"$tmp/symbol.err"
symbol_status=$?
zag_run_bounded 30 "$app" "$library" invalid-symbol >/dev/null 2>"$tmp/invalid.err"
invalid_status=$?
set -e
test "$missing_status" -eq 10
test "$symbol_status" -eq 23
test "$invalid_status" -eq 21

echo 'macOS dynamic plugin reference: PASS load + resolve + call + unload + negative lifecycle'
