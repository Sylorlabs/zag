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

# Some newer SDKs advertise arm64e.x1-macos in libSystem's TAPI stub, which
# the installed Apple linker cannot parse. Use another installed macOS SDK
# for this test's C dylib and SDK symbol lookup when that target is present.
sdk_root=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
if [ -f "$sdk_root/usr/lib/libSystem.B.tbd" ] &&
    grep -Fq 'arm64e.x1-macos' "$sdk_root/usr/lib/libSystem.B.tbd"; then
    sdk_dir=$(dirname "$sdk_root")
    compatible_sdk=
    for candidate in "$sdk_dir"/MacOSX*.sdk; do
        [ -f "$candidate/usr/lib/libSystem.B.tbd" ] || continue
        if ! grep -Fq 'arm64e.x1-macos' "$candidate/usr/lib/libSystem.B.tbd"; then
            compatible_sdk=$(cd "$candidate" && pwd -P)
            break
        fi
    done
    if [ -z "$compatible_sdk" ]; then
        echo "macOS dynamic plugin reference: no installed TAPI-compatible SDK (selected: $sdk_root)" >&2
        exit 2
    fi
    echo "macOS dynamic plugin reference: using compatible SDK $compatible_sdk" >&2
    sdk_root=$compatible_sdk
fi
export SDKROOT=$sdk_root

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-dynamic-plugin-macos.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# A freshly rebuilt compiler commonly lives in an isolated temporary directory.
# Stage its executable beside the current std/selfhost trees so absolute-source
# builds resolve imports identically from the repository and unrelated CWDs.
mkdir -p "$tmp/compiler"
ln -s "$real_compiler" "$tmp/compiler/znc"
# The compiler may be a wrapper script that resolves the real compiler RELATIVE to
# its own argv[0] (`wrapper_dir=${0%/*}; real="$wrapper_dir/znc-real"`), which is
# what the macOS release gate passes in. Staging `znc` alone therefore relocates
# the wrapper away from the `znc-real` it depends on and it exits 127. Stage
# `znc-real` here too, exactly as run_macos_zagscript_authority.sh does.
ln -s "$real_compiler" "$tmp/compiler/znc-real"
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
