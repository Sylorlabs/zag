#!/usr/bin/env bash
# Statement switch arms with block bodies accept an optional trailing comma
# (`.A => { ... },`) in both editions, and the arm after it still dispatches.
set -u
cd "$(dirname "$0")/.."
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-switch-comma.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
for edition in 2026 2027; do
    d="$WORK/e$edition"; mkdir -p "$d"
    printf 'name = "switch-comma"\nversion = "0"\nedition = "%s"\n' "$edition" >"$d/zag.mod"
    cat >"$d/main.zag" <<'EOF'
enum Kind { Leaf, Add, Mul }
union Val { int: i64, flag: bool }
fn code(k: Kind) i32 {
    let r: i32 = 0;
    switch (k) {
        .Leaf => { r = 1; },
        .Add => { r = 2; },
        .Mul => { r = 3; },
    }
    return r;
}
fn pick(v: Val) i64 {
    let r: i64 = 0;
    switch (v) {
        .int => |x| { r = x; },
        .flag => |f| { if (f) { r = 1; } },
    }
    return r;
}
fn bucket(n: i32) i32 {
    let r: i32 = 0;
    switch (n) {
        1, 2 => { r = 10; },
        else => { r = 20; },
    }
    return r;
}
fn main() i32 {
    let total: i64 = (code(Kind.Leaf) + code(Kind.Add) + code(Kind.Mul)) as i64;
    total = total + pick(Val{ .int = 5 }) + pick(Val{ .flag = true });
    total = total + (bucket(2) + bucket(7)) as i64;
    return total as i32;
}
EOF
    if (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1; then
        (cd "$d" && ./out); rc=$?
        if [ "$rc" -eq 42 ]; then ok "edition $edition block arms with trailing commas"; else bad "edition $edition rc=$rc want 42"; fi
    else
        bad "edition $edition compile"; sed -n '1,12p' "$d/log"
    fi
done
echo "switch block arm comma: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
