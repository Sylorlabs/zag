#!/usr/bin/env bash
# _zag_u64_to_str renders values with bit 63 set as unsigned decimal, while
# _zag_i64_to_str stays signed (editions 2026 and 2027).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZNC_BIN="${ZNC:-$ROOT/znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$ROOT/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-u64-text.XXXXXX)"
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
for e in 2026 2027; do
    proj u64text$e $e
    cat >"$WORK/u64text$e/main.zag" <<'EOF'
fn main() i32 {
    let one: u64 = 1;
    let a: []u8 = _zag_u64_to_str(one << 63);
    _zag_println(a);
    _zag_str_free(a);
    let b: []u8 = _zag_u64_to_str(18446744073709551615);
    _zag_println(b);
    _zag_str_free(b);
    let c: []u8 = _zag_u64_to_str(0);
    _zag_println(c);
    _zag_str_free(c);
    let d: []u8 = _zag_i64_to_str(0 - 42);
    _zag_println(d);
    _zag_str_free(d);
    return 0;
}
EOF
    build_run u64text$e "_zag_u64_to_str is unsigned, _zag_i64_to_str signed (edition $e)" 0 "$(printf '9223372036854775808\n18446744073709551615\n0\n-42')"
done
echo "u64 text: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
