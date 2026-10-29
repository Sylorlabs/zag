#!/usr/bin/env bash
# Edition-2027 ownership: scalar element loads from an owned RAW POINTER
# (`p[i]` with builtin scalar element type) are values, not owner escapes,
# exactly like element loads from an owned slice; pointer-typed elements,
# casts of the pointer itself and direct passes stay rejected.
set -u
cd "$(dirname "$0")/.."

ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
STD_DIR="$PWD/std"
WORK="$(mktemp -d /tmp/zag-v2-owned-ptr-index.XXXXXX)"
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
project ptr_u8_load
cat >"$WORK/ptr_u8_load/main.zag" <<'ZEOF'
fn main() i32 {
    let n: i64 = 64;
    let p: *u8 = _zag_malloc(n) as *u8;
    p[0] = 7;
    p[n - 1] = 9;
    print_i64((p[0] as i64) + (p[n - 1] as i64));
    print_i32(p[0] as i32);
    _zag_free(p as *i8);
    return 0;
}
ZEOF
run_expect ptr_u8_load "owned *u8 element loads flow into uncontracted calls" 0 "$(printf '16\n7')"

project ptr_i64_arith
cat >"$WORK/ptr_i64_arith/main.zag" <<'ZEOF'
fn twice(v: i64) i64 { return v * 2; }
fn main() i32 {
    let p: *i64 = _zag_malloc(32) as *i64;
    let i: i32 = 0;
    while (i < 4) { p[i] = (i as i64) + 1; i = i + 1; }
    let r: i64 = twice(p[0] + p[3]) + twice(p[p[0]]);
    _zag_free(p as *i8);
    return r as i32;
}
ZEOF
run_expect ptr_i64_arith "owned *i64 element arithmetic and nested index are values" 14 ""

project ptr_elem_pointer_rejected
cat >"$WORK/ptr_elem_pointer_rejected/main.zag" <<'ZEOF'
fn keep(v: *u8) i32 { return 0; }
fn main() i32 {
    let pp: **u8 = _zag_malloc(16) as **u8;
    let r: i32 = keep(pp[0]);
    _zag_free(pp as *i8);
    return r;
}
ZEOF
check_reject ptr_elem_pointer_rejected "pointer-typed element of an owned **u8 is not a scalar snapshot" 'escapes through uncontracted call `keep`'

project ptr_cast_rejected
cat >"$WORK/ptr_cast_rejected/main.zag" <<'ZEOF'
fn sink(v: i64) i64 { return v; }
fn main() i32 {
    let p: *u8 = _zag_malloc(16) as *u8;
    let r: i64 = sink((p as i64) + 0);
    _zag_free(p as *i8);
    return r as i32;
}
ZEOF
check_reject ptr_cast_rejected "the owned raw pointer itself cast to an integer is still rejected" 'escapes through uncontracted call `sink`'

project ptr_direct_rejected
cat >"$WORK/ptr_direct_rejected/main.zag" <<'ZEOF'
fn keep(v: *u8) i32 { return 0; }
fn main() i32 {
    let p: *u8 = _zag_malloc(16) as *u8;
    let r: i32 = keep(p);
    _zag_free(p as *i8);
    return r;
}
ZEOF
check_reject ptr_direct_rejected "owned raw pointer passed to an uncontracted callee is still rejected" 'escapes through uncontracted call `keep`'

echo "v2 owned ptr index: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
