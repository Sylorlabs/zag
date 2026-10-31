#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-map.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$compiler" tests/script_map.zag -o "$tmp/map" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/map"
"$tmp/map"

"$compiler" tests/script_map_literal.zag -o "$tmp/map-literal" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/map-literal"
"$tmp/map-literal"

cat >"$tmp/map-null-context.zag" <<'ZAG'
@import("std:script_map")
fn main() i32 {
    unsafe {
    let context: *opaque = null as *opaque;
    let values: ScriptMapI32 = script_map_new(context);
    if (values.failed != 1 || values.context != null as *opaque ||
        values.keys != null as *i32 || values.values != null as *i32 ||
        values.used != null as *u8) { return 1; }
    return 0;
    }
}
ZAG
"$compiler" "$tmp/map-null-context.zag" -o "$tmp/map-null-context" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/map-null-context"

cat >"$tmp/map-mutation-null.zag" <<'ZAG'
@import("std:script_map")
fn main() i32 {
    unsafe {
    let nothing: *ScriptMapI32 = null as *ScriptMapI32;
    if (script_map_put(nothing, 1, 2) != 1) { return 1; }
    if (script_map_del(nothing, 1) != 1) { return 2; }
if (script_map_rehash(nothing, 16) != 1) { return 3; }
if (script_map_grow(nothing) != 1) { return 4; }
    return 0;
    }
}
ZAG
"$compiler" "$tmp/map-mutation-null.zag" -o "$tmp/map-mutation-null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/map-mutation-null"

cat >"$tmp/map-operation-adversarial.zag" <<'ZAG'
script;

// Every operation validates the complete bounded table state before probing.
// The sentinels prove a malformed descriptor cannot partially mutate backing
// storage while it is being rejected.
let bad_state = map();
bad_state.keys[0] = 101;
bad_state.values[0] = 202;
bad_state.used[0] = 3;
if (map_put(bad_state, 7, 70) != 1 || map_has(bad_state, 7) ||
    bad_state.failed != 1 || bad_state.keys[0] != 101 ||
    bad_state.values[0] != 202 || bad_state.used[0] != 3) { return 1; }

let bad_count = map();
bad_count.keys[0] = 303;
bad_count.values[0] = 404;
bad_count.count = 1;
if (map_del(bad_count, 7) != 1 || map_has(bad_count, 7) ||
    bad_count.failed != 1 || bad_count.keys[0] != 303 ||
    bad_count.values[0] != 404 || bad_count.used[0] != 0) { return 2; }

let bad_cap = map();
bad_cap.keys[0] = 505;
bad_cap.values[0] = 606;
bad_cap.cap = 10;
if (map_put(bad_cap, 8, 80) != 1 || map_del(bad_cap, 8) != 1 ||
    map_has(bad_cap, 8) || bad_cap.failed != 1 ||
    bad_cap.keys[0] != 505 || bad_cap.values[0] != 606 ||
    bad_cap.used[0] != 0) { return 3; }

// grow() must validate the complete descriptor before calculating cap * 2.
// These forged capacities cover the negative and above-growth-limit cases;
// the sentinels prove rejection does not touch table storage.
let bad_negative_cap = map();
bad_negative_cap.keys[0] = 707;
bad_negative_cap.values[0] = 808;
bad_negative_cap.cap = -1;
if (script_map_grow(&bad_negative_cap) != 1 ||
    bad_negative_cap.failed != 1 || bad_negative_cap.keys[0] != 707 ||
    bad_negative_cap.values[0] != 808 || bad_negative_cap.used[0] != 0) {
    return 4;
}

let bad_extreme_cap = map();
bad_extreme_cap.keys[0] = 909;
bad_extreme_cap.values[0] = 1001;
bad_extreme_cap.cap = 1048576;
if (script_map_grow(&bad_extreme_cap) != 1 ||
    bad_extreme_cap.failed != 1 || bad_extreme_cap.keys[0] != 909 ||
    bad_extreme_cap.values[0] != 1001 || bad_extreme_cap.used[0] != 0) {
    return 5;
}
return 0;
ZAG
"$compiler" "$tmp/map-operation-adversarial.zag" \
    -o "$tmp/map-operation-adversarial" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/map-operation-adversarial"

