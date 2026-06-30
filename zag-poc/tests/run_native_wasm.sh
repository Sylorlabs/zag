#!/usr/bin/env bash
# znc WebAssembly binary emission suite (self-contained — no wasm-ld/llvm).
set -eu
cd "$(dirname "$0")/.."
pass=0; fail=0
SCRIPT_DIR="$(dirname "$0")"
WASM_HOST_JS="$SCRIPT_DIR/wasm_invoke.js"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"

if [ ! -x ./znc ]; then
    echo "  XX  ./znc missing — run ./bootstrap.sh first"
    echo "════ native-wasm pass=0 fail=1 ════"; exit 1
fi
ZNC=./znc

wasm_validate(){ local wf="$1"
    local ok=1
    # magic \0asm
    local b0 b1 b2 b3
    b0=$(od -An -tx1 -N1 "$wf" | tr -d ' ')
    b1=$(od -An -tx1 -j1 -N1 "$wf" | tr -d ' ')
    b2=$(od -An -tx1 -j2 -N1 "$wf" | tr -d ' ')
    b3=$(od -An -tx1 -j3 -N1 "$wf" | tr -d ' ')
    [ "$b0" = "00" ] && [ "$b1" = "61" ] && [ "$b2" = "73" ] && [ "$b3" = "6d" ] || { ok=0; echo "      bad magic"; }
    # version 1
    local v0 v1 v2 v3
    v0=$(od -An -tx1 -j4 -N1 "$wf" | tr -d ' ')
    v1=$(od -An -tx1 -j5 -N1 "$wf" | tr -d ' ')
    v2=$(od -An -tx1 -j6 -N1 "$wf" | tr -d ' ')
    v3=$(od -An -tx1 -j7 -N1 "$wf" | tr -d ' ')
    [ "$v0" = "01" ] && [ "$v1" = "00" ] && [ "$v2" = "00" ] && [ "$v3" = "00" ] || { ok=0; echo "      bad version"; }
    # must contain type(1), function(3), export(7), code(10) sections
    od -An -tx1 "$wf" | grep -q ' 01 ' || { ok=0; echo "      missing type section"; }
    od -An -tx1 "$wf" | grep -q ' 03 ' || { ok=0; echo "      missing function section"; }
    od -An -tx1 "$wf" | grep -q ' 07 ' || { ok=0; echo "      missing export section"; }
    od -An -tx1 "$wf" | grep -q ' 0a ' || { ok=0; echo "      missing code section"; }
    # exported symbol name for wasmtime --invoke
    strings "$wf" 2>/dev/null | grep -qx 'main' || { ok=0; echo "      missing exported main"; }
    # no stub markers in binary (strings)
    if strings "$wf" 2>/dev/null | grep -qE 'unsupported|unimplemented|stub|TODO'; then
        ok=0; echo "      found stub marker string in wasm output"
    fi
    echo "$ok"
}

wasm_build(){ local src="$1" out="$2"
    "$ZNC" "$src" --target wasm -o "$out" >/tmp/znc_wasm_out 2>&1
}

# Harsh runtime verification: invoke exported main() and check i32 return.
# Prefer wasmtime + tests/wasmtime_run.sh (env::print_* host stubs);
# fall back to tests/wasm_invoke.js when wasmtime/cargo unavailable.
# SKIP only when neither runner exists; FAIL if a runner is present but breaks.
wasm_runtime_expect(){ local wf="$1" expect="$2" label="$3"
    if [ -x "$WASMTIME_RUN" ]; then
        local rt=0
        "$WASMTIME_RUN" "$wf" "$expect" >/tmp/wasm_rt_out 2>/tmp/wasm_rt_err || rt=$?
        if [ "$rt" -eq 0 ]; then
            echo "  ok  runtime $label (wasmtime main() → $expect)"
            return 0
        fi
        if [ "$rt" -eq 127 ]; then
            : # wasmtime/cargo missing — try node below
        else
            echo "  XX  runtime $label (wasmtime host failed)" >&2
            sed -n '1,5p' /tmp/wasm_rt_err >&2
            return 1
        fi
    fi
    if command -v node >/dev/null 2>&1 && [ -f "$WASM_HOST_JS" ]; then
        if node "$WASM_HOST_JS" "$wf" "$expect" >/tmp/wasm_rt_out 2>/tmp/wasm_rt_err; then
            echo "  ok  runtime $label (node host main() → $expect)"
            return 0
        fi
        echo "  XX  runtime $label (node host failed)"
        sed -n '1,5p' /tmp/wasm_rt_err
        return 1
    fi
    echo "  --  SKIP runtime $label (no wasmtime/cargo or node; install: curl -sSf https://wasmtime.dev/install.sh | bash)"
    return 2
}

