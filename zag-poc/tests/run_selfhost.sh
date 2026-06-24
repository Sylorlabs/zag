#!/usr/bin/env bash
# Self-hosted compiler tests: each stage of the Zag-in-Zag compiler must build
# (via the bootstrap zig zagc) and produce the expected result.
cd "$(dirname "$0")/.."
ZAGC=./zig-out/bin/zagc
pass=0; fail=0

# Lexer: token-kind codes (numeric lines) followed by three token texts.
echo "── selfhost: lexer ──"
$ZAGC build selfhost/lex_test.zag --run >/tmp/zsh 2>/dev/null
body=$(sed -n '/-- running/,/-- exit/p' /tmp/zsh | grep -vE 'running|exit|--')
codes=$(echo "$body" | grep -E '^[0-9]+$' | tr '\n' ' ' | sed 's/ *$//')
texts=$(echo "$body" | grep -vE '^[0-9]*$' | tr '\n' ' ' | sed 's/ *$//')
want_codes="10 1 40 1 48 1 46 1 48 1 41 1 2 42 12 1 48 1 3 1 3 1 47 13 1 3 5 47 43 0"
want_texts="fn add @realtime"
if [ "$codes" = "$want_codes" ] && [ "$texts" = "$want_texts" ]; then
    echo "  ok  lexer (30 tokens; texts via slicing)"; pass=$((pass+1))
else
    echo "  XX  lexer"
    echo "      want codes: [$want_codes]"; echo "      got  codes: [$codes]"
    echo "      want texts: [$want_texts]"; echo "      got  texts: [$texts]"
    fail=$((fail+1))
fi

# Parser: pre-order AST dump of fib (precedence) + enum/struct/union decls +
# struct literal + pointer-deref field chain (p.*.x).
echo "── selfhost: parser ──"
$ZAGC build selfhost/parse_test.zag --run >/tmp/zsh2 2>/dev/null
pgot=$(sed -n '/-- running/,/-- exit/p' /tmp/zsh2 | grep -vE 'running|exit|--' | tr '\n' ' ' | sed 's/ *$//')
pwant="1 fib i32 4 13 < 12 n 10 2 3 12 n 3 13 + 15 12 fib 13 - 12 n 10 1 15 12 fib 13 - 12 n 10 2 31 Color Red Green Blue 30 Point x i32 y i32 32 Val num i32 flag bool 1 origin Point 3 18 Point x 10 0 y 10 0 1 getx i32 3 17 17 12 p * x"
if [ "$pgot" = "$pwant" ]; then
    echo "  ok  parser (fib precedence; enum/struct/union; struct-lit; p.*.x)"; pass=$((pass+1))
else
    echo "  XX  parser"; echo "      want: [$pwant]"; echo "      got:  [$pgot]"; fail=$((fail+1))
fi

# Effect/capability checker: fixpoint call-graph analysis + constraint verify.
# Prints "<fn> <violated-mask>" per constrained fn (0 = proven safe).
echo "── selfhost: effect checker ──"
$ZAGC build selfhost/sema_test.zag --run >/tmp/zsh3 2>/dev/null
sgot=$(sed -n '/-- running/,/-- exit/p' /tmp/zsh3 | grep -vE 'running|exit|--' | tr '\n' ' ' | sed 's/ *$//')
# safe_add: realtime, clean → 0; bad_rt: Alloc(1); rt_io: transitive IO(4);
# pure_calc: total, clean → 0; total_div: Panic(2).
swant="safe_add 0 bad_rt 1 rt_io 4 pure_calc 0 total_div 2"
if [ "$sgot" = "$swant" ]; then
    echo "  ok  effects (proven safe; direct Alloc; transitive IO; intrinsic Panic)"; pass=$((pass+1))
else
    echo "  XX  effects"; echo "      want: [$swant]"; echo "      got:  [$sgot]"; fail=$((fail+1))
fi

# C backend: codegen a recursive fib(10), compile the emitted C, run it → 55.
# This is the full self-hosted front-to-back pipeline: lex→parse→codegen→C→exe.
echo "── selfhost: codegen (end-to-end) ──"
$ZAGC build selfhost/codegen_test.zag --run >/tmp/zsh4 2>/dev/null
sed -n '/-- running/,/-- exit/p' /tmp/zsh4 | grep -v '^-- ' > /tmp/zsh_gen.c
cgout=""
if cc /tmp/zsh_gen.c -o /tmp/zsh_gen 2>/dev/null; then
    cgout=$(/tmp/zsh_gen)
fi
if [ "$cgout" = "55" ]; then
    echo "  ok  codegen (fib(10)→C→cc→55)"; pass=$((pass+1))
else
    echo "  XX  codegen (got '$cgout', want 55)"; fail=$((fail+1))
