#!/usr/bin/env bash
# AArch64 Linux backend suite: compile Zag to static EM_AARCH64 ELF, run via
# qemu-user — or natively when the host is already aarch64 (real-hardware CI).
cd "$(dirname "$0")/.."    # zag-poc root
pass=0; fail=0
WORK="/tmp/zag_native_arm64_$$"
SRC="nt_src_arm64_$$.zag"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"; rm -f "$SRC"' EXIT

if [ "$(uname -m)" = "aarch64" ]; then
    QEMU=""     # native execution: "$QEMU" prog expands to prog
else
    QEMU="${QEMU:-qemu-aarch64-static}"
    if ! command -v "$QEMU" >/dev/null 2>&1; then
        echo "  XX  $QEMU not found (apt install qemu-user-static)"; exit 1
    fi
fi

if [ -z "${ZNC:-}" ]; then
    if ! ./znc selfhost/native/znc.zag -o "$WORK/znc_drv" >"$WORK/zn_build" 2>&1; then
        echo "  XX  znc driver build"; sed -n '1,20p' "$WORK/zn_build"
        echo "════ arm64 pass=0 fail=1 ════"; exit 1
    fi
    ZNC="$WORK/znc_drv"
fi

nt(){
    printf '%s' "$2" > "$SRC"
    "$ZNC" "$SRC" --target arm64 -o "$WORK/nt_arm" >"$WORK/nt_out" 2>&1
    if [ ! -x "$WORK/nt_arm" ]; then echo "  XX  $1 (compile failed)"; sed -n '1,8p' "$WORK/nt_out"; fail=$((fail+1)); return; fi
    if ! file "$WORK/nt_arm" | grep -q 'ARM aarch64'; then
        echo "  XX  $1 (not aarch64 ELF)"; fail=$((fail+1)); return
    fi
    $QEMU "$WORK/nt_arm"; local got=$?
    if [ "$got" = "$3" ]; then echo "  ok  $1 (exit $got)"; pass=$((pass+1));
    else echo "  XX  $1 (got $got, want $3)"; fail=$((fail+1)); fi
    rm -f "$WORK/nt_arm"
}

nto(){
    printf '%s' "$2" > "$SRC"
    "$ZNC" "$SRC" --target arm64 -o "$WORK/nt_arm" >"$WORK/nt_out" 2>&1
    if [ ! -x "$WORK/nt_arm" ]; then echo "  XX  $1 (compile failed)"; sed -n '1,8p' "$WORK/nt_out"; fail=$((fail+1)); return; fi
    local got; got=$($QEMU "$WORK/nt_arm"); local ec=$?
    if [ "$got" = "$3" ] && [ "$ec" = "$4" ]; then echo "  ok  $1 (stdout='$got' exit=$ec)"; pass=$((pass+1));
    else echo "  XX  $1 (got stdout='$got' exit=$ec, want '$3'/$4)"; fail=$((fail+1)); fi
    rm -f "$WORK/nt_arm"
}

