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
# `_zag_println` on a SLICE VALUE (not a literal) must STILL append the trailing
# '\n'. The native lowerer baked the newline into the interned bytes for the
# literal branch but forgot the slice branch, so a println'd slice ran into the
# next line (e.g. `zag: built …out` merged with `-- running --`) → the self-host
# codegen/zir tests saw mangled output. Two lines prove the newline is there.
nto "println slice newline" 'fn main() i32 { let s: []u8 = "AB"; _zag_println(s); _zag_println("CD"); return 0; }' "$(printf 'AB\nCD')" 0
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
# `orelse` UNWRAPS to a scalar; when used directly as a CALL ARGUMENT its type
# must be the inner T, not the optional `?T`. Mis-typing it as the optional
# aggregate made the caller copy the scalar result as a 16-byte block pointer →
# NULL deref / SIGSEGV (the bug that crashed the znc-built native zagc).
nt  "orelse as call arg"   'fn id(a: i32) i32 { return a; } fn f(b: i32) ?i32 { if (b == 1) { return 7; } return null; } fn main() i32 { let o: ?i32 = f(1); return id(o orelse 0); }' 7
# A switch that REUSES a capture name across arms whose payloads are DIFFERENT
# struct types: `.a => |s| ...` (s : *A) then `.b => |s| ...` (s : *B). The
# frame pre-scan's name→type map returned the FIRST recorded type (stale *A) for
# `s`, so an aggregate field `s.*.items` (an ArrayList passed BY VALUE to suml)
# was mis-sized as a scalar → the per-call copy was under-reserved → the frame
# overran and a nested call clobbered the copied aggregate (returned 86, not 42).
# The pre-scan now REFRESHES a reused name's type in place, mirroring lowering's
# slot shadowing. (This single bug crashed the znc-built native zagc on BOTH
# examples/methods.zag — via sema's struct_field_type — and examples/patterns.zag
# — via codegen's gen_expr.)
nt  "switch capture reuse + agg field" '@import("std/list.zag") struct A { tag: i32 } struct B { items: ArrayList[i32] } union U { a: A, b: B } fn suml(xs: ArrayList[i32]) i32 { let acc: i32 = 0; let i: i32 = 0; while (i < len[i32](xs)) { acc = acc + get[i32](xs, i); i = i + 1; } return acc; } fn eval(u: *U) i32 { return switch (u.*) { .a => |s| s.*.tag, .b => |s| suml(s.*.items) }; } fn main() i32 { let xs: ArrayList[i32] = make[i32](4); push[i32](&xs, 10); push[i32](&xs, 20); push[i32](&xs, 12); let u: *U = new(U{ .b = B{ .items = xs } }); return eval(u); }' 42

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

echo "── posits (p8/p16/p32/p64 — Zag posit runtime, native, no libc) ──"
# Round-trip: @floatToPosit then @positToFloat → exact for 0.5.
nto "p32 round-trip 0.5"  'fn main() i32 { let h: p32 = @floatToPosit(0.5); print_f64(@positToFloat(h)); return 0; }' "0.5" 0
# Exact posit bit patterns (must match the IEEE/Posit-standard encodings).
nto "p32 bits of 1.0"     'fn main() i32 { let o: p32 = @intToPosit(1); print_u64(@positToBits(o)); return 0; }' "1073741824" 0
nto "p32 add 1+2=3"       'fn main() i32 { let a: p32 = @intToPosit(1); let b: p32 = @intToPosit(2); let c: p32 = a + b; print_u64(@positToBits(c)); return 0; }' "1275068416" 0
nto "p32 mul 2*2=4"       'fn main() i32 { let t: p32 = @intToPosit(2); let f: p32 = t * t; print_f64(@positToFloat(f)); return 0; }' "4" 0
# All four widths encode 1.0 to the right bit pattern.
nto "p8 bits of 1.0"      'fn main() i32 { let o: p8  = @floatToP8(1.0);  print_u64(@p8ToBits(o));  return 0; }' "64" 0
nto "p16 bits of 1.0"     'fn main() i32 { let o: p16 = @floatToP16(1.0); print_u64(@p16ToBits(o)); return 0; }' "16384" 0
nto "p64 round-trip 3.0"  'fn main() i32 { let a: p64 = @floatToP64(1.0); let b: p64 = @floatToP64(2.0); print_f64(@p64ToFloat(a + b)); return 0; }' "3" 0
# A non-posit program must NOT pull in the runtime (byte-identical to no-posit).
nto "no-posit unaffected" 'fn main() i32 { print_int(7); return 0; }' "7" 0

