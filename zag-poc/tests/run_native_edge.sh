#!/usr/bin/env bash
# Native backend edge-case battery: unions, effects, errors, numerics, generics,
# modules, forward-decl / mutual-recursion stress. Runs alongside run_native.sh.
cd "$(dirname "$0")/.."    # zag-poc root
pass=0; fail=0

ZNC=${ZNC:-}
if [ -z "$ZNC" ] || [ ! -x "$ZNC" ]; then
    if ! ./znc selfhost/native/znc.zag -o /tmp/znc_drv >/tmp/zne_build 2>&1; then
        echo "  XX  znc driver build"; sed -n '1,20p' /tmp/zne_build
        echo "════ native-edge pass=0 fail=1 ════"; exit 1
    fi
    ZNC=/tmp/znc_drv
fi

# nt <name> <source> <expected-exit>
nt(){
    printf '%s' "$2" > nt_edge.zag
    "$ZNC" nt_edge.zag -o /tmp/nt_edge_bin >/tmp/nt_edge_out 2>&1
    if [ ! -x /tmp/nt_edge_bin ]; then echo "  XX  $1 (compile failed)"; sed -n '1,8p' /tmp/nt_edge_out; fail=$((fail+1)); return; fi
    /tmp/nt_edge_bin; local got=$?
    if [ "$got" = "$3" ]; then echo "  ok  $1 (exit $got)"; pass=$((pass+1));
    else echo "  XX  $1 (got $got, want $3)"; fail=$((fail+1)); fi
    rm -f /tmp/nt_edge_bin
}

# nto <name> <source> <expected-stdout> <expected-exit>
nto(){
    printf '%s' "$2" > nt_edge.zag
    "$ZNC" nt_edge.zag -o /tmp/nt_edge_bin >/tmp/nt_edge_out 2>&1
    if [ ! -x /tmp/nt_edge_bin ]; then echo "  XX  $1 (compile failed)"; sed -n '1,6p' /tmp/nt_edge_out; fail=$((fail+1)); return; fi
    local got; got=$(/tmp/nt_edge_bin); local ec=$?
    if [ "$got" = "$3" ] && [ "$ec" = "$4" ]; then echo "  ok  $1 (stdout='$got' exit=$ec)"; pass=$((pass+1));
    else echo "  XX  $1 (got stdout='$got' exit=$ec, want '$3'/$4)"; fail=$((fail+1)); fi
    rm -f /tmp/nt_edge_bin
}

# reject <name> <source> <grep-pattern>
reject(){
    printf '%s' "$2" > nt_edge.zag
    rm -f /tmp/nt_edge_bin
    "$ZNC" nt_edge.zag -o /tmp/nt_edge_bin >/tmp/nt_edge_out 2>&1
    if [ ! -x /tmp/nt_edge_bin ] && grep -qiE "$3" /tmp/nt_edge_out; then
        echo "  ok  $1 (rejected)"; pass=$((pass+1));
    else
        echo "  XX  $1 (should reject)"; sed -n '1,8p' /tmp/nt_edge_out; fail=$((fail+1)); fi
    rm -f /tmp/nt_edge_bin
}

echo "── edge: unions (scalar/slice, nested, switch expr/stmt, capture reuse) ──"
nt  "union scalar arm" \
    'union U { n: i32, s: []u8 } fn main() i32 { let u: U = U{ .n = 42 }; return switch (u) { .n => |v| v, .s => |s| s.len }; }' 42
nt  "union slice arm len" \
    'union U { n: i32, s: []u8 } fn main() i32 { let u: U = U{ .s = "abcd" }; return switch (u) { .n => |v| 0, .s => |s| s.len }; }' 4
nt  "union capture reuse scalar/slice" \
    'union U { n: i32, s: []u8 } fn main() i32 { let u: U = U{ .s = "hi" }; return switch (u) { .n => |x| x, .s => |x| x.len }; }' 2
nt  "union capture reuse struct arms" \
    'struct A { v: i32 } struct B { n: i32 } union U { a: A, b: B } fn main() i32 { let u: U = U{ .b = B{ .n = 42 } }; return switch (u) { .a => |x| x.v, .b => |x| x.n }; }' 42
nt  "nested union in struct" \
    'struct Inner { v: i32 } union Node { leaf: Inner, num: i32 } fn main() i32 { let n: Node = Node{ .leaf = Inner{ .v = 42 } }; return switch (n) { .leaf => |x| x.*.v, .num => |v| v }; }' 42
nt  "switch stmt union side effect" \
    'union U { a: i32, b: i32 } fn main() i32 { let u: U = U{ .b = 7 }; let r: i32 = 0; switch (u) { .a => |x| { r = x; } .b => |x| { r = x; } } return r; }' 7

echo "── edge: effects (@pure/@noalloc/@realtime violation rejects) ──"
reject "reject @pure + IO" \
    'extern fn print_str(s: []u8) void @io; fn bad() void @pure { print_str("x"); } fn main() i32 { return 0; }' \
    'E0002|violation|aborted'
reject "reject @noalloc + zalloc" \
    'fn bad(n: i32) void @noalloc { let p: []i32 = zalloc_i(n); } fn main() i32 { return 0; }' \
    'E0002|violation|aborted'
reject "reject @realtime + IO" \
    'fn bad() void @realtime { print_str("x"); } fn main() i32 { return 0; }' \
    'E0002|violation|aborted'

echo "── edge: error unions (!T try/catch, code distinctness) ──"
nt  "error catch success" \
    'error { Err } fn ok() !i32 { return 42; } fn main() i32 { return ok() catch 0; }' 42
nt  "error catch |e| on err" \
    'error { Err } fn bad() !i32 { return error.Err; } fn main() i32 { return bad() catch |e| e; }' 1
