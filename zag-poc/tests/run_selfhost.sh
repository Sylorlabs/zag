#!/usr/bin/env bash
# Self-hosted compiler tests: each stage of the Zag-in-Zag compiler must build
# (via the bootstrap zig zagc) and produce the expected result.
cd "$(dirname "$0")/.."
ZAGC=./zagc
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

    # qualified import of a GENERIC module: g.Box[i32] / g.make_box[i32] /
    # g.unwrap[i32] — type substitution must descend into Base[args] so the
    # module's own generic types get the g__ prefix (g__Box[i32] → g__Box_i32).
    mkdir -p $SH/qg
    printf 'struct Box[T] { v: T }\nfn make_box[T](x: T) Box[T] { return Box[T]{ .v = x }; }\nfn unwrap[T](b: Box[T]) T { return b.v; }\n' > $SH/qg/gmod.zag
    printf '@import("gmod.zag") as g\nfn main() void {\n  let b: g.Box[i32] = g.make_box[i32](42);\n  print_i32(g.unwrap[i32](b));\n}\n' > $SH/qg/main.zag
    $SH/zagc $SH/qg/main.zag >/dev/null 2>&1
    qgout=""; if [ -x $SH/qg/main.zag.out ]; then qgout=$($SH/qg/main.zag.out); fi
    if [ "$qgout" = "42" ]; then
        echo "  ok  @import as name (generic): g.Box[i32]/g.make_box[i32]/g.unwrap[i32] → 42"; pass=$((pass+1))
    else
        echo "  XX  @import as name (generic) (got '$qgout', want 42)"; fail=$((fail+1))
    fi

    # The capstone: the self-hosted compiler compiles the real std/map.zag
    # (StringMap[V]) imported `as map` — generics + *T pointers + slice/pointer
    # indexing + ?V optionals + orelse + runtime.c auto-link, all at once.
    printf '@import("%s/std/map.zag") as map\nfn main() void {\n  let m: map.StringMap[i32] = map.make[i32](8);\n  map.put[i32](&m, "x", 10);\n  map.put[i32](&m, "y", 20);\n  map.put[i32](&m, "z", 30);\n  print_i32(map.get[i32](m, "x") orelse 0);\n  print_i32(map.get[i32](m, "y") orelse 0);\n  print_i32(map.get[i32](m, "z") orelse 0);\n  print_i32(map.get[i32](m, "missing") orelse 99);\n  print_i32(map.count[i32](m));\n}\n' "$(pwd)" > $SH/mapuse.zag
    $SH/zagc $SH/mapuse.zag >/dev/null 2>&1
    mapout=""; if [ -x $SH/mapuse.zag.out ]; then mapout=$($SH/mapuse.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$mapout" = "10 20 30 99 3" ]; then
        echo "  ok  std/map.zag (as map): StringMap[i32] put/get/orelse/count → 10 20 30 99 3"; pass=$((pass+1))
    else
        echo "  XX  std/map.zag (as map) (got '$mapout', want '10 20 30 99 3')"; fail=$((fail+1))
    fi

    # char literals 'x' / '\n' → integer codes (the self-hosted lexer needs these
    # to lex its own source, which is full of c == '\n' style comparisons).
    printf "fn main() void { print_i32('A'); print_i32('z' - 'a'); print_i32('\\\\n'); }\n" > $SH/chr.zag
    $SH/zagc $SH/chr.zag >/dev/null 2>&1
    chrout=""; if [ -x $SH/chr.zag.out ]; then chrout=$($SH/chr.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$chrout" = "65 25 10" ]; then
        echo "  ok  char literals ('A'=65, 'z'-'a'=25, '\\n'=10)"; pass=$((pass+1))
    else
        echo "  XX  char literals (got '$chrout', want '65 25 10')"; fail=$((fail+1))
    fi

    # ── C3 FIXPOINT ──────────────────────────────────────────────────────────
    # The self-hosted compiler compiles its OWN source to a working zagc2; zagc2
    # recompiles that source to byte-identical C. True self-hosting (zagc2≡zagc3).
    ./zagc build selfhost/zagc.zag >/dev/null 2>&1          # zagc1 → C1 + zagc2
    cp selfhost/zagc.zag.c $SH/c3_C1.c 2>/dev/null
    cp selfhost/zagc.zag.out $SH/zagc2 2>/dev/null
    fixpoint="no"
    if [ -x $SH/zagc2 ]; then
        $SH/zagc2 build selfhost/zagc.zag >/dev/null 2>&1  # zagc2 → C2
        if [ -f selfhost/zagc.zag.c ] && diff -q $SH/c3_C1.c selfhost/zagc.zag.c >/dev/null 2>&1; then
            fixpoint="yes"
        fi
    fi
    rm -f selfhost/zagc.zag.c selfhost/zagc.zag.out $SH/c3_C1.c $SH/zagc2 2>/dev/null
    if [ "$fixpoint" = "yes" ]; then
        echo "  ok  C3 fixpoint (zagc compiles itself → zagc2 reproduces identical C)"; pass=$((pass+1))
    else
        echo "  XX  C3 fixpoint (zagc2 did not reproduce identical C)"; fail=$((fail+1))
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

    # optionals + orelse: ?T return (null + wrapped value), `orelse`, ?T let with
    # value/null/passthrough (no double-wrap).
    printf 'fn sd(a: i32, b: i32) ?i32 { if (b == 0) { return null; } return a / b; }\nfn pt(x: i32) ?i32 { return sd(x, 2); }\nfn main() void {\n  print_i32(sd(10, 2) orelse 0);\n  print_i32(sd(1, 0) orelse 99);\n  let x: ?i32 = 7;\n  print_i32(x orelse 0);\n  let y: ?i32 = null;\n  print_i32(y orelse 42);\n  let z: ?i32 = sd(20, 4);\n  print_i32(z orelse 0);\n  print_i32(pt(8) orelse 0);\n}\n' > $SH/opt.zag
    $SH/zagc $SH/opt.zag >/dev/null 2>&1
    optout=""; if [ -x $SH/opt.zag.out ]; then optout=$($SH/opt.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$optout" = "5 99 7 42 5 4" ]; then
        echo "  ok  optionals + orelse (?T return/let; null; orelse; passthrough → 5 99 7 42 5 4)"; pass=$((pass+1))
    else
        echo "  XX  optionals + orelse (got '$optout', want '5 99 7 42 5 4')"; fail=$((fail+1))
    fi

    # expression switch (switch as a value): enum exhaustive, union with |capture|,
    # and a switch with an `else` arm.
    printf 'enum Day { Mon, Tue, Wed }\nunion Val { num: i32, neg: i32 }\nfn dc(d: Day) i32 { return switch (d) { .Mon => 1, .Tue => 2, .Wed => 3, }; }\nfn ev(v: Val) i32 { return switch (v) { .num => |x| x, .neg => |x| 0 - x, }; }\nfn cl(d: Day) i32 { let c: i32 = switch (d) { .Mon => 10, else => 99, }; return c; }\nfn main() void {\n  print_i32(dc(Day.Tue));\n  print_i32(ev(Val{ .num = 42 }));\n  print_i32(ev(Val{ .neg = 5 }));\n  print_i32(cl(Day.Mon));\n  print_i32(cl(Day.Wed));\n}\n' > $SH/esw.zag
    $SH/zagc $SH/esw.zag >/dev/null 2>&1
    eswout=""; if [ -x $SH/esw.zag.out ]; then eswout=$($SH/esw.zag.out | tr '\n' ' ' | sed 's/ *$//'); fi
    if [ "$eswout" = "2 42 -5 10 99" ]; then
        echo "  ok  expression switch (enum/union value-switch + capture + else → 2 42 -5 10 99)"; pass=$((pass+1))
    else
        echo "  XX  expression switch (got '$eswout', want '2 42 -5 10 99')"; fail=$((fail+1))
    fi

    # pointer-base slicing: a struct's *u8 field sliced directly (container.data
    # pattern), backed by a sibling runtime.c.
    mkdir -p $SH/ps
    printf '#include <stdint.h>\nstatic uint8_t b[6]={\x27h\x27,\x27e\x27,\x27l\x27,\x27l\x27,\x27o\x27,0};\nuint8_t* mkbytes(void){ return b; }\n' > $SH/ps/runtime.c
    printf 'extern fn mkbytes() *u8;\n' > $SH/ps/cmod.zag
    printf '@import("cmod.zag")\nstruct Buf { data: *u8, n: i32 }\nfn view(b: Buf) []u8 { return b.data[1..4]; }\nfn main() void { let b: Buf = Buf{ .data = mkbytes(), .n = 5 }; print_str(view(b)); }\n' > $SH/ps/main.zag
    $SH/zagc $SH/ps/main.zag >/dev/null 2>&1
    psout=""; if [ -x $SH/ps/main.zag.out ]; then psout=$($SH/ps/main.zag.out); fi
    if [ "$psout" = "ell" ]; then
        echo "  ok  pointer-base slicing (struct *u8 field b.data[1..4] → ell)"; pass=$((pass+1))
    else
        echo "  XX  pointer-base slicing (got '$psout', want 'ell')"; fail=$((fail+1))
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

    # GPU/MLIR backend (selfhost/mlir.zag): the self-hosted zagc emits MLIR for
    # the GPU examples under `--target gpu-nvidia`. Verify the key dialect
    # constructs are present AND that there are ZERO stub/unsupported markers.
    mkdir -p $SH/gpu
    cp examples/gpu_matmul_mx.zag $SH/gpu/gpu_matmul_mx.zag
    cp examples/gpu_vsa_hd.zag    $SH/gpu/gpu_vsa_hd.zag
    NOSTUB='unsupported|unimplemented|stub|TODO|unhandled|= //|// closure|// unknown|<kernel>'
    # gpu_check <stem> <pattern...>: emit MLIR, assert all patterns present + no stubs.
    gpu_check(){ local stem="$1"; shift
        ( cd $SH/gpu && $SH/zagc build $stem.zag --target gpu-nvidia >/dev/null 2>&1 )
        local mf=$SH/gpu/$stem.mlir; local ok=1
        [ -f "$mf" ] || ok=0
        for pat in "$@"; do grep -q "$pat" "$mf" 2>/dev/null || { ok=0; echo "      missing: $pat"; }; done
        if grep -qE "$NOSTUB" "$mf" 2>/dev/null; then ok=0; echo "      found stub marker(s):"; grep -nE "$NOSTUB" "$mf" | head; fi
        # brace balance
        local o c; o=$(tr -cd '{' <"$mf" | wc -c); c=$(tr -cd '}' <"$mf" | wc -c)
        [ "$o" = "$c" ] || { ok=0; echo "      unbalanced braces ($o vs $c)"; }
        echo "$ok"
    }
    r1=$(gpu_check gpu_matmul_mx 'gpu.module @zag_kernels' 'gpu.func @matmulMxKernel' ' kernel {' 'f8E4M3FN' 'gpu.thread_id' 'gpu.block_id' 'func.func @tileSize' 'gpu.return' 'gpu.launch_func @zag_kernels::@matmulMxKernel')
    if [ "$(echo "$r1" | tail -1)" = "1" ]; then
        echo "  ok  gpu mlir matmul (kernels/dialects, real launch_func, no stubs)"; pass=$((pass+1))
    else
        echo "  XX  gpu mlir matmul"; echo "$r1"; fail=$((fail+1))
    fi
    r2=$(gpu_check gpu_vsa_hd 'gpu.module @zag_kernels' 'gpu.func @vsaBindKernel' ' kernel {' 'gpu.barrier' 'gpu.thread_id' 'arith.xori' 'arith.andi' 'func.func private @zag_l32_to_f32' 'gpu.launch_func @zag_kernels::')
    if [ "$(echo "$r2" | tail -1)" = "1" ]; then
        echo "  ok  gpu mlir vsa (bind XOR/popcount AND, l32 decls, barrier, no stubs)"; pass=$((pass+1))
    else
        echo "  XX  gpu mlir vsa"; echo "$r2"; fail=$((fail+1))
    fi
    # header must switch per target
    ( cd $SH/gpu && $SH/zagc build gpu_matmul_mx.zag --target gpu-amd >/dev/null 2>&1 )
    if grep -q 'AMD ROCDL/HIP' $SH/gpu/gpu_matmul_mx.mlir 2>/dev/null && \
       ( cd $SH/gpu && $SH/zagc build gpu_matmul_mx.zag --target gpu-vulkan >/dev/null 2>&1 ) && \
       grep -q 'Vulkan SPIR-V' $SH/gpu/gpu_matmul_mx.mlir 2>/dev/null; then
        echo "  ok  gpu mlir target header (amd → ROCDL, vulkan → SPIR-V)"; pass=$((pass+1))
    else
        echo "  XX  gpu mlir target header"; fail=$((fail+1))
    fi

    # ZIR: native MLIR-shaped IR (selfhost/zir.zag). The SAME in-memory IR
    # (AST→ZIR→fold→verify) feeds two backends. Prove: (1) --via-zir lowers
    # ZIR→C→cc→run with correct results; (2) constant folding really fires;
    # (3) the MLIR printer emits valid func/arith/memref/scf from the IR.
    printf 'fn fact(n: i32) i32 {\n    let r: i32 = 1;\n    if (n > 1) { r = n * fact(n - 1); }\n    return r;\n}\nfn konst() i32 { return (2 + 3) * 4; }\nfn main() void { print_i32(fact(5)); print_i32(konst()); }\n' > $SH/zir.zag
    zout=$($SH/zagc build $SH/zir.zag --via-zir --run 2>/dev/null | grep -E '^[0-9]+$' | tr '\n' ' ' | sed 's/ *$//')
    if [ "$zout" = "120 20" ]; then
        echo "  ok  zir backend (AST→ZIR→C→cc→run: fact(5)=120, konst=20)"; pass=$((pass+1))
    else
        echo "  XX  zir backend (got '$zout', want '120 20')"; fail=$((fail+1))
    fi
    # fold pass: (2+3)*4 must become a constant 20 in the IR
    if $SH/zagc zir $SH/zir.zag 2>/dev/null | grep -q 'arith.constant 20'; then
        echo "  ok  zir fold pass (constant-folds (2+3)*4 → 20)"; pass=$((pass+1))
    else
        echo "  XX  zir fold pass"; fail=$((fail+1))
    fi
    # MLIR printer emits structured dialects from the IR
    if $SH/zagc zir $SH/zir.zag 2>/dev/null | grep -q 'func.func @fact' && \
       $SH/zagc zir $SH/zir.zag 2>/dev/null | grep -q 'scf.if' && \
       $SH/zagc zir $SH/zir.zag 2>/dev/null | grep -q 'memref.alloca'; then
        echo "  ok  zir mlir printer (func.func/scf.if/memref from one IR)"; pass=$((pass+1))
    else
        echo "  XX  zir mlir printer"; fail=$((fail+1))
    fi
else
    echo "  XX  driver (zagc failed to build)"; fail=$((fail+1))
fi

echo "════ selfhost pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