echo "── saturating / fixed-point / arbitrary-width (Round 2, native, no libc) ──"
# Saturating: clamps to the type's bounds (NO wrap, NO Panic). sat_i8 100+100→127.
nt  "sat_i8 clamp (exit)" 'fn main() i32 { let a: sat_i8 = 100; let b: sat_i8 = 100; let c: sat_i8 = a + b; return c; }' 127
nto "sat_i16 add clamps"  'fn main() i32 { let a: sat_i16 = 25000; let b: sat_i16 = 20000; let c: sat_i16 = a + b; print_i32(c); return 0; }' "32767" 0
nto "sat_i16 sub clamps"  'fn main() i32 { let a: sat_i16 = 0 - 30000; let b: sat_i16 = 10000; let c: sat_i16 = a - b; print_i32(c); return 0; }' "-32768" 0
nto "sat_u8 sub floor 0"  'fn main() i32 { let a: sat_u8 = 10; let b: sat_u8 = 50; let c: sat_u8 = a - b; print_i32(c); return 0; }' "0" 0
# Fixed-point Q8.8: mul rescales by 2^F → (32*25000)/256 = 3125. +/- are plain
# ints; fixed `/` is plain int division too (bit-identical to the C backend, which
# lowers ONLY fixed `*`), so fixed_8_8 5+3 = 8 and 100/7 = 14.
nto "fixed_8_8 mul (Q8.8)" 'fn main() i32 { let a: fixed_8_8 = 32; let b: fixed_8_8 = 25000; let c: fixed_8_8 = a * b; print_i32(c); return 0; }' "3125" 0
nto "fixed_8_8 add native" 'fn main() i32 { let a: fixed_8_8 = 5; let b: fixed_8_8 = 3; let c: fixed_8_8 = a + b; print_i32(c); return 0; }' "8" 0
# Arbitrary-width UNSIGNED: result masked to N bits. SIGNED iN and div fall through
# unmasked (exactly the C backend), so i12 -100-50 = -150 prints plainly.
nto "u11 mask (2100&0x7FF)" 'fn main() i32 { let a: u11 = 2000; let b: u11 = 100; let c: u11 = a + b; print_i32(c); return 0; }' "52" 0
nto "i12 signed native"     'fn main() i32 { let a: i12 = 0 - 100; let b: i12 = 50; let c: i12 = a - b; print_i32(c); return 0; }' "-150" 0
# []sat_i16 slice indexing must compile (word-stride element load).
nto "[]sat_i16 index compiles" 'fn pick(s: []sat_i16) sat_i16 { return s[0] + s[1]; } fn main() i32 { print_int(7); return 0; }' "7" 0
# A sat/fixed-free program must NOT pull in the rt2 runtime (no extra fns).
nto "no-satfixed unaffected" 'fn main() i32 { let x: u32 = 7; print_int(x as i32); return 0; }' "7" 0

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

# Hardening: mixing a posit and a non-posit operand must ABORT, never miscompile.
rm -f /tmp/nt_bin
printf 'fn main() i32 { let p: p32 = @intToPosit(1); let q: i32 = 2; let r: p32 = p + q; return 0; }' > nt_src.zag
"$ZNC" nt_src.zag -o /tmp/nt_bin >/tmp/nt_out 2>&1
if grep -q 'build aborted' /tmp/nt_out && [ ! -x /tmp/nt_bin ]; then
    echo "  ok  rejects mixed posit/non-posit arithmetic loudly"; pass=$((pass+1))
else
    echo "  XX  mixed posit/non-posit not rejected loudly"; fail=$((fail+1))
fi
rm -f /tmp/nt_bin nt_src.zag

echo "════ native pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
