#!/usr/bin/env bash
# Edition-2027 ownership: scalar values derived from an owned runtime string
# (nested scalar-returning calls, arithmetic over .len, element loads) and the
# copying string/file/process runtime bridges must not be reported as owner
# escapes, while real escapes stay rejected. Also covers std/map.zag free.
set -u
cd "$(dirname "$0")/.."

ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
STD_DIR="$PWD/std"
WORK="$(mktemp -d /tmp/zag-v2-owned-flow.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
project() {
    mkdir -p "$WORK/$1"
    printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$WORK/$1/zag.mod"
    ln -s "$STD_DIR" "$WORK/$1/std"
}
run_expect() {
    name="$1"; label="$2"; want_rc="$3"; want_out="$4"
    if ! (cd "$WORK/$name" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$WORK/$name/log" 2>&1; then
        bad "$label (compile)"; sed -n '1,12p' "$WORK/$name/log"; return
    fi
    got_out=$(cd "$WORK/$name" && ./out 2>&1); got_rc=$?
    if [ "$got_rc" = "$want_rc" ] && [ "$got_out" = "$want_out" ]; then
        ok "$label"
    else
        bad "$label (rc=$got_rc want=$want_rc out=[$got_out] want=[$want_out])"
    fi
}
check_reject() {
    name="$1"; label="$2"; diagnostic="$3"
    if (cd "$WORK/$name" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$WORK/$name/log" 2>&1 || [ -e "$WORK/$name/out" ]; then
        bad "$label"
    elif grep -q "$diagnostic" "$WORK/$name/log"; then
        ok "$label"
    else
        bad "$label"; sed -n '1,12p' "$WORK/$name/log"
    fi
}

project nested_scalar_call
cat >"$WORK/nested_scalar_call/main.zag" <<'EOF'
fn count_byte(s: @borrows []u8, b: u8) i32 {
    let i: i32 = 0;
    let c: i32 = 0;
    while (i < s.len) { if (s[i] == b) { c = c + 1; } i = i + 1; }
    return c;
}
fn main() i32 {
    let n: []u8 = _zag_i64_to_str(1231);
    print_i32(count_byte(n, 49));
    let rc: i32 = count_byte(n, 51) + 40;
    _zag_str_free(n);
    return rc;
}
EOF
run_expect nested_scalar_call "scalar result of a borrowed call flows into an uncontracted call" 41 "2"

project scalar_arith_index
cat >"$WORK/scalar_arith_index/main.zag" <<'EOF'
fn main() i32 {
    let s: []u8 = _zag_i64_to_str(907);
    print_i32(s.len - 1);
    print_i32(s[0] as i32);
    print_i32((s[s.len - 1] as i32) + s.len);
    _zag_str_free(s);
    return 0;
}
EOF
run_expect scalar_arith_index "arithmetic over .len and owned-slice element loads are values" 0 "$(printf '2\n57\n58')"

project builtin_scalar_bridge
cat >"$WORK/builtin_scalar_bridge/main.zag" <<'EOF'
fn main() i32 {
    let s: []u8 = _zag_i64_to_str(4142);
    print_str(s);
    print_i32(_zag_str_index_of_byte(s, 49));
    print_i32(_zag_strlen(s) + _zag_strcmp(s, "4142"));
    _zag_str_free(s);
    return 0;
}
EOF
run_expect builtin_scalar_bridge "print_str and scalar compiler bridges over an owned string" 0 "$(printf '41421\n5')"

project owned_concat
cat >"$WORK/owned_concat/main.zag" <<'EOF'
fn main() i32 {
    let a: []u8 = _zag_i64_to_str(12);
    let b: []u8 = _zag_str_concat(a, "x");
    let c: []u8 = _zag_str_concat(b, a);
    _zag_println(c);
    let at: i32 = _zag_str_index_of_byte(c, 120);
    _zag_str_free(a);
    _zag_str_free(b);
    _zag_str_free(c);
    return at;
}
EOF
run_expect owned_concat "copying concat/index bridges accept owned runtime strings" 2 "12x12"

project owned_file_roundtrip
cat >"$WORK/owned_file_roundtrip/main.zag" <<'EOF'
fn main() i32 {
    let path: []u8 = _zag_str_concat("./", "state.txt");
    let body: []u8 = _zag_i64_to_str(4242);
    if (_zag_write_file(path, body) != 0) { return 1; }
    if (_zag_file_exists(path) != 1) { return 2; }
    let got: []u8 = _zag_read_file(path);
    let same: bool = @strEq(got, body);
    _zag_str_free(got);
    _zag_str_free(body);
    _zag_str_free(path);
    if (same) { return 0; }
    return 3;
}
EOF
run_expect owned_file_roundtrip "file bridges accept owned path and content strings" 0 ""

project std_map_free
cat >"$WORK/std_map_free/main.zag" <<'EOF'
@import("std/map.zag") as smap
fn main() i32 {
    let s: smap.StringMap[i32] = smap.make[i32](4);
    smap.put[i32](&s, "alpha", 1);
    smap.put[i32](&s, "beta", 2);
    smap.put[i32](&s, "gamma", 3);
    smap.put[i32](&s, "alpha", 40);
    let a: i32 = smap.get[i32](s, "alpha") orelse 0;
    let c: i32 = smap.count[i32](s);
    smap.free[i32](&s);
    return a + c - 1;
}
EOF
run_expect std_map_free "std/map.zag StringMap builds, grows and frees under edition 2027" 42 ""

project nested_uncontracted_still_rejected
cat >"$WORK/nested_uncontracted_still_rejected/main.zag" <<'EOF'
fn retain_len(v: []u8) i32 { return v.len; }
fn main() i32 {
    let s: []u8 = _zag_i64_to_str(5);
    print_i32(retain_len(s));
    _zag_str_free(s);
    return 0;
}
EOF
check_reject nested_uncontracted_still_rejected "owner passed to an uncontracted nested callee is still rejected" 'escapes through uncontracted call `retain_len`'

project pointer_laundering_rejected
cat >"$WORK/pointer_laundering_rejected/main.zag" <<'EOF'
@import("std/rt.zag")
fn sink(v: i64) void { }
fn main() i32 {
    let s: []u8 = _zag_i64_to_str(5);
    sink((_zag_slice_ptr(s) as i64) + 0);
    _zag_str_free(s);
    return 0;
}
EOF
check_reject pointer_laundering_rejected "pointer-valued call result is not treated as a scalar snapshot" 'escapes through uncontracted call `sink`'

project concat_result_still_owned
cat >"$WORK/concat_result_still_owned/main.zag" <<'EOF'
fn main() i32 {
    let a: []u8 = _zag_str_concat("a", "b");
    _zag_println(a);
    return 0;
}
EOF
check_reject concat_result_still_owned "concat result remains an owned allocation that must be released" 'neither released nor returned'

echo "v2 owned value flow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