echo "── arm64 backend: Zag → AArch64 ELF (qemu-user) ──"
nt "return literal"  'fn main() i32 { return 42; }' 42
nt "arithmetic"      'fn main() i32 { let a: i32 = 8; let b: i32 = 5; return a * b - 2; }' 38
nt "portable memory fence" 'fn main() i32 { let a:i32 = 20; @memoryFence(); return a + 22; }' 42
nt "function call"   'fn add(a: i32, b: i32) i32 { return a + b; } fn main() i32 { return add(40, 2); }' 42
nt "while loop"      'fn main() i32 { let s: i32 = 0; let i: i32 = 1; while (i <= 10) { s = s + i; i = i + 1; } return s; }' 55
nt "continue nested" 'fn main() i32 { let i: i32 = 0; let s: i32 = 0; while (i < 8) { i = i + 1; if (i % 2 == 0) { continue; } let j: i32 = 0; while (j < 3) { j = j + 1; if (j == 2) { continue; } s = s + 1; } } return s; }' 8
nt "break nested"    'fn main() i32 { let i: i32 = 0; let s:i32 = 0; while (i < 5) { i = i + 1; let j:i32 = 0; while (j < 5) { j = j + 1; if (j == 3) { break; } s = s + 1; } } return s; }' 10
nt "if/else"         'fn main() i32 { let x: i32 = 7; if (x < 5) { return 1; } else { return 99; } }' 99
nt "recursion (fib)" 'fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); } fn main() i32 { return fib(10); }' 55
nt "factorial"       'fn fact(n: i32) i32 { if (n < 2) { return 1; } return n * fact(n - 1); } fn main() i32 { return fact(5); }' 120
nt "div and mod"     'fn main() i32 { return (100 / 7) + (100 % 7); }' 16
nt "unary minus"     'fn main() i32 { let a: i32 = 50; return 0 - a + 57; }' 7
nt "nested if/else"  'fn main() i32 { let x: i32 = 7; if (x < 5) { return 1; } else if (x < 10) { return 99; } else { return 2; } }' 99
nt "fwd mutual rec"  'fn bar() i32; fn foo() i32 { return bar(); } fn bar() i32 { return 42; } fn main() i32 { return foo(); }' 42
nt "logical ops"     'fn main() i32 { let a: i32 = 1; let b: i32 = 0; if (a == 1 && b == 0) { if (a == 0 || b == 0) { return 33; } } return 1; }' 33
nt "not op"          'fn main() i32 { let a: i32 = 0; if (!a) { return 21; } return 1; }' 21
nt "many args"       'fn s6(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32) i32 { return a + b + c + d + e + f; } fn main() i32 { return s6(1, 2, 3, 4, 5, 6); }' 21
nt "nested calls"    'fn add(a: i32, b: i32) i32 { return a + b; } fn main() i32 { return add(add(10, 20), add(5, 7)); }' 42

echo "── output (write syscall) ──"
nto "print_i32"      'fn main() i32 { print_i32(12345); return 0; }' "12345" 0
nto "print_int"      'fn main() i32 { print_int(42); return 0; }' "42" 0
nto "print_int zero" 'fn main() i32 { print_int(0); return 0; }' "0" 0
nto "print_int neg"  'fn main() i32 { print_i32(0 - 42); return 0; }' "-42" 0
nto "print computed" 'fn main() i32 { let s: i32 = 0; let i: i32 = 1; while (i <= 10) { s = s + i; i = i + 1; } print_int(s); return 0; }' "55" 0
nto "print big i64"  'fn main() i32 { print_int(123456789012); return 0; }' "123456789012" 0
nto "print_str"      'fn main() i32 { print_str("hello\n"); return 0; }' "hello" 0
nto "println str"    'fn main() i32 { _zag_println("world\n"); return 0; }' "world" 0

