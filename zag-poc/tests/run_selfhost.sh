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
else
    echo "  XX  driver (zagc failed to build)"; fail=$((fail+1))
fi

echo "════ selfhost pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
