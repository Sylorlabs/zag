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

echo "════ selfhost pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