echo "── znc WASM backend (selfhost/native/wasm.zag) ──"

wasm_build examples/wasm_ret42.zag /tmp/wasm_ret42.wasm
r=$(wasm_validate /tmp/wasm_ret42.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm_ret42.zag (magic/version/sections/export main)"; pass=$((pass+1))
else
    echo "  XX  wasm_ret42.zag"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_ret42.wasm 42 "return literal 42"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

printf 'fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); } fn main() i32 { return fib(10); }' > /tmp/wasm_fib.zag
wasm_build /tmp/wasm_fib.zag /tmp/wasm_fib.wasm
r=$(wasm_validate /tmp/wasm_fib.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm recursion + if/else"; pass=$((pass+1))
else
    echo "  XX  wasm recursion + if/else"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_fib.wasm 55 "fib(10)"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

printf 'fn main() i32 { let s: i32 = 0; let i: i32 = 1; while (i <= 10) { s = s + i; i = i + 1; } return s; }' > /tmp/wasm_while.zag
wasm_build /tmp/wasm_while.zag /tmp/wasm_while.wasm
r=$(wasm_validate /tmp/wasm_while.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm while loop"; pass=$((pass+1))
else
    echo "  XX  wasm while loop"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_while.wasm 55 "sum 1..10"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

printf 'struct P { x: i32, y: i32 } fn main() i32 { let p: P = P{ .x = 30, .y = 12 }; return p.x + p.y; }' > /tmp/wasm_struct.zag
wasm_build /tmp/wasm_struct.zag /tmp/wasm_struct.wasm
r=$(wasm_validate /tmp/wasm_struct.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm struct fields"; pass=$((pass+1))
else
    echo "  XX  wasm struct fields"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_struct.wasm 42 "struct field add"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

wasm_build examples/wasm_demo.zag /tmp/wasm_demo.wasm
r=$(wasm_validate /tmp/wasm_demo.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm_demo.zag"; pass=$((pass+1))
else
    echo "  XX  wasm_demo.zag"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_demo.wasm 0 "wasm_demo main"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

wasm_build examples/numeric.zag /tmp/wasm_numeric.wasm
r=$(wasm_validate /tmp/wasm_numeric.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  numeric.zag → .wasm"; pass=$((pass+1))
else
    echo "  XX  numeric.zag → .wasm"; echo "$r"; fail=$((fail+1))
fi

wasm_build examples/wasm_float.zag /tmp/wasm_float.wasm
r=$(wasm_validate /tmp/wasm_float.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm_float.zag (f32/f64 locals + add/mul)"; pass=$((pass+1))
else
    echo "  XX  wasm_float.zag"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_float.wasm 8 "f32/f64 (1.5+2.5)*2"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

wasm_build examples/wasm_op.zag /tmp/wasm_op.wasm
r=$(wasm_validate /tmp/wasm_op.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm_op.zag (enum + union switch)"; pass=$((pass+1))
else
    echo "  XX  wasm_op.zag"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_op.wasm 0 "wasm_op enum/union switch"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

# union literal as call argument (expression position, not let binding)
printf 'enum OpClass { Numeric, Control, Memory } union WasmOp { local_get: i32, i32_const: i64, i32_add: bool } fn classify(op: WasmOp) OpClass { let cls: OpClass = OpClass.Control; switch (op) { .local_get => |_idx| { cls = OpClass.Memory; } .i32_const => |_v| { cls = OpClass.Numeric; } .i32_add => |_x| { cls = OpClass.Numeric; } } return cls; } fn code(c: OpClass) i32 { let r: i32 = 0; switch (c) { .Numeric => { r = 1; } .Control => { r = 2; } .Memory => { r = 3; } } return r; } fn main() i32 { return code(classify(WasmOp{ .i32_const = 42 })); }' > /tmp/wasm_union_lit_arg.zag
wasm_build /tmp/wasm_union_lit_arg.zag /tmp/wasm_union_lit_arg.wasm
r=$(wasm_validate /tmp/wasm_union_lit_arg.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm union literal as call arg"; pass=$((pass+1))
else
    echo "  XX  wasm union literal as call arg"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_union_lit_arg.wasm 1 "union literal call arg"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

# nested union switch (outer capture feeds inner union literal payload)
printf 'enum OpClass { Numeric, Control, Memory } union WasmOp { local_get: i32, i32_const: i64, i32_add: bool } fn classify(op: WasmOp) OpClass { let cls: OpClass = OpClass.Control; switch (op) { .local_get => |_idx| { cls = OpClass.Memory; } .i32_const => |_v| { cls = OpClass.Numeric; } .i32_add => |_x| { cls = OpClass.Numeric; } } return cls; } fn code(c: OpClass) i32 { let r: i32 = 0; switch (c) { .Numeric => { r = 1; } .Control => { r = 2; } .Memory => { r = 3; } } return r; } fn main() i32 { let r: i32 = 0; switch (WasmOp{ .local_get = 7 }) { .local_get => |idx| { switch (WasmOp{ .i32_const = idx }) { .i32_const => |_v| { r = code(classify(WasmOp{ .i32_const = 99 })); } .local_get => |_i| { r = 0; } .i32_add => |_x| { r = 0; } } } .i32_const => |_v| { r = 0; } .i32_add => |_x| { r = 0; } } return r; }' > /tmp/wasm_nested_union_sw.zag
wasm_build /tmp/wasm_nested_union_sw.zag /tmp/wasm_nested_union_sw.wasm
r=$(wasm_validate /tmp/wasm_nested_union_sw.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm nested union switch + literal subject"; pass=$((pass+1))
else
    echo "  XX  wasm nested union switch"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_nested_union_sw.wasm 1 "nested union switch"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

# enum + union combo with struct literal call arg
printf 'enum Kind { A, B } union U { a: i32, b: Kind } struct P { x: i32, y: i32 } fn tag(u: U) i32 { let r: i32 = 0; switch (u) { .a => |v| { r = v; } .b => |k| { switch (k) { .A => { r = 10; } .B => { r = 20; } } } } return r; } fn add(p: P) i32 { return p.x + p.y; } fn main() i32 { return tag(U{ .b = Kind.B }) + add(P{ .x = 3, .y = 4 }); }' > /tmp/wasm_enum_union_combo.zag
wasm_build /tmp/wasm_enum_union_combo.zag /tmp/wasm_enum_union_combo.wasm
r=$(wasm_validate /tmp/wasm_enum_union_combo.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm enum+union combo + struct literal arg"; pass=$((pass+1))
else
    echo "  XX  wasm enum+union combo"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_enum_union_combo.wasm 27 "enum+union combo"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

# empty-payload union variant (bool placeholder) via expression-position literal
printf 'union W { noop: bool, val: i32 } fn pick(w: W) i32 { switch (w) { .noop => |_x| { return 0; } .val => |v| { return v; } } return -1; } fn main() i32 { return pick(W{ .noop = true }) + pick(W{ .val = 11 }); }' > /tmp/wasm_union_empty.zag
wasm_build /tmp/wasm_union_empty.zag /tmp/wasm_union_empty.wasm
r=$(wasm_validate /tmp/wasm_union_empty.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm empty-payload union variant literal"; pass=$((pass+1))
else
    echo "  XX  wasm empty-payload union variant"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_union_empty.wasm 11 "empty payload union"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

# f32/f64 edge cases: f32 add, f32→f64 cast, f64 mul, trunc to i32
printf 'fn main() i32 { let a: f32 = 1.5; let b: f32 = 2.5; let c: f32 = a + b; let d: f64 = c as f64; let e: f64 = d * 1.75; return e as i32; }' > /tmp/wasm_float_edge.zag
wasm_build /tmp/wasm_float_edge.zag /tmp/wasm_float_edge.wasm
r=$(wasm_validate /tmp/wasm_float_edge.wasm)
if [ "$(echo "$r" | tail -1)" = "1" ]; then
    echo "  ok  wasm f32/f64 edge (cast + mul + trunc)"; pass=$((pass+1))
else
    echo "  XX  wasm f32/f64 edge"; echo "$r"; fail=$((fail+1))
fi
set +e
wasm_runtime_expect /tmp/wasm_float_edge.wasm 7 "f32/f64 edge"; rt=$?
set -e
case "$rt" in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)) ;;
    2) : ;;
esac

echo "════ native-wasm pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]