echo "── data model: structs, pointers, heap, slices, enums ──"
nt "struct fields"   'struct P { x: i32, y: i32 } fn main() i32 { let p: P = P{ .x = 40, .y = 2 }; return p.x + p.y; }' 42
nt "struct field set" 'struct P { x: i32, y: i32 } fn main() i32 { let p: P = P{ .x = 8, .y = 1 }; p.y = 5; return p.x * p.y; }' 40
nt "nested struct"   'struct In { v: i32 } struct Out { a: In, b: i32 } fn main() i32 { let o: Out = Out{ .a = In{ .v = 40 }, .b = 2 }; return o.a.v + o.b; }' 42
nt "struct byval arg" 'struct P { x: i32, y: i32 } fn zap(p: P) i32 { p.x = 0; return p.x; } fn main() i32 { let p: P = P{ .x = 40, .y = 2 }; let z: i32 = zap(p); return p.x + z; }' 40
nt "struct return"   'struct P { x: i32, y: i32 } fn mk(x: i32, y: i32) P { return P{ .x = x, .y = y }; } fn main() i32 { let p: P = mk(40, 2); return p.x + p.y; }' 42
nt "ptr to scalar"   'fn main() i32 { let a: i32 = 1; let pa: *i32 = &a; pa.* = 42; return a; }' 42
nt "ptr to struct"   'struct P { x: i32, y: i32 } fn main() i32 { let p: P = P{ .x = 1, .y = 2 }; let q: *P = &p; q.*.x = 40; return p.x + p.y; }' 42
nt "ptr arg mutate"  'struct P { x: i32, y: i32 } fn bump(q: *P) i32 { q.*.x = q.*.x + 1; return 0; } fn main() i32 { let p: P = P{ .x = 41, .y = 0 }; let z: i32 = bump(&p); return p.x + z; }' 42
nt "new + deref"     'struct P { x: i32, y: i32 } fn main() i32 { let q: *P = new(P{ .x = 40, .y = 2 }); let r: i32 = q.*.x + q.*.y; delete(q); return r; }' 42
nt "new scalar"      'fn main() i32 { let q: *i32 = new(42); return q.*; }' 42
nt "malloc bytes"    'fn main() i32 { let b: *u8 = _zag_malloc(8); b[0] = 65; b[1] = 66; return (b[0] as i32) + (b[1] as i32) - 89; }' 42
nt "slice len"       'fn main() i32 { let s: []u8 = "hello"; return s.len; }' 5
nt "slice index"     'fn main() i32 { let s: []u8 = "hello"; return s[1] as i32; }' 101
nt "subslice"        'fn main() i32 { let s: []u8 = "hello"; let t: []u8 = s[1..3]; return t.len + (t[0] as i32) - 60; }' 43
nt "subslice open"   'fn main() i32 { let s: []u8 = "hello"; let t: []u8 = s[2..]; return t.len; }' 3
nt "slice byval arg" 'fn first(s: []u8) i32 { return s[0] as i32; } fn main() i32 { return first("*hi") - 2; }' 40
nt "enum compare"    'enum Color { red, green, blue } fn main() i32 { let c: Color = Color.green; if (c == Color.green) { return 11; } return 0; }' 11
nt "enum switch"     'enum Color { red, green, blue } fn main() i32 { let c: Color = Color.blue; switch (c) { .red => { return 1; } .green => { return 2; } .blue => { return 42; } } return 0; }' 42
nto "print_str var"  'fn main() i32 { let s: []u8 = "dyn\n"; print_str(s); return 0; }' "dyn" 0
nto "println var"    'fn main() i32 { let s: []u8 = "dyn2"; _zag_println(s); return 0; }' "dyn2" 0

echo "── unions, optionals, scoping ──"
nt "union tag switch" 'union V { a: i32, b: i32 } fn main() i32 { let v: V = V{ .b = 40 }; switch (v) { .a => |x| { return 1; } .b => |x| { return x + 2; } } return 0; }' 42
nt "union agg payload" 'struct P { x: i32, y: i32 } union V { p: P, n: i32 } fn main() i32 { let v: V = V{ .p = P{ .x = 40, .y = 2 } }; switch (v) { .p => |c| { return c.*.x + c.*.y; } .n => |m| { return m; } } return 0; }' 42
nt "opt some"        'fn main() i32 { let o: ?i32 = 42; if (o) |v| { return v; } return 1; }' 42
nt "opt null"        'fn main() i32 { let o: ?i32 = null; if (o) |v| { return 1; } return 42; }' 42
nt "opt reassign"    'fn main() i32 { let o: ?i32 = null; o = 21; if (o) |v| { return v * 2; } return 1; }' 42
nt "opt orelse"      'fn main() i32 { let o: ?i32 = null; let a: i32 = o orelse 40; o = 10; let b: i32 = o orelse 99; return a + b / 5; }' 42
nt "opt fn return"   'fn find(k: i32) ?i32 { if (k > 0) { return k * 2; } return null; } fn main() i32 { let a: i32 = find(21) orelse 0; let b: i32 = find(0 - 1) orelse 100; return a - b + 100; }' 42
nt "while-let"       'fn main() i32 { let o: ?i32 = 3; let s: i32 = 0; while (o) |v| { s = s + v; if (v == 1) { o = null; } else { o = v - 1; } } return s * 7; }' 42
nt "scoped shadow"   'fn main() i32 { let x: i32 = 40; if (x > 0) { let x: i32 = 2; if (x != 2) { return 1; } } return x + 2; }' 42

