#!/usr/bin/env bash
# Optimizer suite for the native x86-64 backend (selfhost/native/optimize.zag):
# constant-stack elimination + constant folding + gated immediate-form + dead
# pure-write removal. Two things are checked:
#   (1) CORRECTNESS — every program returns the SAME value it does with the
#       optimizer turned OFF (regalloc→peephole only). A behaviour change is a
#       catastrophic bug, so this is the bar that matters most.
#   (2) THE WIN ACTUALLY FIRES — folded constants appear as immediates in the
#       machine code and the push/pop temporary traffic drops vs the baseline.
# The whole pipeline is Zag — no cc/as/ld/libc.
cd "$(dirname "$0")/.."    # zag-poc root
pass=0; fail=0

# Build the optimizing driver (znc).
if ! ./zagc build selfhost/native/znc.zag >/tmp/zo_build 2>&1; then
    echo "  XX  znc driver build"; sed -n '1,20p' /tmp/zo_build
    echo "════ optimize pass=0 fail=1 ════"; exit 1
fi
cp selfhost/native/znc.zag.out /tmp/zo_opt
OPT=/tmp/zo_opt

# Build a BASELINE driver with the optimize() call neutered (regalloc→peephole),
# to differentially compare behaviour and measure the reduction.
sed 's/let prog3: ArrayList\[Instr\] = optimize(prog2);/let prog3: ArrayList[Instr] = prog2;/' \
    selfhost/native/znc.zag > selfhost/native/znc_optbase.zag
if ! ./zagc build selfhost/native/znc_optbase.zag >/tmp/zo_bbuild 2>&1; then
    echo "  XX  baseline driver build"; sed -n '1,20p' /tmp/zo_bbuild
    rm -f selfhost/native/znc_optbase.zag*; echo "════ optimize pass=0 fail=1 ════"; exit 1
fi
cp selfhost/native/znc_optbase.zag.out /tmp/zo_base
BASE=/tmp/zo_base
rm -f selfhost/native/znc_optbase.zag selfhost/native/znc_optbase.zag.out selfhost/native/znc_optbase.zag.c

# eq <name> <source>: optimized output/exit MUST equal baseline output/exit.
eq(){
    printf '%s' "$2" > zo_src.zag
    "$BASE" zo_src.zag -o /tmp/zo_b >/dev/null 2>&1; bo=$(/tmp/zo_b 2>/dev/null); be=$?
    "$OPT"  zo_src.zag -o /tmp/zo_o >/dev/null 2>&1; oo=$(/tmp/zo_o 2>/dev/null); oe=$?
    if [ "$bo" = "$oo" ] && [ "$be" = "$oe" ]; then
        echo "  ok  $1 (out='$oo' exit=$oe == baseline)"; pass=$((pass+1))
    else
        echo "  XX  $1 (baseline out='$bo' exit=$be ; optimized out='$oo' exit=$oe)"; fail=$((fail+1))
    fi
    rm -f /tmp/zo_b /tmp/zo_o zo_src.zag
}

echo "── correctness: optimized ≡ baseline (semantics preserved) ──"
eq "constant fold 2+3*4"      'fn main() i32 { return 2 + 3 * 4; }'
eq "constant nest"            'fn main() i32 { return (10-2)*(3+1) - 30; }'
eq "constant div/mod/mul"     'fn main() i32 { return (20/4)+(20%6)+(3*7)-(8/2); }'
eq "i64 const > int32"        'fn main() i32 { let b: i64 = 5000000000 + 1000000000; if (b == 6000000000) { return 11; } return 0; }'
eq "int32 overflow wraps"     'fn main() i32 { let n: i32 = 2000000000; return (n + n) % 256; }'
eq "negatives folded"         'fn main() i32 { return 0 - 5 + 3 * (0 - 2) + 100; }'
eq "immediate-form mix"       'fn f(a: i32, b: i32) i32 { return (a+5)+(b+7)+(2*3); } fn main() i32 { return f(10,20); }'
eq "div-by-zero still traps"  'fn main() i32 { let a: i32 = 100; return (a / 0 == 0); }'
eq "branch comparison"        'fn main() i32 { let x: i32 = 7; if (x < 10 && x > 5) { return 33; } return 0; }'
eq "recursion fib(10)"        'fn fib(n: i32) i32 { if (n<2) { return n; } return fib(n-1)+fib(n-2); } fn main() i32 { return fib(10); }'
eq "while-loop sum"           'fn main() i32 { let s: i32 = 0; let i: i32 = 1; while (i<=10) { s=s+i; i=i+1; } return s; }'
eq "struct fields const"      'struct P { x: i32, y: i32 } fn main() i32 { let p: P = P{ .x = 30+0, .y = 6*2 }; return p.x + p.y; }'
eq "float unaffected"         'fn main() i32 { let x: f64 = 1.5; let y: f64 = 2.5; if (x+y == 4.0) { return 7; } return 0; }'

# A heavily-constant program: assert the optimizer (a) keeps the right answer
# and (b) FOLDS — the result constant appears as an immediate and the temporary
# push/pop traffic collapses relative to the baseline.
echo "── the win actually fires (objdump evidence) ──"
printf 'fn main() i32 { return (2+3*4) + (10-2)*(3+1) + (100/7) + (2*2*2*2); }' > zo_src.zag
"$BASE" zo_src.zag -o /tmp/zo_b >/dev/null 2>&1
"$OPT"  zo_src.zag -o /tmp/zo_o >/dev/null 2>&1
/tmp/zo_b >/dev/null 2>&1; be=$?
/tmp/zo_o >/dev/null 2>&1; oe=$?
seg(){ readelf -l "$1" 2>/dev/null | awk '/LOAD/{getline; print strtonum($1); exit}'; }
pp(){ dd if="$1" of=/tmp/zo_bin bs=1 count="$(seg "$1")" 2>/dev/null
      objdump -b binary -m i386:x86-64 -D --adjust-vma=0x400000 /tmp/zo_bin 2>/dev/null | grep -cE "$2"; }
bpush=$(pp /tmp/zo_b '\bpush\b'); opush=$(pp /tmp/zo_o '\bpush\b')
if [ "$be" = "$oe" ]; then echo "  ok  const-heavy exit matches (exit=$oe)"; pass=$((pass+1));
else echo "  XX  const-heavy exit (base=$be opt=$oe)"; fail=$((fail+1)); fi
if [ "$opush" -lt "$bpush" ]; then echo "  ok  push count dropped ($bpush → $opush)"; pass=$((pass+1));
else echo "  XX  push count not reduced ($bpush → $opush)"; fail=$((fail+1)); fi
# the final constant must appear folded as an immediate (mov $0x...,%rax style)
dd if=/tmp/zo_o of=/tmp/zo_bin bs=1 count="$(seg /tmp/zo_o)" 2>/dev/null
if objdump -b binary -m i386:x86-64 -D --adjust-vma=0x400000 /tmp/zo_bin 2>/dev/null | grep -qE 'mov +\$0x[0-9a-f]+,%rax'; then
    echo "  ok  folded constant present as immediate"; pass=$((pass+1))
else
    echo "  XX  no folded immediate found"; fail=$((fail+1))
fi
rm -f /tmp/zo_b /tmp/zo_o /tmp/zo_bin zo_src.zag

echo "════ optimize pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