nt  "error try propagate ok" \
    'error { Err } fn step() !i32 { return 5; } fn run() !i32 { let x: i32 = try step(); return x * 2; } fn main() i32 { return run() catch 0; }' 10
nt  "error try propagate err" \
    'error { Err } fn step() !i32 { return error.Err; } fn run() !i32 { let x: i32 = try step(); return x * 2; } fn main() i32 { return run() catch 9; }' 9
nt  "error three distinct codes" \
    'error { X, Y, Z } fn pick(n: i32) !i32 { if (n == 0) { return error.X; } if (n == 1) { return error.Y; } return error.Z; } fn main() i32 { let a: i32 = pick(0) catch |e| e; let b: i32 = pick(1) catch |e| e; let c: i32 = pick(2) catch |e| e; if (a != b && b != c && a != c) { return 42; } return 0; }' 42
nt  "error nested try/catch" \
    'error { E } fn inner() !i32 { return error.E; } fn outer() !i32 { let v: i32 = try inner(); return v; } fn main() i32 { return outer() catch |e| e; }' 1

echo "── edge: numerics (i32/u32 wrap, sat_i8 clamp edges) ──"
nto "i32 INT_MAX+1 wrap" \
    'fn main() i32 { let x: i32 = 2147483647; print_i32(x + 1); return 0; }' "-2147483648" 0
nto "u32 MAX literal" \
    'fn main() i32 { let x: u32 = 4294967295; print_u64(x as u64); return 0; }' "4294967295" 0
nto "u32 MAX+1 wraps to 0" \
    'fn main() i32 { let x: u32 = 4294967295; let y: u32 = x + 1; print_i32(y as i32); return 0; }' "0" 0
nt  "sat_i8 max+1 clamps" \
    'fn main() i32 { let a: sat_i8 = 127; let b: sat_i8 = 1; return a + b; }' 127
nt  "sat_i8 min-1 clamps" \
    'fn main() i32 { let a: sat_i8 = 0 - 128; let b: sat_i8 = 0 - 1; return a + b; }' 128
nt  "sat_i8 sub floor" \
    'fn main() i32 { let a: sat_i8 = 0 - 128; let b: sat_i8 = 1; return a - b; }' 128

echo "── edge: generics (inferred vs explicit, inference failure) ──"
nt  "generic inferred let" \
    'fn id[T](x: T) T { return x; } fn main() i32 { let a: i32 = id(40); let b: i32 = id(2); return a + b; }' 42
nt  "generic explicit targs" \
    'fn id[T](x: T) T { return x; } fn main() i32 { return id[i32](40) + id[i32](2); }' 42
reject "reject generic inference fail (mixed args)" \
    'fn pair[A, B](a: A, b: B) A { return a; } fn main() i32 { return pair(1, "x"); }' \
    'could not infer|aborted'
reject "reject generic inference fail (unbound T)" \
    'fn cast[T](x: i32) T { return x; } fn main() i32 { return cast(1); }' \
    'could not infer|aborted'

echo "── edge: modules (pub/private, circular import) ──"
rm -f /tmp/nt_edge_bin
"$ZNC" tests/module_system/main.zag -o /tmp/nt_edge_bin >/tmp/nt_edge_out 2>&1
if [ -x /tmp/nt_edge_bin ]; then
    got=$(/tmp/nt_edge_bin)
    if [ "$got" = "7" ]; then echo "  ok  module pub fn accessible"; pass=$((pass+1));
    else echo "  XX  module pub fn (got '$got', want 7)"; fail=$((fail+1)); fi
else echo "  XX  module pub fn compile failed"; sed -n '1,6p' /tmp/nt_edge_out; fail=$((fail+1)); fi
rm -f /tmp/nt_edge_bin

rm -f /tmp/nt_edge_bin
"$ZNC" tests/module_system/private_access.zag -o /tmp/nt_edge_bin >/tmp/nt_edge_out 2>&1
if [ ! -x /tmp/nt_edge_bin ]; then echo "  ok  module private symbol rejected"; pass=$((pass+1));
else echo "  XX  module private symbol should reject"; fail=$((fail+1)); fi
rm -f /tmp/nt_edge_bin

rm -f /tmp/nt_edge_bin
"$ZNC" tests/module_system/circ_main.zag -o /tmp/nt_edge_bin >/tmp/nt_edge_out 2>&1
if grep -qiE 'circular.*import|E0011' /tmp/nt_edge_out && [ ! -x /tmp/nt_edge_bin ]; then
    echo "  ok  circular import rejected"; pass=$((pass+1));
else echo "  XX  circular import should reject"; sed -n '1,6p' /tmp/nt_edge_out; fail=$((fail+1)); fi
rm -f /tmp/nt_edge_bin

echo "── edge: forward decl + mutual recursion stress ──"
nt  "forward decl only" \
    'fn later() i32; fn main() i32 { return 0; }' 0
nt  "mutual recursion even/odd" \
    'fn even(n: i32) i32; fn odd(n: i32) i32 { if (n == 0) { return 0; } return even(n - 1); } fn even(n: i32) i32 { if (n == 0) { return 1; } return odd(n - 1); } fn main() i32 { return even(10); }' 1
nt  "forward decl chain a→b→c" \
    'fn c() i32; fn b() i32 { return c(); } fn a() i32 { return b(); } fn c() i32 { return 42; } fn main() i32 { return a(); }' 42
nt  "mutual recursion fib-like" \
    'fn bar() i32; fn foo() i32 { return bar(); } fn bar() i32 { return 42; } fn main() i32 { return foo(); }' 42

rm -f nt_edge.zag
echo "════ native-edge pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]