echo "── generics (monomorphization) + string builtins ──"
nt "generic identity" 'fn id[T](x: T) T { return x; } fn main() i32 { return id[i32](42); }' 42
nt "generic infer"   'fn id[T](x: T) T { return x; } fn main() i32 { return id(42); }' 42
nt "arraylist sum"   '@import("std/list.zag") fn main() i32 { let xs: ArrayList[i32] = make[i32](2); let i: i32 = 0; while (i < 10) { push[i32](&xs, i); i = i + 1; } let s: i32 = 0; let j: i32 = 0; while (j < len[i32](xs)) { s = s + get[i32](xs, j); j = j + 1; } return s; }' 45
nt "arraylist grow"  '@import("std/list.zag") fn main() i32 { let xs: ArrayList[u8] = make[u8](1); let i: i32 = 0; while (i < 100) { push[u8](&xs, (i % 7) as u8); i = i + 1; } return (get[u8](xs, 99) as i32) + len[u8](xs) - 59; }' 42
nt "nested generics" '@import("std/list.zag") fn main() i32 { let m: ArrayList[ArrayList[i32]] = make[ArrayList[i32]](2); let r: ArrayList[i32] = make[i32](2); push[i32](&r, 20); push[i32](&r, 22); push[ArrayList[i32]](&m, r); let row: ArrayList[i32] = get[ArrayList[i32]](m, 0); return get[i32](row, 0) + get[i32](row, 1); }' 42
nt "struct elems+pop" '@import("std/list.zag") struct Pt { x: i32, y: i32 } fn main() i32 { let ps: ArrayList[Pt] = make[Pt](1); push[Pt](&ps, Pt{ .x = 30, .y = 8 }); push[Pt](&ps, Pt{ .x = 1, .y = 2 }); let p: Pt = pop[Pt](&ps); return p.x + p.y + get[Pt](ps, 0).x + get[Pt](ps, 0).y + len[Pt](ps); }' 42
nt "strEq/strLen"    'fn main() i32 { let s: []u8 = "hello"; let c: i32 = 0; if (@strEq(s, "hello")) { c = c + 1; } if (!@strEq(s, "world")) { c = c + 1; } if (@strLen(s) == 5) { c = c + 40; } return c; }' 42

echo "── error unions (!T, try, catch) ──"
nt "catch ok"        'error { Err } fn sdiv(a: i32, b: i32) !i32 { if (b == 0) { return error.Err; } return a / b; } fn main() i32 { return sdiv(84, 2) catch 0; }' 42
nt "catch fallback"  'error { Err } fn sdiv(a: i32, b: i32) !i32 { if (b == 0) { return error.Err; } return a / b; } fn main() i32 { return sdiv(5, 0) catch 7; }' 7
nt "catch success"   'error { Err } fn sdiv(a: i32, b: i32) !i32 { if (b == 0) { return error.Err; } return a / b; } fn main() i32 { return sdiv(10, 2) catch 0 - 1; }' 5
nt "try propagate"   'error { Err } fn sdiv(a: i32, b: i32) !i32 { if (b == 0) { return error.Err; } return a / b; } fn calc(a: i32, b: i32) !i32 { let q: i32 = try sdiv(a, b); return q * 2; } fn main() i32 { return calc(10, 0) catch 99; }' 99
nt "try success"     'error { Err } fn sdiv(a: i32, b: i32) !i32 { if (b == 0) { return error.Err; } return a / b; } fn calc(a: i32, b: i32) !i32 { let q: i32 = try sdiv(a, b); return q * 2; } fn main() i32 { return calc(10, 2) catch 0 - 1; }' 10
nt "catch capture"   'error { NotFound, OutOfRange } fn ge(x: i32) !i32 { if (x == 0) { return error.NotFound; } if (x == 1) { return error.OutOfRange; } return x; } fn main() i32 { let a: i32 = ge(0) catch |e| e; let b: i32 = ge(1) catch |e| e; if (a != b && a > 0 && b > 0) { return 42; } return 0; }' 42

