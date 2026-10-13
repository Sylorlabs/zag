#!/usr/bin/env bash
# No dependency may disappear silently from a non-linking output mode.
# Custom dynamic/dylib success paths are covered by run_macos_dylib.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then exit 2; fi
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-link-options.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/project/src" "$work/project/vendor/helper"
printf 'name = "link-options"\nversion = "0"\nedition = "2027"\n' >"$work/manifest"
cp "$work/manifest" "$work/project/zag.mod"
cat >"$work/project/src/main.zag" <<'ZAG'
pub fn answer() i64 @cabi_export { return 42; }
fn main() i32 { return 0; }
ZAG
source="$work/project/src/main.zag"
pass=0
fail=0
build() {
    local output=$1
    shift
    zag_run_bounded 120 "$compiler" "$source" --target macos-arm64 \
        --no-zagd --no-analyze --no-foreground-cache -o "$output" \
        ${mode_args[@]+"${mode_args[@]}"} "$@"
}
reject() {
    local label=$1
    shift
    local output="$work/$mode-$label"
    if build "$output" "$@" >"$output.log" 2>&1; then
        echo "XX macOS link options: silently accepted $mode/$label" >&2
        fail=$((fail + 1))
    elif [ -e "$output" ] ||
         ! grep -Eq 'macos-arm64.*(link|needed|relocatable)|external library' "$output.log"; then
        echo "XX macOS link options: missing link diagnostic or stray artifact for $mode/$label" >&2
        sed -n '1,8p' "$output.log" >&2
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}
for mode in executable object archive; do
    case "$mode" in
        executable) mode_args=() ;;
        object) mode_args=(--emit-obj) ;;
        archive) mode_args=(--emit-static) ;;
    esac
    cp "$work/manifest" "$work/project/zag.mod"
    build "$work/$mode-baseline" >/dev/null
    reject library-attached -lnot-a-zag-library
    reject library-separated -l not-a-zag-library
    reject library-missing -l
    reject path-attached -L/not-a-zag-library-directory
    reject path-separated -L /not-a-zag-library-directory
    reject path-missing -L
    reject framework-separated -framework CoreFoundation
    reject framework-missing -framework
    reject framework-path-separated -F /not-a-framework-directory
    reject framework-path-attached -F/not-a-framework-directory
    reject framework-path-missing -F
    reject needed-separated --needed libnot-a-zag-library.dylib
    reject needed-equals --needed=libnot-a-zag-library.dylib
    reject needed-missing --needed
    printf '\n[deps]\nnative = { link = "not-a-zag-library" }\n' \
        >>"$work/project/zag.mod"
    reject ancestor-manifest
    cp "$work/project/zag.mod" "$work/project/src/zag.mod"
    reject adjacent-manifest
    rm "$work/project/src/zag.mod"
    cp "$work/manifest" "$work/project/zag.mod"
done

# A source-only dependency's path is NOT an external library search path.
printf '\n[deps]\nhelper = { path = "vendor/helper" }\n' >>"$work/project/zag.mod"
printf 'pub fn value() i64 { return 42; }\n' >"$work/project/vendor/helper/value.zag"
cat >"$work/project/src/main.zag" <<'ZAG'
@import("pkg:helper/value.zag") as helper
pub fn answer() i64 @cabi_export { return helper.value(); }
fn main() i32 { if (helper.value() == 42) { return 0; } return 1; }
ZAG
mode_args=()
build "$work/source-dependency" >/dev/null
zag_run_bounded 30 "$work/source-dependency"
mode_args=(--emit-obj)
build "$work/source-dependency.o" >/dev/null
pass=$((pass + 2))

# A linked dependency's own manifest is part of the source graph too.
cp "$work/manifest" "$work/project/vendor/helper/zag.mod"
printf '\n[deps]\nnative = { link = "not-a-zag-library" }\n' \
    >>"$work/project/vendor/helper/zag.mod"
for mode in executable object archive; do
    case "$mode" in
        executable) mode_args=() ;;
        object) mode_args=(--emit-obj) ;;
        archive) mode_args=(--emit-static) ;;
    esac
    reject imported-module-manifest
done
rm "$work/project/vendor/helper/zag.mod"

# Hot replacement must not bypass the same option/manifest validation. It
# must reject before staging any text, even without pre-existing hot metadata.
for option in -l -L -framework -F --needed --needed=libnot-a-zag-library.dylib; do
    if (cd "$work/project" && zag_run_bounded 120 "$compiler" hot-patch "$source" \
        --target macos-arm64 --no-zagd --no-analyze "$option") \
        >"$work/hot.log" 2>&1; then
        echo "XX macOS link options: hot-patch ignored $option" >&2
        fail=$((fail + 1))
    elif [ -e "$work/project/.zag_hotpatch" ] ||
         ! grep -Eq 'macos-arm64.*(link|needed)' "$work/hot.log"; then
        echo "XX macOS link options: hot-patch did not reject $option before staging" >&2
        sed -n '1,8p' "$work/hot.log" >&2
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done
printf 'macOS link options: pass=%s fail=%s (CLI, nearest manifest, source-only dependencies)\n' "$pass" "$fail"
test "$fail" -eq 0
