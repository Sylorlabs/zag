#!/usr/bin/env bash
# Native x86-64 backend suite: compiles Zag STRAIGHT to a runnable ELF with
# zero external tools — no cc, no as, no ld, no libc. The whole pipeline
# (parse → ncodegen → x86 encode → ELF) is Zag (selfhost/native/*.zag).
cd "$(dirname "$0")/.."    # zag-poc root
pass=0; fail=0

# Build the native driver (znc) with the self-hosted compiler.
if ! ./zagc build selfhost/native/znc.zag >/tmp/zn_build 2>&1; then
    echo "  XX  znc driver build"; sed -n '1,20p' /tmp/zn_build
    echo "════ native pass=0 fail=1 ════"; exit 1
fi
cp selfhost/native/znc.zag.out /tmp/znc_drv
ZNC=/tmp/znc_drv

# nt <name> <source> <expected-exit>
nt(){
    printf '%s' "$2" > nt_src.zag
    "$ZNC" nt_src.zag -o /tmp/nt_bin >/tmp/nt_out 2>&1
    if [ ! -x /tmp/nt_bin ]; then echo "  XX  $1 (compile failed)"; sed -n '1,8p' /tmp/nt_out; fail=$((fail+1)); return; fi
    /tmp/nt_bin; local got=$?
    if [ "$got" = "$3" ]; then echo "  ok  $1 (exit $got)"; pass=$((pass+1));
    else echo "  XX  $1 (got $got, want $3)"; fail=$((fail+1)); fi
    rm -f /tmp/nt_bin
}

echo "── native backend: Zag → x86-64 ELF (no cc/as/ld/libc) ──"
nt "return literal"  'fn main() i32 { return 42; }' 42
nt "arithmetic"      'fn main() i32 { let a: i32 = 8; let b: i32 = 5; return a * b - 2; }' 38
nt "function call"   'fn add(a: i32, b: i32) i32 { return a + b; } fn main() i32 { return add(40, 2); }' 42
nt "recursion (fib)" 'fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); } fn main() i32 { return fib(10); }' 55
nt "while loop"      'fn main() i32 { let s: i32 = 0; let i: i32 = 1; while (i <= 10) { s = s + i; i = i + 1; } return s; }' 55
nt "factorial"       'fn fact(n: i32) i32 { if (n < 2) { return 1; } return n * fact(n - 1); } fn main() i32 { return fact(5); }' 120
nt "div and mod"     'fn main() i32 { return (100 / 7) + (100 % 7); }' 16
nt "unary minus"     'fn main() i32 { let a: i32 = 50; return 0 - a + 57; }' 7
nt "nested if/else"  'fn main() i32 { let x: i32 = 7; if (x < 5) { return 1; } else if (x < 10) { return 99; } else { return 2; } }' 99