echo "── floats (f64/f32 held as doubles) ──"
nt "f64 add cmp"     'fn main() i32 { let x: f64 = 1.5; let y: f64 = 2.5; if (x + y == 4.0) { return 42; } return 1; }' 42
nt "f64 div as i32"  'fn main() i32 { let x: f64 = 7.0; let y: f64 = 2.0; return (x / y) as i32; }' 3
nt "int to f64 back" 'fn main() i32 { let n: i32 = 7; let f: f64 = n as f64; return f as i32; }' 7
nt "f64 mul sub"     'fn main() i32 { let a: f64 = 6.5; let b: f64 = 8.0; return (a * b - 10.0) as i32; }' 42
nt "f64 neg"         'fn main() i32 { let a: f64 = -3.5; let b: f64 = 0.0 - a; return (b * 12.0) as i32; }' 42
nt "f64 compare lt"  'fn main() i32 { let a: f64 = 1.25; let b: f64 = 1.5; if (a < b && b > a && a <= a && b >= b && a != b) { return 42; } return 1; }' 42
nt "f32 via f64"     'fn main() i32 { let a: f32 = 10.5; let b: f32 = 4.0; return (a * b) as i32; }' 42
nt "f64 fn arg ret"  'fn half(x: f64) f64 { return x / 2.0; } fn main() i32 { return half(84.0) as i32; }' 42

nto "print_f64"      'fn main() i32 { print_f64(3.14159); return 0; }' "3.14159" 0
nto "print_f64 neg"  'fn main() i32 { print_f64(0.0 - 1.5); return 0; }' "-1.5" 0
nto "print_f64 sci"  'fn main() i32 { let m: f64 = 1000000.0; print_f64(1.23457 * m); return 0; }' "1.23457e+06" 0
nto "print_f64 tiny" 'fn main() i32 { print_f64(0.000012345); return 0; }' "1.2345e-05" 0
nto "print_f32"      'fn main() i32 { print_f32(10.5); return 0; }' "10.5" 0

echo "── closures (fat_fn) ──"
nt "fn as value"     'fn add1(x: i32) i32 { return x + 1; } fn apply(f: fn(i32) i32, x: i32) i32 { return f(x); } fn main() i32 { return apply(add1, 41); }' 42
nt "closure capture" 'fn main() i32 { let g: i32 = 3; let f: fn(i32) i32 = fn[g](x: i32) i32 { return x * g; }; return f(14); }' 42
nt "closure as arg"  'fn apply(f: fn(i32) i32, x: i32) i32 { return f(x); } fn main() i32 { let g: i32 = 2; let f: fn(i32) i32 = fn[g](x: i32) i32 { return x * g; }; return apply(f, 21); }' 42
nt "two captures"    'fn main() i32 { let a: i32 = 40; let b: i32 = 2; let f: fn() i32 = fn[a, b]() i32 { return a + b; }; return f(); }' 42
nt "capless closure" 'fn main() i32 { let f: fn(i32) i32 = fn[](x: i32) i32 { return x + 40; }; return f(2); }' 42
nt "clos shadows fn" 'fn add(a: i32, b: i32) i32 { return a + b; } fn main() i32 { let add: fn(i32) i32 = fn[](x: i32) i32 { return x; }; return add(1) + 41; }' 42
nt "ptr capture"     'fn main() i32 { let v: i32 = 10; let bump: fn() i32 = fn[&v]() i32 { v.* = v.* + 1; return 0; }; let z: i32 = bump(); let z2: i32 = bump(); return v + z + z2 + 30; }' 42

