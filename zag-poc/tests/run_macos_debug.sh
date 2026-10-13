#!/usr/bin/env bash
# A readable DWARF section and valid signature are insufficient: every debug
# artifact must also launch and execute, both fresh and from the machine cache.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
. tests/portable.sh
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS debug: requires native Apple Silicon macOS' >&2
    exit 2
fi
compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in /*) ;; *) compiler="$root/${compiler#./}" ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-debug.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

verify_debug() {
    artifact=$1
    zag_assert_native_executable "$artifact"
    otool -l "$artifact" >"$artifact.loadcommands"
    grep -q '__DWARF' "$artifact.loadcommands"
    awk -v expected="$2" '
        $1 == "segname" { text = ($2 == "__TEXT") }
        text && $1 == "maxprot" { maximum = $2 }
        text && $1 == "initprot" { initial = $2; found = 1 }
        END { exit !(found && maximum == expected && initial == "0x00000005") }
    ' "$artifact.loadcommands"
    dwarfdump "$artifact" >"$artifact.dwarf"
    grep -q 'DW_TAG_compile_unit' "$artifact.dwarf"
    set +e
    "$artifact"
    status=$?
    set -e
    if [ "$status" -ne 42 ]; then
        echo "macOS debug: $artifact exited $status instead of 42" >&2
        return 1
    fi
}

cp tests/macos_debug_runtime.zag "$work/main.zag"
cp tests/macos_dyld_two_imports.zag "$work/imports.zag"
for source in main imports; do
    for flavor in regular hot; do
        build_flags=(--debug)
        maximum=0x00000005
        if [ "$flavor" = hot ]; then
            build_flags=(--debug --hot)
            maximum=0x00000007
        fi
        prefix="$work/$source-$flavor"
        "$compiler" "$work/$source.zag" --target macos-arm64 "${build_flags[@]}" \
            --no-zagd --no-analyze --no-foreground-cache -o "$prefix-fresh"
        verify_debug "$prefix-fresh" "$maximum"
        "$compiler" "$work/$source.zag" --target macos-arm64 "${build_flags[@]}" \
            --no-zagd --no-analyze --cache-report -o "$prefix-cold" >"$prefix-cold.log"
        verify_debug "$prefix-cold" "$maximum"
        "$compiler" "$work/$source.zag" --target macos-arm64 "${build_flags[@]}" \
            --no-zagd --no-analyze --cache-report -o "$prefix-warm" >"$prefix-warm.log"
        grep -q 'lowering_calls=0 payload_substituted=true' "$prefix-warm.log"
        verify_debug "$prefix-warm" "$maximum"
        cmp "$prefix-fresh" "$prefix-cold"
        cmp "$prefix-fresh" "$prefix-warm"
    done
done
grep -q 'LC_DYLD_INFO_ONLY' "$work/imports-regular-warm.loadcommands"
grep -q '/usr/lib/libSystem.B.dylib' "$work/imports-regular-warm.loadcommands"
echo 'macOS debug: PASS standalone+dyld regular+hot fresh+cold+warm signature+DWARF+execution'
