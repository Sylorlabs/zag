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

echo "════ selfhost pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