cat >"$tmp/map-get-invalid.zag" <<'ZAG'
script;
let values = map();
values.keys[0] = 707;
values.values[0] = 808;
values.count = 1;
if (map_get(values, 7) != 0) { return 1; }
return 2;
ZAG
"$compiler" "$tmp/map-get-invalid.zag" -o "$tmp/map-get-invalid" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/map-get-invalid" >"$tmp/map-get-invalid.out" 2>&1
status=$?
set -e
test "$status" -eq 1
grep -q 'Zag Script map state is invalid' "$tmp/map-get-invalid.out"

cat >"$tmp/map-clear-null.zag" <<'ZAG'
@import("std:script_map")
script;
let nothing: *ScriptMapI32 = null as *ScriptMapI32;
return script_map_clear(nothing);
ZAG
"$compiler" "$tmp/map-clear-null.zag" -o "$tmp/map-clear-null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/map-clear-null" >"$tmp/map-clear-null.out" 2>&1
status=$?
set -e
test "$status" -eq 1

cat >"$tmp/map-clear-arity.zag" <<'ZAG'
script;
let values = map();
return map_clear(values, values);
ZAG
if "$compiler" "$tmp/map-clear-arity.zag" -o "$tmp/map-clear-arity" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/map-clear-arity.out" 2>&1; then
    echo 'map_clear arity unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/map-clear-arity"
grep -q 'Zag Script map_clear expects one map' "$tmp/map-clear-arity.out"

cat >"$tmp/map-clear-user.zag" <<'ZAG'
fn map_clear(value: i32) i32 { return value + 1; }
script;
if (map_clear(41) != 42) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/map-clear-user.zag" -o "$tmp/map-clear-user" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/map-clear-user"

cat >"$tmp/nested-only.zag" <<'ZAG'
script;
if (true) {
    let nested = {3: 30, 4: 40};
    if (map_len(nested) != 2 || map_get(nested, 3) != 30 ||
        map_get(nested, 4) != 40) { return 1; }
}
return 0;
ZAG
"$compiler" "$tmp/nested-only.zag" -o "$tmp/nested-only" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/nested-only"
"$tmp/nested-only"

cat >"$tmp/bad-literal-trailing.zag" <<'ZAG'
script;
let values = {1: 10, 2: 20,};
return map_len(values);
ZAG
if "$compiler" "$tmp/bad-literal-trailing.zag" -o "$tmp/bad-literal-trailing" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-trailing.out" 2>&1; then
    echo 'map literal trailing comma unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-trailing"
grep -q 'map literal requires one or more' "$tmp/bad-literal-trailing.out"

cat >"$tmp/bad-literal-mixed.zag" <<'ZAG'
script;
let values = {"one": 1};
return 0;
ZAG
if "$compiler" "$tmp/bad-literal-mixed.zag" -o "$tmp/bad-literal-mixed" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-mixed.out" 2>&1; then
    echo 'mixed-type map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-mixed"
grep -q 'map literal requires one or more' "$tmp/bad-literal-mixed.out"

cat >"$tmp/bad-literal-empty.zag" <<'ZAG'
script;
let values = {};
return 0;
ZAG
if "$compiler" "$tmp/bad-literal-empty.zag" -o "$tmp/bad-literal-empty" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-empty.out" 2>&1; then
    echo 'empty map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-empty"
grep -q 'map literal requires one or more' "$tmp/bad-literal-empty.out"

cat >"$tmp/bad-literal-high.zag" <<'ZAG'
script;
let values = {2147483648: 1};
return 0;
ZAG
if "$compiler" "$tmp/bad-literal-high.zag" -o "$tmp/bad-literal-high" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-high.out" 2>&1; then
    echo 'out-of-range positive map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-high"
grep -q 'map literal requires one or more' "$tmp/bad-literal-high.out"

cat >"$tmp/bad-literal-low.zag" <<'ZAG'
script;
let values = {1: -2147483649};
return 0;
ZAG
if "$compiler" "$tmp/bad-literal-low.zag" -o "$tmp/bad-literal-low" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-low.out" 2>&1; then
    echo 'out-of-range negative map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-low"
grep -q 'map literal requires one or more' "$tmp/bad-literal-low.out"

