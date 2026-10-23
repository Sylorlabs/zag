#!/usr/bin/env bash
# Normative Zag v1-core semantic checks against the native, no-C compiler.
set -u
cd "$(dirname "$0")/.."
. ./tests/portable.sh

ZNC=${ZNC:-$(zag_native_compiler "$PWD")}
ROOT=$PWD
TMP=$(mktemp -d /tmp/zag-semantics.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() {
    local name=$1 source=$2 expected=$3 binary="$TMP/$1"
    if ! "$ZNC" "$ROOT/tests/semantic/$source" -o "$binary" >"$TMP/$name.compile" 2>&1; then
        echo "  XX  $name (compile failed)"
        sed -n '1,12p' "$TMP/$name.compile"
        fail=$((fail + 1))
        return
    fi
    "$binary" >"$TMP/$name.run" 2>&1
    local actual=$?
    if [ "$actual" -eq "$expected" ]; then
        echo "  ok  $name (exit $actual)"
        pass=$((pass + 1))
    else
        echo "  XX  $name (exit $actual, expected $expected)"
        sed -n '1,12p' "$TMP/$name.run"
        fail=$((fail + 1))
    fi
}

ok_strict() {
    local name=$1 source=$2 expected=$3 binary="$TMP/$1"
    if ! "$ZNC" "$ROOT/tests/semantic/$source" -o "$binary" --analyze-strict >"$TMP/$name.compile" 2>&1; then
        echo "  XX  $name (strict compile failed)"
        sed -n '1,12p' "$TMP/$name.compile"
        fail=$((fail + 1))
        return
    fi
    "$binary" >"$TMP/$name.run" 2>&1
    local actual=$?
    if [ "$actual" -eq "$expected" ]; then
        echo "  ok  $name (strict exit $actual)"
        pass=$((pass + 1))
    else
        echo "  XX  $name (exit $actual, expected $expected)"
        sed -n '1,12p' "$TMP/$name.run"
        fail=$((fail + 1))
    fi
}

reject() {
    local name=$1 source=$2 binary="$TMP/$1"
    rm -f "$binary"
    if "$ZNC" "$ROOT/tests/semantic/$source" -o "$binary" >"$TMP/$name.compile" 2>&1 || [ -e "$binary" ]; then
        echo "  XX  $name (invalid program emitted an executable)"
        sed -n '1,12p' "$TMP/$name.compile"
        fail=$((fail + 1))
    else
        echo "  ok  $name (rejected, no executable)"
        pass=$((pass + 1))
    fi
}

# ok_out <name> <source> <expected-exit> <expected-stdout>: exact decimal output
# matters for the unsigned print routines, where a wrong (signed) lowering
# still exits 0 but prints a negative value.
ok_out() {
    local name=$1 source=$2 expected=$3 expected_out=$4 binary="$TMP/$1"
    if ! "$ZNC" "$ROOT/tests/semantic/$source" -o "$binary" >"$TMP/$name.compile" 2>&1; then
        echo "  XX  $name (compile failed)"
        sed -n '1,12p' "$TMP/$name.compile"
        fail=$((fail + 1))
        return
    fi
    "$binary" >"$TMP/$name.run" 2>&1
    local actual=$?
    local actual_out
    actual_out=$(cat "$TMP/$name.run")
    if [ "$actual" -eq "$expected" ] && [ "$actual_out" = "$expected_out" ]; then
        echo "  ok  $name (exit $actual, stdout exact)"
        pass=$((pass + 1))
    else
        echo "  XX  $name (exit $actual, expected $expected; stdout mismatch)"
        printf '      got:  %s\n' "$actual_out"
        printf '      want: %s\n' "$expected_out"
        fail=$((fail + 1))
    fi
}

echo "-- v1 core: accepted semantics --"
ok scoping-import-shadow scoping_import_shadow.zag 42
ok nested-block-shadow scoping_block_shadow.zag 41
ok capture-shadow scoping_capture_shadow.zag 42
ok numeric-types-casts types_numeric.zag 42
ok cast-followed-by-comparison cast_comparison.zag 42
ok direct-function-values direct_function_values.zag 42
ok error-propagation errors_propagation.zag 42
ok error-union-struct-storage error_union_struct_storage.zag 42
ok error-union-storage error_union_storage.zag 42
ok generic-monomorphization generics_monomorphization.zag 42
ok prefix-declaration-annotations prefix_declaration_annotations.zag 42
ok prefix-enum-pub-import prefix_enum_pub_import.zag 42
ok memory-value-pointer memory_value_pointer.zag 42
ok edge-control-values edge_control_values.zag 42
ok unsigned-numeric unsigned_numeric.zag 42
ok_out unsigned-print unsigned_print.zag 42 $'9223372036854775808\n18446744073709551615\n4000000000\n0\n-9223372036854775808'
ok_strict imported-const-flat import_const_flat.zag 42
ok_strict imported-const-qualified import_const_qualified.zag 42

echo "-- v1 core: required rejection --"
reject unknown-name reject_unknown_name.zag
reject try-outside-error-function reject_try_non_error.zag
reject dropped-error-value reject_dropped_error.zag
reject mixed-posit-arithmetic reject_mixed_posit.zag
ok hexadecimal-literal accept_hex_literal.zag 42
reject escaping-capturing-closure reject_closure_escape.zag
reject general-type-mismatch reject_type_mismatch.zag
reject prefix-enum-private-filter reject_prefix_enum_private_import.zag
reject prefix-enum-private-type-filter reject_prefix_enum_private_type.zag

if ZNC="$ZNC" bash tests/run_generic_metadata.sh; then
    pass=$((pass + 1))
else
    echo "  XX  generic-struct-metadata (source regression failed)"
    fail=$((fail + 1))
fi

echo "==== semantics pass=$pass fail=$fail known_gaps=0 ===="
[ "$fail" -eq 0 ]