# nto <name> <source> <expected-stdout> <expected-exit> — for output-producing programs
nto(){
    printf '%s' "$2" > nt_src.zag
    "$ZNC" nt_src.zag -o /tmp/nt_bin >/tmp/nt_out 2>&1
    if [ ! -x /tmp/nt_bin ]; then echo "  XX  $1 (compile failed)"; sed -n '1,6p' /tmp/nt_out; fail=$((fail+1)); return; fi
    local got; got=$(/tmp/nt_bin); local ec=$?
    if [ "$got" = "$3" ] && [ "$ec" = "$4" ]; then echo "  ok  $1 (stdout='$got' exit=$ec)"; pass=$((pass+1));
    else echo "  XX  $1 (got stdout='$got' exit=$ec, want '$3'/$4)"; fail=$((fail+1)); fi
    rm -f /tmp/nt_bin
}
echo "── output (print via write syscall) + structs ──"
nto "print_int"      'fn main() i32 { print_int(12345); return 0; }' "12345" 0
nto "print_int zero" 'fn main() i32 { print_int(0); return 0; }' "0" 0
nto "print_int neg"  'fn main() i32 { print_int(0 - 42); return 0; }' "-42" 0
nto "print computed" 'fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); } fn main() i32 { print_int(fib(10)); return 0; }' "55" 0
nto "print_str"      'fn main() i32 { print_str("hello\n"); return 0; }' "hello" 0
nt  "struct fields"  'struct P { x: i32, y: i32 } fn main() i32 { let p: P = P{ .x = 30, .y = 12 }; return p.x + p.y; }' 42
nt  "string .len"    'fn main() i32 { return "hello".len; }' 5
echo "── structs by-value · slices · heap (new) ──"
nt  "struct byval return" 'struct P { x: i32, y: i32 } fn mk(a: i32, b: i32) P { return P{ .x = a, .y = b }; } fn main() i32 { let p: P = mk(30, 12); return p.x + p.y; }' 42
nt  "struct byval arg iso" 'struct P { x: i32 } fn wr(p: P) i32 { p.x = 999; return p.x; } fn main() i32 { let q: P = P{ .x = 5 }; let z: i32 = wr(q); return q.x; }' 5
nt  "slice value len"     'fn slen(s: []u8) i32 { return s.len; } fn main() i32 { let s: []u8 = "hello"; return slen(s); }' 5
nt  "slice index"         'fn main() i32 { let s: []u8 = "hello"; return s[1]; }' 101
nto "print slice var"     'fn main() i32 { let s: []u8 = "hello\n"; print_str(s); return 0; }' "hello" 0
nt  "new heap (mmap)"     'struct P { x: i32, y: i32 } fn main() i32 { let p: *P = new(P{ .x = 40, .y = 2 }); return p.*.x + p.*.y; }' 42
nt  "new x3 (frame)"      'struct P { x: i32 } fn main() i32 { let a: *P = new(P{ .x = 10 }); let b: *P = new(P{ .x = 20 }); let c: *P = new(P{ .x = 12 }); return a.*.x + b.*.x + c.*.x; }' 42
echo "── generics · unions · @-builtins (native self-hosting round 1) ──"
nt  "@sizeOf struct"   'struct P { a: i32, b: i32, c: i32 } fn main() i32 { return @sizeOf[P](); }' 24
nt  "@strEq equal"     'fn main() i32 { if (@strEq("hi", "hi")) { return 1; } return 0; }' 1
nt  "@strEq differ"    'fn main() i32 { if (@strEq("hi", "ho")) { return 1; } return 0; }' 0
nt  "generic id[T]"    'fn id[T](x: T) T { return x; } fn main() i32 { return id[i32](42); }' 42
nt  "ArrayList[i32]"   '@import("std/list.zag") fn main() i32 { let xs: ArrayList[i32] = make[i32](4); push[i32](&xs, 30); push[i32](&xs, 12); return get[i32](xs, 0) + get[i32](xs, 1); }' 42
nt  "ArrayList realloc" '@import("std/list.zag") fn main() i32 { let xs: ArrayList[i32] = make[i32](2); push[i32](&xs, 1); push[i32](&xs, 2); push[i32](&xs, 3); push[i32](&xs, 4); push[i32](&xs, 5); return len[i32](xs); }' 5
nt  "union switch"     'union U { a: i32, b: i32 } fn main() i32 { let u: U = U{ .b = 42 }; return switch (u) { .a => |x| 0, .b => |x| x.* }; }' 42
nt  "enum switch"      'enum Color { Red, Green, Blue } fn main() i32 { let c: Color = Color.Green; return switch (c) { .Red => 1, .Green => 42, .Blue => 3 }; }' 42
echo "── variable layout · nested literals · &expr · optionals (round 2) ──"
nt  "@sizeOf slice field" 'struct S { a: i32, b: []u8, c: i32 } fn main() i32 { return @sizeOf[S](); }' 32
nt  "var-layout fields"   'struct S { a: i32, b: []u8, c: i32 } fn main() i32 { let s: S = S{ .a = 40, .b = "x", .c = 2 }; return s.a + s.c; }' 42
nt  "slice field .len"    'struct S { a: i32, b: []u8 } fn main() i32 { let s: S = S{ .a = 1, .b = "hello" }; return s.b.len; }' 5
nt  "nested union literal" 'struct IntLit { text: []u8 } struct Bin { op: []u8, l: *IntLit, r: *IntLit } union Node { ilit: IntLit, bin: Bin } fn main() i32 { let n: *Node = new(Node{ .ilit = IntLit{ .text = "hello" } }); return switch (n.*) { .ilit => |x| x.*.text.len, .bin => |x| 0 }; }' 5
nt  "nested struct as arg" 'struct P { x: i32, y: i32 } fn sum(p: P) i32 { return p.x + p.y; } fn main() i32 { return sum(P{ .x = 30, .y = 12 }); }' 42
nt  "&s.field write-thru"  'struct P { x: i32, y: i32 } fn setx(p: *i32) void { p.* = 42; } fn main() i32 { let s: P = P{ .x = 1, .y = 0 }; setx(&s.x); return s.x; }' 42
nt  "optional orelse val"  'fn f(b: i32) ?i32 { if (b == 1) { return 42; } return null; } fn main() i32 { return f(1) orelse 7; }' 42
nt  "optional orelse def"  'fn f(b: i32) ?i32 { if (b == 1) { return 42; } return null; } fn main() i32 { return f(0) orelse 7; }' 7