for bad_name in hex_high hex_low hex_empty hex_underscores decimal_huge \
    negative_huge unary_plus double_minus dynamic_value call_value nested_value \
    container_key missing_separator double_comma duplicate_colon; do
    case "$bad_name" in
        hex_high) bad_entry='0x80000000: 1' ;;
        hex_low) bad_entry='1: -0x80000001' ;;
        hex_empty) bad_entry='0x: 1' ;;
        hex_underscores) bad_entry='0x__: 1' ;;
        decimal_huge) bad_entry='18446744073709551616: 1' ;;
        negative_huge) bad_entry='1: -18446744073709551616' ;;
        unary_plus) bad_entry='+1: 2' ;;
        double_minus) bad_entry='--1: 2' ;;
        dynamic_value) bad_entry='1: other' ;;
        call_value) bad_entry='1: map()' ;;
        nested_value) bad_entry='1: {2: 3}' ;;
        container_key) bad_entry='[1]: 2' ;;
        missing_separator) bad_entry='1: 2 3: 4' ;;
        double_comma) bad_entry='1: 2,, 3: 4' ;;
        duplicate_colon) bad_entry='1::2' ;;
    esac
    bad_source="$tmp/bad-literal-$bad_name.zag"
    bad_binary="$tmp/bad-literal-$bad_name"
    bad_output="$tmp/bad-literal-$bad_name.out"
    printf 'script;\nlet values = {%s};\nreturn 0;\n' "$bad_entry" >"$bad_source"
    if "$compiler" "$bad_source" -o "$bad_binary" \
        --no-zagd --no-analyze --no-foreground-cache >"$bad_output" 2>&1; then
        echo "malformed or out-of-range $bad_name map literal unexpectedly compiled" >&2
        exit 1
    fi
    test ! -e "$bad_binary"
    grep -q 'map literal requires one or more' "$bad_output"
done

cat >"$tmp/bad-literal-colon.zag" <<'ZAG'
script;
let values = {1 10};
return 0;
ZAG
if "$compiler" "$tmp/bad-literal-colon.zag" -o "$tmp/bad-literal-colon" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-colon.out" 2>&1; then
    echo 'map literal without colon unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-colon"
grep -q 'map literal requires one or more' "$tmp/bad-literal-colon.out"

cat >"$tmp/bad-literal-annotated.zag" <<'ZAG'
script;
let values: ScriptMapI32 = {1: 10};
return 0;
ZAG
if "$compiler" "$tmp/bad-literal-annotated.zag" -o "$tmp/bad-literal-annotated" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-annotated.out" 2>&1; then
    echo 'annotated map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-annotated"
grep -q 'map literals require a simple unannotated binding' "$tmp/bad-literal-annotated.out"

cat >"$tmp/bad-literal-inline.zag" <<'ZAG'
script;
if (true) { let values = {1: 10}; return map_get(values, 1); }
return 0;
ZAG
if "$compiler" "$tmp/bad-literal-inline.zag" -o "$tmp/bad-literal-inline" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-literal-inline.out" 2>&1; then
    echo 'same-line nested map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-literal-inline"

cat >"$tmp/multiline-literal.zag" <<'ZAG'
script;
let values = {
    1: 10,
    2: 20
};
if (map_len(values) != 2 || map_get(values, 1) != 10 || map_get(values, 2) != 20) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/multiline-literal.zag" -o "$tmp/multiline-literal" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/multiline-literal"
"$tmp/multiline-literal"

cat >"$tmp/missing.zag" <<'ZAG'
script;
let values = map();
let missing: i32 = map_get(values, 99);
return missing;
ZAG
"$compiler" "$tmp/missing.zag" -o "$tmp/missing" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/missing" >"$tmp/missing.out" 2>"$tmp/missing.err"
status=$?
set -e
test "$status" -eq 1
grep -q 'map key is absent' "$tmp/missing.err"

cat >"$tmp/delete-absent.zag" <<'ZAG'
script;
let values = map();
if (map_del(values, 99) != 1 || map_len(values) != 0 || map_failed(values) != 0) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/delete-absent.zag" -o "$tmp/delete-absent" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/delete-absent"

cat >"$tmp/bad-arity.zag" <<'ZAG'
script;
let values = map(1);
return 0;
ZAG
if "$compiler" "$tmp/bad-arity.zag" -o "$tmp/bad-arity" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-arity.out" 2>&1; then
    echo 'map constructor arity unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-arity"
grep -q 'map expects no initial values' "$tmp/bad-arity.out"

cat >"$tmp/bad-delete-arity.zag" <<'ZAG'
script;
let values = map();
let ignored: i32 = map_del(values);
return ignored;
ZAG
if "$compiler" "$tmp/bad-delete-arity.zag" -o "$tmp/bad-delete-arity" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-delete-arity.out" 2>&1; then
    echo 'map_del arity unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-delete-arity"
grep -q 'map_del expects a map and key' "$tmp/bad-delete-arity.out"

echo 'script typed i32 map and bounded literals/clear: PASS'
