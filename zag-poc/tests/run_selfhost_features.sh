#!/usr/bin/env bash
# Tests for self-hosted *driver features* authored in Zag (selfhost/zagc.zag,
# selfhost/astjson.zag): `zag version` and `zag ast` (AST → JSON, zag.ast/v1).
# Kept separate from run_selfhost.sh so the two suites can evolve independently.
cd "$(dirname "$0")/.."
ZAGC=./zig-out/bin/zagc
pass=0; fail=0

# Build the self-hosted compiler via the Zig bootstrap.
$ZAGC build selfhost/zagc.zag >/dev/null 2>&1
if [ ! -x ./zagc ]; then
    echo "  XX  could not build self-hosted ./zagc via bootstrap"
    exit 1
fi

# ── version ──────────────────────────────────────────────────────────────────
echo "── selfhost feature: version ──"
v=$(./zagc version | head -1)
if echo "$v" | grep -q "self-hosted"; then
    echo "  ok  version ($v)"; pass=$((pass+1))
else
    echo "  XX  version: [$v]"; fail=$((fail+1))
fi

# ── ast → JSON ───────────────────────────────────────────────────────────────
echo "── selfhost feature: ast (AST→JSON) ──"
cat > /tmp/zfeat.zag <<'EOF'
fn sq(x: i32) i32 { return x * x; }
fn main() void { print_i32(sq(6)); }
EOF
j=$(./zagc ast /tmp/zfeat.zag 2>/dev/null)
if echo "$j" | grep -qF '"schema": "zag.ast/v1"' \
   && echo "$j" | grep -qF '"kind": "fn_decl"' \
   && echo "$j" | grep -qF '"name": "sq"' \
   && echo "$j" | grep -qF '"op": "*"'; then
    echo "  ok  ast (valid zag.ast/v1; fn_decl sq, bin op *)"; pass=$((pass+1))
else
    echo "  XX  ast JSON unexpected:"; echo "$j" | head -4
    fail=$((fail+1))
fi

rm -f zagc zagc.c /tmp/zfeat.zag /tmp/zfeat.zag.c /tmp/zfeat.zag.out 2>/dev/null
echo "════ selfhost-features pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
