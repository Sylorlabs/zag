#!/usr/bin/env bash
# Focused bounded collections/iteration/UTF-8 gate. This is deliberately not a
# broad Unicode, dynamic-collection, concurrency, or cross-target claim.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"
real_compiler=${ZNC:-"$root/znc"}
case "$real_compiler" in
    /*) ;;
    *) real_compiler="$root/${real_compiler#./}" ;;
esac

platform=$(zag_native_platform) || exit 2
case "$platform" in
    linux-x86_64)
        target_args=()
        artifact_description='static ELF64 x86-64'
        ;;
    macos-arm64)
        target_args=(--target macos-arm64)
        artifact_description='signed Mach-O arm64'
        ;;
    *)
        echo "Collections and Unicode: unsupported host ($platform)" >&2
        exit 2
        ;;
esac

tmp=$(mktemp -d /tmp/zag-collections-unicode.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/compiler"
ln -s "$real_compiler" "$tmp/compiler/znc"
ln -s "$root/selfhost" "$tmp/compiler/selfhost"
ln -s "$root/std" "$tmp/compiler/std"
compiler="$tmp/compiler/znc"
mkdir -p "$tmp/project" "$tmp/unrelated"
printf '%s\n' \
    'name = "collections-unicode"' \
    'version = "0"' \
    'edition = "2027"' >"$tmp/project/zag.mod"
cp "$root/tests/collections_unicode.zag" "$tmp/project/main.zag"
cp "$root/tests/script_collections_unicode.zag" "$tmp/project/script.zag"
cp "$root/tests/collections_mixed_type_bad.zag" "$tmp/project/mixed-bad.zag"

pass=0
fail=0
record() {
    local label=$1
    shift
    if "$@"; then
        echo "  ok  $label"
        pass=$((pass + 1))
    else
        echo "  XX  $label"
        fail=$((fail + 1))
    fi
}

native_executable() {
    local artifact=$1
    zag_assert_native_executable "$artifact"
}

mixed_type_diagnostic() {
    grep -qF 'expected i32, found []u8 in call to setlib__set_add' \
        "$tmp/mixed-bad.out" ||
        grep -qF 'expected i32, found []u8 in call to setlib__set_add' \
            "$tmp/mixed-bad.err"
}

for module in hashmap set range iterator utf8; do
    # Check standard modules through the public import boundary.  The root
    # edition-2026 contract intentionally rejects explicit parameter-lifetime
    # syntax in a standalone source file, while imported library declarations
    # retain that metadata for callers.  This is the path real applications
    # use and prevents a root-file-only check from testing the wrong contract.
    module_dir="$tmp/module-check-$module"
    mkdir -p "$module_dir"
    printf '%s\n' \
        'name = "module-check"' \
        'version = "0"' \
        'edition = "2026"' >"$module_dir/zag.mod"
    printf '%s\n' \
        "@import(\"std:${module}\") as checked" \
        'fn main()i32{return 0;}' >"$module_dir/main.zag"
    record "public std:${module} module type-checks" \
        zag_run_bounded 180 "$compiler" check "$module_dir/main.zag" \
            "${target_args[@]}" \
            --no-zagd --no-analyze --no-foreground-cache
done

build_native() {
    local output=$1
    (cd "$tmp/unrelated" && zag_run_bounded 300 "$compiler" \
        "$tmp/project/main.zag" -o "$output" \
        "${target_args[@]}" \
        --safety=checked --no-zagd --no-analyze --no-foreground-cache) \
        >"$output.build.out" 2>"$output.build.err"
}

if build_native "$tmp/collections-unicode"; then
    set +e
    zag_run_bounded 30 "$tmp/collections-unicode" \
        >"$tmp/native.out" 2>"$tmp/native.err"
    native_status=$?
    set -e
    printf '%s\n' 'collections-unicode-ok' >"$tmp/native.expected"
    record 'strict native corpus exits successfully' test "$native_status" -eq 0
    record 'strict native corpus emits exact output' \
        cmp -s "$tmp/native.expected" "$tmp/native.out"
    record 'strict native corpus emits no diagnostics' test ! -s "$tmp/native.err"
    record "strict native corpus is $artifact_description" \
        native_executable "$tmp/collections-unicode"
else
    echo '  XX  strict native corpus compiles'
    sed -n '1,160p' "$tmp/collections-unicode.build.out" >&2
    sed -n '1,160p' "$tmp/collections-unicode.build.err" >&2
    fail=$((fail + 1))
fi

if build_native "$tmp/collections-unicode-second"; then
    record 'unrelated-cwd rebuild is byte-identical' \
        cmp -s "$tmp/collections-unicode" "$tmp/collections-unicode-second"
else
    echo '  XX  unrelated-cwd rebuild compiles'
    sed -n '1,160p' "$tmp/collections-unicode-second.build.out" >&2
    sed -n '1,160p' "$tmp/collections-unicode-second.build.err" >&2
    fail=$((fail + 1))
fi

if (cd "$tmp/unrelated" && zag_run_bounded 240 "$compiler" \
        "$tmp/project/script.zag" -o "$tmp/script" \
        "${target_args[@]}" \
        --safety=checked --no-zagd --no-analyze --no-foreground-cache) \
        >"$tmp/script.build.out" 2>"$tmp/script.build.err"; then
    set +e
    zag_run_bounded 30 "$tmp/script" >"$tmp/script.out" 2>"$tmp/script.err"
    script_status=$?
    set -e
    if [ "$script_status" -ne 0 ]; then
        sed -n '1,80p' "$tmp/script.out" >&2
        sed -n '1,80p' "$tmp/script.err" >&2
    fi
    record 'allocation-free Script range/UTF-8 consumer executes' \
        test "$script_status" -eq 0
    record 'Script consumer emits no output or diagnostics' \
        sh -c 'test ! -s "$1" && test ! -s "$2"' \
            _ "$tmp/script.out" "$tmp/script.err"
    record "Script consumer is $artifact_description" \
        native_executable "$tmp/script"
else
    echo '  XX  allocation-free Script range/UTF-8 consumer compiles'
    sed -n '1,160p' "$tmp/script.build.out" >&2
    sed -n '1,160p' "$tmp/script.build.err" >&2
    fail=$((fail + 1))
fi

set +e
(cd "$tmp/unrelated" && zag_run_bounded 180 "$compiler" \
    "$tmp/project/mixed-bad.zag" -o "$tmp/mixed-bad" \
    "${target_args[@]}" \
    --safety=checked --no-zagd --no-analyze --no-foreground-cache) \
    >"$tmp/mixed-bad.out" 2>"$tmp/mixed-bad.err"
mixed_status=$?
set -e
record 'mixed-type set insertion is rejected' test "$mixed_status" -ne 0
record 'mixed-type rejection reports the exact expected type' mixed_type_diagnostic
record 'mixed-type rejection publishes no executable' test ! -e "$tmp/mixed-bad"

echo "Collections and Unicode: pass=$pass fail=$fail"
test "$fail" -eq 0
