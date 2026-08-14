#!/usr/bin/env bash
# Normative Zag v1-core semantic checks against the native, no-C compiler.
set -u
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
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

echo "==== semantics pass=$pass fail=$fail known_gaps=0 ===="
[ "$fail" -eq 0 ]
