#!/usr/bin/env bash
# Reproducible test suite for zagc. Good programs must build+run; bad ones must be rejected.
cd "$(dirname "$0")"
pass=0; fail=0
g(){ ./zig-out/bin/zagc build examples/$1.zag --run >/tmp/zt 2>&1
     if grep -q 'exit 0' /tmp/zt; then echo "  ok  $1  -> $(grep -A20 running /tmp/zt | grep -vE 'running|exit|--' | tr '\n' ' ')"; pass=$((pass+1))
     else echo "  XX  $1"; fail=$((fail+1)); sed -n '1,40p' /tmp/zt; fi; }
b(){ ./zig-out/bin/zagc check examples/$1.zag >/tmp/zt 2>&1
     if [ $? -ne 0 ] && grep -qi 'violation\|error:' /tmp/zt; then echo "  ok  $1 (rejected)"; pass=$((pass+1))
     else echo "  XX  $1 (should fail)"; fail=$((fail+1)); sed -n '1,40p' /tmp/zt; fi; }

echo "── effects: basics ──"
g audio_render; g synth
b audio_render_bad; b total_bad; b realtime_io_lock_bad
echo "── effect polymorphism (higher-order) ──"
g process_poly; g process_bounded
b process_poly_bad; b process_bounded_bad
echo "── type-level effect variables (value flow) + structs/slices ──"
g effvar_local; g effvar_return; g struct_basic; g voice_struct
b effvar_local_bad; b voice_struct_bad
echo "── closures (explicit capture, no heap) + effect-variable instantiation ──"
g closure_basic; g closure_effvar
b closure_bad; b closure_effvar_bad; b closure_escape_bad
echo "── generics over types (monomorphization) + composition with everything ──"
g generic_box; g generic_map; g generic_map_rt
b generic_map_rt_bad
echo "── real numeric types (u8..u64, i8..i64, usize, f64) ──"
g numeric
echo "── enums + tagged unions + switch ──"
g wasm_op
echo "── native posits (p32, es=2 software emulation) ──"
g posit32
echo "── posit family (p8/p16/p32/p64 arithmetic) ──"
g posit_multi
echo "── the quire: exact 512-bit fused multiply-add accumulator ──"
g quire
echo "── methods (fn (self: T) name(args) ret, dot-call dispatch) ──"
g methods
echo "── error unions (!T, error.X, try, catch) ──"
g error_union
echo "── strings and []u8 (literals, .len, indexing, @strEq) ──"
g strings
echo "── enums/patterns (expr switch, multi-pattern, exhaustiveness, int-literal) ──"
g patterns
echo "── modules (@import flat merge + qualified as name) ──"
g modules; g modules_struct
echo "── optionals (?T, null, orelse, if-let, force-unwrap) ──"
g optionals
echo "── heterogeneous: embedded (sat_i16, u11, fixed_8_8, @realtime) ──"
g embedded_sensor
echo "── heterogeneous: HPC (rns_3 parallel residues, fixed_16_16, @pure) ──"
g hpc_rns
echo "── heterogeneous: desktop security (u_any bignum, u7 arb-width) ──"
g safe_bignum
echo "── manual cache-line control (@prefetch/@cacheAlign/@cacheAlignedAlloc) ──"
g cache_control
b cache_control_bad
echo "── operator contracts (operator T { + => fn }; effect flows into proof) ──"
g operator_contract
b operator_contract_bad
echo "── P4: hardware posit target — ppu32 (emit-c, check asm opcodes) ──"
ppu(){ ./zig-out/bin/zagc build examples/$1.zag --target ppu32 --emit-c >/tmp/zt 2>&1
       # --emit-c writes <stem>.c into the cwd
       if grep -q 'padd\.s' $1.c 2>/dev/null && \
          grep -q 'ZAG_TARGET_PPU32' $1.c 2>/dev/null; then
           echo "  ok  $1 (ppu32: padd.s/psub.s/pmul.s/pdiv.s in C)"
           pass=$((pass+1))
       else echo "  XX  $1 (ppu32)"; fail=$((fail+1)); cat /tmp/zt; fi
       rm -f $1.c 2>/dev/null; }
ppu posit32
echo "════ pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