fi

# Driver: build the self-hosted compiler `zagc`, then use IT to compile a Zag
# program to a native binary and run it — and confirm it refuses to build a
# capability-violating program.
echo "── selfhost: driver (zagc compiling Zag) ──"
SH=/tmp/zsh_driver
mkdir -p $SH
if $ZAGC build selfhost/zagc.zag >/dev/null 2>&1 && [ -x ./zagc ]; then
    cp ./zagc $SH/zagc
    printf 'fn fact(n: i32) i32 { if (n < 2) { return 1; } return n * fact(n - 1); }\nfn main() void { print_i32(fact(6)); }\n' > $SH/ok.zag
    printf 'extern fn grab(n: i32) *i8 @alloc;\nfn hot(n: i32) i32 @realtime { let p: *i8 = grab(n); return 0; }\nfn main() void { print_i32(hot(1)); }\n' > $SH/bad.zag
    $SH/zagc $SH/ok.zag >/dev/null 2>&1
    okout=""
    if [ -x $SH/ok.zag.out ]; then okout=$($SH/ok.zag.out); fi
    rm -f $SH/bad.zag.out
    badmsg=$($SH/zagc $SH/bad.zag 2>&1)
    if [ "$okout" = "720" ] && echo "$badmsg" | grep -q "VIOLATION in hot" && [ ! -e $SH/bad.zag.out ]; then
        echo "  ok  driver (compiles fact→720; rejects @realtime-violating program)"; pass=$((pass+1))
    else
        echo "  XX  driver (okout='$okout', bad='$badmsg')"; fail=$((fail+1))
    fi

    # Stage C progress: self-hosted zagc compiles structs + enums (field access
    # disambiguation, struct literals, enum constants) to correct native code.
    printf 'struct Point { x: i32, y: i32 }\nenum Tag { Lo, Hi }\nfn dist2(p: Point) i32 { return p.x * p.x + p.y * p.y; }\nfn pick(t: Tag) i32 { if (t == Tag.Hi) { return 100; } return 1; }\nfn main() void { let p: Point = Point{ .x = 3, .y = 4 }; print_i32(dist2(p) + pick(Tag.Hi)); }\n' > $SH/se.zag
    $SH/zagc $SH/se.zag >/dev/null 2>&1
    seout=""
    if [ -x $SH/se.zag.out ]; then seout=$($SH/se.zag.out); fi
    if [ "$seout" = "125" ]; then
        echo "  ok  stage-c (structs + enums: dist2(3,4)+pick(Hi)=125)"; pass=$((pass+1))
    else
        echo "  XX  stage-c (got '$seout', want 125)"; fail=$((fail+1))
    fi

    # Stage C / generics: self-hosted zagc monomorphizes generic functions.
    printf 'fn id[T](x: T) T { return x; }\nfn add[T](a: T, b: T) T { return a + b; }\nfn main() void { print_i32(add[i32](id[i32](40), 2)); }\n' > $SH/gen.zag
    $SH/zagc $SH/gen.zag >/dev/null 2>&1
    genout=""
    if [ -x $SH/gen.zag.out ]; then genout=$($SH/gen.zag.out); fi
    if [ "$genout" = "42" ]; then
        echo "  ok  generics (monomorphize id[i32]/add[i32] → 42)"; pass=$((pass+1))
    else
        echo "  XX  generics (got '$genout', want 42)"; fail=$((fail+1))
    fi

    # Generic STRUCTS: monomorphize struct + generic fns over it, two type args.
    printf 'struct Pair[T] { a: T, b: T }\nfn sum[T](p: Pair[T]) T { return p.a + p.b; }\nfn make_pair[T](x: T, y: T) Pair[T] { return Pair[T]{ .a = x, .b = y }; }\nfn main() void {\n    let p: Pair[i32] = make_pair[i32](30, 12);\n    print_i32(sum[i32](p));\n    let q: Pair[i64] = Pair[i64]{ .a = 100, .b = 23 };\n    print_i32(sum[i64](q));\n}\n' > $SH/gs.zag
    $SH/zagc $SH/gs.zag >/dev/null 2>&1
    gsout=""
    if [ -x $SH/gs.zag.out ]; then gsout=$($SH/gs.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$gsout" = "42 123" ]; then
        echo "  ok  generic structs (Pair[i32]→42, Pair[i64]→123)"; pass=$((pass+1))
    else
        echo "  XX  generic structs (got '$gsout', want '42 123')"; fail=$((fail+1))
    fi

    # @-builtins + casts: @sizeOf (direct & generic-substituted) and `as` casts.
    printf 'fn esize[T]() i32 { return @sizeOf[T](); }\nfn main() void {\n  let n: i64 = 300;\n  print_i32(n as i32);\n  print_i32(@sizeOf[i32]());\n  print_i32(esize[i32]());\n  print_i32(esize[f64]());\n}\n' > $SH/bi.zag
    $SH/zagc $SH/bi.zag >/dev/null 2>&1
    biout=""
    if [ -x $SH/bi.zag.out ]; then biout=$($SH/bi.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$biout" = "300 4 4 8" ]; then
        echo "  ok  builtins (@sizeOf direct/generic + as cast)"; pass=$((pass+1))
    else
        echo "  XX  builtins (got '$biout', want '300 4 4 8')"; fail=$((fail+1))
    fi

    # @import: flat module merge + diamond dedup. m.zag defines square; the
    # diamond pulls c.zag in via two paths — it must appear exactly once.
    mkdir -p $SH/imp
    printf 'fn square(x: i32) i32 { return x * x; }\n' > $SH/imp/m.zag
    printf '@import("m.zag")\nfn main() void { print_i32(square(7)); }\n' > $SH/imp/use.zag
    $SH/zagc $SH/imp/use.zag >/dev/null 2>&1
    impout=""; if [ -x $SH/imp/use.zag.out ]; then impout=$($SH/imp/use.zag.out); fi
    printf 'fn fc() i32 { return 3; }\n' > $SH/imp/c.zag
    printf '@import("c.zag")\nfn fa() i32 { return 1; }\n' > $SH/imp/a.zag
    printf '@import("c.zag")\nfn fb() i32 { return 2; }\n' > $SH/imp/b.zag
    printf '@import("a.zag")\n@import("b.zag")\nfn main() void { print_i32(fa() + fb() + fc()); }\n' > $SH/imp/d.zag
    $SH/zagc $SH/imp/d.zag >/dev/null 2>&1
    dout=""; if [ -x $SH/imp/d.zag.out ]; then dout=$($SH/imp/d.zag.out); fi
    ndef=$(grep -c "int32_t fc(void) {" $SH/imp/d.zag.c 2>/dev/null)
    if [ "$impout" = "49" ] && [ "$dout" = "6" ] && [ "$ndef" = "1" ]; then
        echo "  ok  @import (flat merge square→49; diamond dedup fa+fb+fc=6, fc once)"; pass=$((pass+1))
    else
        echo "  XX  @import (impout='$impout' want 49; dout='$dout' want 6; fc defs=$ndef want 1)"; fail=$((fail+1))
    fi

    # @import runtime.c auto-linking: a module with an extern backed by a sibling
    # runtime.c — the driver must collect that .c and hand it to cc.
    mkdir -p $SH/rt
    printf '#include <stdint.h>\nint32_t add_in_c(int32_t a, int32_t b){ return a + b; }\n' > $SH/rt/runtime.c
    printf 'extern fn add_in_c(a: i32, b: i32) i32;\n' > $SH/rt/cmod.zag
    printf '@import("cmod.zag")\nfn main() void { print_i32(add_in_c(40, 2)); }\n' > $SH/rt/rtmain.zag
    $SH/zagc $SH/rt/rtmain.zag >/dev/null 2>&1
    rtout=""; if [ -x $SH/rt/rtmain.zag.out ]; then rtout=$($SH/rt/rtmain.zag.out); fi
    if [ "$rtout" = "42" ]; then
        echo "  ok  @import runtime.c auto-link (extern add_in_c → 42)"; pass=$((pass+1))
    else
        echo "  XX  @import runtime.c auto-link (got '$rtout', want 42)"; fail=$((fail+1))
    fi

    # @import ... as name (qualified): true namespacing. flat dup()=1 and the
    # qualified q.dup()=2 coexist; q.helper()'s internal dup() resolves to q__dup;
    # q.Box type / q.Box{} literal / q.unbox() all route through the q__ prefix.
    mkdir -p $SH/qi
    printf 'fn dup() i32 { return 1; }\n' > $SH/qi/flatmod.zag
    printf 'struct Box { v: i32 }\nfn dup() i32 { return 2; }\nfn helper() i32 { return dup() + 10; }\nfn unbox(b: Box) i32 { return b.v; }\n' > $SH/qi/qmod.zag
    printf '@import("flatmod.zag")\n@import("qmod.zag") as q\nfn main() void {\n  print_i32(dup());\n  print_i32(q.dup());\n  print_i32(q.helper());\n  let bx: q.Box = q.Box{ .v = 7 };\n  print_i32(q.unbox(bx));\n}\n' > $SH/qi/main.zag
    $SH/zagc $SH/qi/main.zag >/dev/null 2>&1
    qiout=""; if [ -x $SH/qi/main.zag.out ]; then qiout=$($SH/qi/main.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$qiout" = "1 2 12 7" ]; then
        echo "  ok  @import as name (namespacing: flat dup=1, q.dup=2, q.helper=12, q.unbox=7)"; pass=$((pass+1))
    else
        echo "  XX  @import as name (got '$qiout', want '1 2 12 7')"; fail=$((fail+1))
    fi

    # tagged unions + statement switch: union construction (tag + payload),
    # switch over a union tag with |capture|, and switch over a plain enum.
    printf 'enum OpClass { Numeric, Control, Memory }\nunion WasmOp { local_get: i32, i32_const: i64, i32_add: bool }\nfn classify(op: WasmOp) OpClass {\n  let cls: OpClass = OpClass.Control;\n  switch (op) {\n    .local_get => |idx| { cls = OpClass.Memory; }\n    .i32_const => |v| { cls = OpClass.Numeric; }\n    .i32_add => |_x| { cls = OpClass.Numeric; }\n  }\n  return cls;\n}\nfn code(c: OpClass) i32 {\n  let r: i32 = 0;\n  switch (c) { .Numeric => { r = 1; } .Control => { r = 2; } .Memory => { r = 3; } }\n  return r;\n}\nfn main() void {\n  let a: WasmOp = WasmOp{ .local_get = 5 };\n  let b: WasmOp = WasmOp{ .i32_const = 42 };\n  print_i32(code(classify(a)));\n  print_i32(code(classify(b)));\n}\n' > $SH/uni.zag
    $SH/zagc $SH/uni.zag >/dev/null 2>&1
    uniout=""; if [ -x $SH/uni.zag.out ]; then uniout=$($SH/uni.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$uniout" = "3 1" ]; then
        echo "  ok  unions + switch (union tag/payload + |cap|; enum switch → 3 1)"; pass=$((pass+1))
    else
        echo "  XX  unions + switch (got '$uniout', want '3 1')"; fail=$((fail+1))
    fi

    # []u8 strings: string literals → ZagSliceU8, print_str, @strLen, @strEq, and
    # []u8 slicing s[lo..hi] / open-ended s[lo..].
    printf 'fn first3(s: []u8) []u8 { return s[0..3]; }\nfn rest(s: []u8) []u8 { return s[2..]; }\nfn main() void {\n  print_str("hi");\n  print_i32(@strLen("abc"));\n  print_i32(@strEq("ab", "ab"));\n  print_str(first3("hello"));\n  print_str(rest("hello"));\n  print_i32(first3("hello").len);\n}\n' > $SH/str.zag
    $SH/zagc $SH/str.zag >/dev/null 2>&1
    strout=""; if [ -x $SH/str.zag.out ]; then strout=$($SH/str.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$strout" = "hi 3 1 hel llo 3" ]; then
        echo "  ok  []u8 strings + slicing (literals/print_str/@strLen/@strEq; s[0..3]=hel, s[2..]=llo)"; pass=$((pass+1))
    else
        echo "  XX  []u8 strings + slicing (got '$strout', want 'hi 3 1 hel llo 3')"; fail=$((fail+1))
    fi

    # Generic heap container (the ArrayList pattern): generic struct + extern
    # malloc + @sizeOf[T] + `as *T` + pointer indexing. zagc emits the .c; we
    # link std/runtime.c (the self-hosted driver does not auto-link it yet).
    printf 'extern fn _zag_malloc(n: i32) *i8 @alloc @panic;\nstruct Vec[T] { data: *T, len: i32, cap: i32 }\nfn vnew[T](cap: i32) Vec[T] { let r: *i8 = _zag_malloc(cap * @sizeOf[T]()); return Vec[T]{ .data = r as *T, .len = 0, .cap = cap }; }\nfn vset[T](v: *Vec[T], i: i32, x: T) void { v.*.data[i] = x; }\nfn vget[T](v: Vec[T], i: i32) T { return v.data[i]; }\nfn main() void { let v: Vec[i32] = vnew[i32](4); vset[i32](&v, 0, 10); vset[i32](&v, 1, 32); print_i32(vget[i32](v, 0) + vget[i32](v, 1)); }\n' > $SH/vec.zag
    $SH/zagc $SH/vec.zag >/dev/null 2>&1   # writes vec.zag.c (link fails: no runtime.c — expected)
    vout=""
    if cc $SH/vec.zag.c std/runtime.c -o $SH/vec 2>/dev/null; then vout=$($SH/vec); fi
    if [ "$vout" = "42" ]; then
        echo "  ok  generic heap container (Vec[i32] via malloc/@sizeOf/as*T → 42)"; pass=$((pass+1))
    else
        echo "  XX  generic heap container (got '$vout', want 42)"; fail=$((fail+1))
    fi
else
    echo "  XX  driver (zagc failed to build)"; fail=$((fail+1))
fi

echo "════ selfhost pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