echo "── structural interfaces (vtable dispatch + coercion) ──"
nt "method call"     'struct P { x: i32 } fn (self: P) twice() i32 { return self.x * 2; } fn main() i32 { let p: P = P{ .x = 21 }; return p.twice(); }' 42
nt "iface dispatch"  'interface Shape { fn area(self) i32; } struct Sq { s: i32 } fn (self: Sq) area() i32 { return self.s * self.s; } struct Rc { w: i32, h: i32 } fn (self: Rc) area() i32 { return self.w * self.h; } fn go(s: Shape) i32 { return s.area(); } fn main() i32 { let a: Sq = Sq{ .s = 5 }; let b: Rc = Rc{ .w = 3, .h = 4 }; return go(a) + go(b) + 5; }' 42
nt "iface multi-meth" 'interface Shape { fn area(self) i32; fn scaled(self, k: i32) i32; } struct Sq { s: i32 } fn (self: Sq) area() i32 { return self.s * self.s; } fn (self: Sq) scaled(k: i32) i32 { return self.s * self.s * k; } fn rep(s: Shape) i32 { return s.area() + s.scaled(2); } fn main() i32 { let a: Sq = Sq{ .s = 3 }; return rep(a) + 15; }' 42

# interfaces example must match the x86 expected output exactly
"$ZNC" examples/interfaces.zag --target arm64 -o $WORK/nt_if >$WORK/nt_out 2>&1
if [ -x $WORK/nt_if ] && [ "$($QEMU $WORK/nt_if 2>/dev/null)" = "$(printf '75\n36')" ]; then
    echo "  ok  examples/interfaces.zag (75/36)"; pass=$((pass+1))
else
    echo "  XX  examples/interfaces.zag"; sed -n '1,6p' $WORK/nt_out; fail=$((fail+1))
fi
rm -f $WORK/nt_if

echo "── real programs (output must be byte-identical to x86) ──"
for prog in arena hash_map sort_bench state_machine csv_parser json_parser; do
    if ! "$ZNC" "programs/$prog.zag" -o $WORK/np_x86 >/dev/null 2>&1; then
        echo "  XX  $prog (x86 compile failed)"; fail=$((fail+1)); continue
    fi
    $WORK/np_x86 > $WORK/np_x86_out 2>&1; x86_ec=$?
    if ! "$ZNC" "programs/$prog.zag" --target arm64 -o $WORK/np_arm >/dev/null 2>&1; then
        echo "  XX  $prog (arm64 compile failed)"; fail=$((fail+1)); continue
    fi
    $QEMU $WORK/np_arm > $WORK/np_arm_out 2>&1; arm_ec=$?
    if [ "$x86_ec" = "$arm_ec" ] && diff -q $WORK/np_x86_out $WORK/np_arm_out >/dev/null 2>&1; then
        echo "  ok  $prog (byte-identical output, exit $arm_ec)"; pass=$((pass+1))
    else
        echo "  XX  $prog (output differs from x86: x86=$x86_ec arm=$arm_ec)"
        diff $WORK/np_x86_out $WORK/np_arm_out 2>/dev/null | head -4
        fail=$((fail+1))
    fi
    rm -f $WORK/np_x86 $WORK/np_arm $WORK/np_x86_out $WORK/np_arm_out
done

# static ELF, no interpreter
printf 'fn main() i32 { return 0; }' > $SRC
"$ZNC" $SRC --target arm64 -o $WORK/nt_elf >/dev/null 2>&1
if file $WORK/nt_elf | grep -q 'statically linked' && ! readelf -l $WORK/nt_elf 2>/dev/null | grep -q 'INTERP'; then
    echo "  ok  emitted ELF is static, no interpreter"; pass=$((pass+1))
else
    echo "  XX  emitted ELF static/no-interp check"; fail=$((fail+1))
fi
rm -f $WORK/nt_elf $SRC

echo "════ arm64 pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
