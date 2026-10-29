#!/usr/bin/env bash
# std/hashmap.zag and std/map.zag hashes are overflow/narrowing-free yet equal
# the previous wrapping formulas (edition 2026 witness), and Int64Map with keys
# beyond i32 plus long string keys work under edition-2027 checked narrowing.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZNC_BIN="${ZNC:-$ROOT/znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$ROOT/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-std-hash.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
proj() { mkdir -p "$WORK/$1"; printf 'name = "%s"\nversion = "0"\nedition = "%s"\n' "$1" "$2" >"$WORK/$1/zag.mod"; ln -s "$ROOT/std" "$WORK/$1/std"; }
build_run() { # dir label want_rc want_out
    if (cd "$WORK/$1" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$WORK/$1/log" 2>&1; then
        got=$(cd "$WORK/$1" && timeout 30 ./out 2>&1); rc=$?
        if [ "$rc" = "$3" ] && [ "$got" = "$4" ]; then ok "$2"; else bad "$2 (rc=$rc out=[$got])"; fi
    else bad "$2 (compile)"; sed -n '1,12p' "$WORK/$1/log"; fi
}
proj equiv 2026
cp "$ROOT/tests/std_hash_equivalence.zag" "$WORK/equiv/main.zag"
build_run equiv "hash formulas unchanged and Int64Map large keys (edition 2026)" 42 ""
proj v2keys 2027
cat >"$WORK/v2keys/main.zag" <<'EOF'
@import("std/hashmap.zag") as hm
fn main() i32 {
    let m: hm.HashMap[[]u8, i64] = hm.make[[]u8, i64](8, hm.hash_str, hm.eq_str);
    hm.put[[]u8, i64](&m, "a-rather-long-key-that-overflows-djb2", 7);
    let v: i64 = hm.get[[]u8, i64](m, "a-rather-long-key-that-overflows-djb2") orelse 0;
    let w: hm.Int64Map[i64] = hm.int64_make[i64](8);
    let k: i64 = 0;
    while (k < 1000) { hm.int64_put[i64](&w, 9000000000000 + k * 4294967311, k); k = k + 1; }
    let s: i64 = 0;
    k = 0;
    while (k < 1000) { s = s + (hm.int64_get[i64](w, 9000000000000 + k * 4294967311) orelse 0); k = k + 1; }
    let ints: hm.IntMap[i32] = hm.int_make[i32](8);
    hm.int_put[i32](&ints, 0 - 2147483647, 3);
    let n: i32 = hm.int_get[i32](ints, 0 - 2147483647) orelse 0;
    hm.free[[]u8, i64](&m);
    hm.int64_free[i64](&w);
    hm.int_free[i32](&ints);
    if (v == 7 && s == 499500 && n == 3) { return 42; }
    return 1;
}
EOF
build_run v2keys "large i64 / negative i32 / long string keys under edition 2027" 42 ""
echo "std hash 2027: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