echo "── floating-point (f64/f32 via SSE — no libc) ──"
nt  "f64 add+cmp"     'fn main() i32 { let x: f64 = 1.5; let y: f64 = 2.5; if (x + y == 4.0) { return 1; } return 0; }' 1
nt  "f64 div trunc"   'fn main() i32 { let x: f64 = 7.0; let y: f64 = 2.0; return (x / y) as i32; }' 3
nt  "int->f64->int"   'fn main() i32 { let n: i32 = 7; let f: f64 = n as f64; return f as i32; }' 7
nt  "f64 lt/ge"       'fn main() i32 { if (1.5 < 2.5 && 2.5 >= 2.5) { return 1; } return 0; }' 1
nt  "f64 param/ret"   'fn sq(x: f64) f64 { return x * x; } fn main() i32 { return sq(3.0) as i32; }' 9
nt  "f32 struct math" 'struct V { x: f32, y: f32 } fn main() i32 { let v: V = V{ .x = 1.5, .y = 2.5 }; return (v.x + v.y) as i32; }' 4
nto "print_f64 frac"  'fn main() i32 { print_f64(0.5); return 0; }' "0.5" 0
nto "print_f64 div"   'fn main() i32 { let x: f64 = 3.0; let y: f64 = 2.0; print_f64(x / y); return 0; }' "1.5" 0
nto "print_f64 int"   'fn main() i32 { print_f64(440.0); return 0; }' "440" 0
nto "print_f64 neg"   'fn main() i32 { let x: f64 = 1.5; print_f64(-x); return 0; }' "-1.5" 0
nto "print_f32"       'fn main() i32 { print_f32(0.25); return 0; }' "0.25" 0

# The emitted artifact must be a real static ELF with no interpreter (no libc).
"$ZNC" nt_src.zag -o /tmp/nt_elf >/dev/null 2>&1
if file /tmp/nt_elf | grep -q 'statically linked' && ! readelf -l /tmp/nt_elf 2>/dev/null | grep -q 'INTERP'; then
    echo "  ok  emitted ELF is static, no interpreter (no libc)"; pass=$((pass+1))
else
    echo "  XX  emitted ELF static/no-interp check"; fail=$((fail+1))
fi
rm -f /tmp/nt_elf nt_src.zag

# Hardening: an unsupported construct must ABORT the build, never miscompile.
# (Float literals are now SUPPORTED; a hex literal is still rejected loudly.)
rm -f /tmp/nt_bin
printf 'fn main() i32 { let x: i32 = 0xff; return 0; }' > nt_src.zag
"$ZNC" nt_src.zag -o /tmp/nt_bin >/tmp/nt_out 2>&1
if grep -q 'build aborted' /tmp/nt_out && [ ! -x /tmp/nt_bin ]; then
    echo "  ok  rejects hex literal loudly (aborts, emits no binary)"; pass=$((pass+1))
else
    echo "  XX  hex literal not rejected loudly"; fail=$((fail+1))
fi
rm -f /tmp/nt_bin nt_src.zag

echo "════ native pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
