#!/usr/bin/env bash
# Native x86-64 f64: IEEE NaN comparison semantics and printing of non-finite
# values (previously NaN == NaN was true, NaN < x was true, and print_f64 of
# inf/NaN never terminated). Runs under a timeout so a regression cannot hang.
set -u
cd "$(dirname "$0")/.."
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-float-ieee.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
cat >"$WORK/cmp.zag" <<'EOF'
fn main() i32 {
    let z: f64 = 0.0;
    let n: f64 = z / z;
    let one: f64 = 1.0;
    let two: f64 = 2.0;
    let bad: i32 = 0;
    if (n == n) { bad = bad + 1; }
    if (!(n != n)) { bad = bad + 2; }
    if (n < one) { bad = bad + 4; }
    if (n <= one) { bad = bad + 8; }
    if (n > one) { bad = bad + 16; }
    if (n >= one) { bad = bad + 32; }
    if (one < n || one <= n || one > n || one >= n || one == n) { bad = bad + 64; }
    if (!(one != n)) { bad = bad + 128; }
    // ordered results must be unchanged
    if (!(one < two) || !(one <= two) || !(two > one) || !(two >= one)) { bad = bad + 256; }
    if (!(one == one) || one != one || two <= one || one >= two) { bad = bad + 512; }
    let neg0: f64 = 0.0 - z;
    if (!(neg0 == z)) { bad = bad + 1024; }
    let lt: bool = n < one;
    let eq: bool = one == one;
    if (lt || !eq) { bad = bad + 2048; }
    return bad;
}
EOF
if (cd "$WORK" && "$ZNC_BIN" cmp.zag --no-zagd --no-analyze -o cmp) >"$WORK/cmp.log" 2>&1; then
    timeout 10 "$WORK/cmp"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "f64 comparisons follow IEEE unordered semantics"; else bad "f64 comparison mask $rc"; fi
else
    bad "f64 comparison compile"; sed -n '1,12p' "$WORK/cmp.log"
fi
cat >"$WORK/pr.zag" <<'EOF'
fn main() i32 {
    let z: f64 = 0.0;
    print_f64(1.0 / z);
    print_f64(-1.0 / z);
    print_f64(z / z);
    print_f64(2.5);
    print_f64(0.0 - 0.125);
    return 0;
}
EOF
if (cd "$WORK" && "$ZNC_BIN" pr.zag --no-zagd --no-analyze -o pr) >"$WORK/pr.log" 2>&1; then
    out=$(timeout 10 "$WORK/pr"); rc=$?
    first3=$(printf '%s\n' "$out" | sed -n '1,2p' | tr '\n' ' ')
    third=$(printf '%s\n' "$out" | sed -n '3p')
    rest=$(printf '%s\n' "$out" | sed -n '4,5p' | tr '\n' ' ')
    if [ "$rc" -eq 0 ] && [ "$first3" = "inf -inf " ] && { [ "$third" = "nan" ] || [ "$third" = "-nan" ]; } && [ "$rest" = "2.5 -0.125 " ]; then
        ok "print_f64 terminates and renders inf/-inf/nan"
    else
        bad "print_f64 non-finite rc=$rc out=[$(printf '%s' "$out" | tr '\n' '|')]"
    fi
else
    bad "print_f64 compile"; sed -n '1,12p' "$WORK/pr.log"
fi
echo "float ieee nonfinite: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
