#!/usr/bin/env bash
# Edition 2027: passing a plain-value struct field (e.g. `s.used: i64`) to a
# generic `@consumes T` parameter instantiated with a value type copies it and
# must not report "@consumes requires named owner arguments". Owner-typed
# fields (`*T`) passed to @consumes still require a named owner.
set -u
cd "$(dirname "$0")/.."
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-consumes-field.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
mk() { mkdir -p "$WORK/$1"; printf 'name = "consumes-field"\nversion = "0"\nedition = "2027"\n' >"$WORK/$1/zag.mod"; }
good() { # dir want_rc label
    if (cd "$WORK/$1" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$WORK/$1/log" 2>&1; then
        (cd "$WORK/$1" && ./out); rc=$?
        if [ "$rc" -eq "$2" ]; then ok "$3"; else bad "$3 rc=$rc want $2"; fi
    else bad "$3 compile"; sed -n '1,6p' "$WORK/$1/log"; fi
}
mk field; cat >"$WORK/field/main.zag" <<'EOF'
@import("std:list") as list
struct SR { found: bool, used: i64, }
fn main() i32 {
    let xs: list.ArrayList[i64] = list.make[i64](4);
    let sr: SR = SR{ .found = true, .used = 7 };
    list.push[i64](&xs, sr.used);
    let r: i64 = list.get[i64](xs, 0);
    list.free[i64](&xs);
    return r as i32;
}
EOF
good field 7 "scalar struct field into push[i64]"
mk reassign; cat >"$WORK/reassign/m.zag" <<'EOF'
@import("std:list") as list
pub struct SR { found: bool, used: i64, }
pub struct Lr { xs: list.ArrayList[i64], k: i64, }
pub fn lr_free(p: @consumes *Lr) void { list.free[i64](&p.*.xs); }
pub fn search(p: @borrows_mut *Lr, n: i64) SR { p.*.k = p.*.k + 1; return SR{ .found = n > 3, .used = n }; }
pub fn run_task(p: @borrows_mut *Lr, t: i64) i64 {
    let sr: SR = SR{ .found = false, .used = 0 };
    if (t == 11) { sr = search(p, t); } else { sr = search(p, t + 1); }
    list.push[i64](&p.*.xs, sr.used);
    if (sr.found) { return list.get[i64](p.*.xs, 0) + p.*.k; }
    return 1;
}
EOF
cat >"$WORK/reassign/main.zag" <<'EOF'
@import("std:list") as list
@import("m.zag") as g
fn main() i32 {
    let l: g.Lr = g.Lr{ .xs = list.make[i64](4), .k = 0 };
    let r: i64 = g.run_task(&l, 6);
    g.lr_free(&l);
    return r as i32;
}
EOF
good reassign 8 "struct reassigned from call, field pushed (GRL-2 shape)"
mk nested; cat >"$WORK/nested/main.zag" <<'EOF'
@import("std:list") as list
struct In { v: f64, n: i64, }
struct Out { a: In, b: bool, }
fn main() i32 {
    let fs: list.ArrayList[f64] = list.make[f64](2);
    let ns: list.ArrayList[i64] = list.make[i64](2);
    let o: Out = Out{ .a = In{ .v = 2.5, .n = 4 }, .b = true };
    list.push[f64](&fs, o.a.v);
    list.push[i64](&ns, o.a.n);
    let r: i64 = (list.get[f64](fs, 0) * 2.0) as i64 + list.get[i64](ns, 0);
    list.free[f64](&fs); list.free[i64](&ns);
    return r as i32;
}
EOF
good nested 9 "nested scalar fields into push[f64]/push[i64]"
mk ownerneg; cat >"$WORK/ownerneg/main.zag" <<'EOF'
struct RawBox { ptr: *i8, }
fn dispose(ptr: @consumes *i8) void { _zag_free(ptr); }
fn main() i32 {
    let box: RawBox = RawBox{ .ptr = null as *i8 };
    dispose(box.ptr);
    return 0;
}
EOF
if (cd "$WORK/ownerneg" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$WORK/ownerneg/log" 2>&1; then
    bad "owner pointer field into @consumes *i8 unexpectedly compiled"
elif grep -q "@consumes requires named owner arguments" "$WORK/ownerneg/log"; then
    ok "owner pointer field into @consumes still rejected"
else bad "owner pointer field: wrong diagnostic"; sed -n '1,6p' "$WORK/ownerneg/log"; fi
echo "v2 consumes scalar field: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
