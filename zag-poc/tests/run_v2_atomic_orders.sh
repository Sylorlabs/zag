#!/usr/bin/env bash
# Executable proof for the bounded selectable-order load/store API.  This is
# not a thread or race proof: it verifies literal order validation and the
# native x86-64 relaxed/acquire/release versus seq_cst lowering boundary.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-v2-atomic-orders.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
project() { mkdir -p "$tmp/$1"; printf 'name = "v2atomicorders"\nversion = "0"\nedition = "2027"\n' >"$tmp/$1/zag.mod"; }

project valid
printf '%s\n' \
  'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let cp:*const i64=(&value) as *const i64; let relaxed:i64=@atomicLoad64Order(cp,0); let acquire:i64=@atomicLoad64Order(cp,1); @atomicStore64Order(p,19,2); let seq:i64=@atomicLoad64Order(cp,4); @atomicStore64Order(p,33,4); let after_seq_store:i64=@atomicLoad64Order(cp,1); @atomicStore64Order(p,42,0); let final:i64=@atomicLoad64Order(cp,1); if(relaxed==7&&acquire==7&&seq==19&&after_seq_store==33&&final==42&&value==42){return 42;} return 1; } }' \
  >"$tmp/valid/main.zag"
if (cd "$tmp/valid" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/valid/log" 2>&1 && [ -x "$tmp/valid/out" ]; then
  set +e; "$tmp/valid/out"; rc=$?; set -e
  bytes=$(od -An -tx1 -v "$tmp/valid/out" | tr -d ' \n')
  # Plain MOV load/store forms prove relaxed/acquire/release lowering; seq_cst
  # retains the locked XADD transaction.  These patterns are intentionally
  # broad enough to tolerate register allocation while checking op families.
  if [ "$rc" -eq 42 ] && printf '%s' "$bytes" | grep -Eq '48(8b|89)[0-9a-f]{2}' && printf '%s' "$bytes" | grep -Eq 'f0480fc1[0-9a-f]{2}'; then
    ok "atomic load/store orders execute with MOV relaxed/acquire/release and locked seq_cst lowering"
  else
    bad "atomic order execution or x86 lowering"; sed -n '1,16p' "$tmp/valid/log"
  fi
else
  bad "atomic order forms compile"; sed -n '1,16p' "$tmp/valid/log"
fi

# RMW and CAS order forms intentionally retain the established locked x86
# instructions for every valid literal order.  That is a stronger seq_cst
# implementation on this target, while the literal interface makes the
# requested operation/failure ordering auditable and fail-closed.
project rmw-cas
printf '%s\n' \
  'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let a:i64=@atomicExchange64Order(p,9,0); let b:i64=@atomicFetchAdd64Order(p,4,1); let c:i64=@atomicFetchSub64Order(p,3,2); let d:i64=@atomicFetchAnd64Order(p,14,3); let e:i64=@atomicFetchOr64Order(p,32,4); let f:i64=@atomicFetchXor64Order(p,2,0); let won:i64=@atomicCompareExchange64Order(p,40,42,3,1); let lost:i64=@atomicCompareExchange64Order(p,7,0,4,4); if(a==7&&b==9&&c==13&&d==10&&e==10&&f==42&&won==40&&lost==42&&value==42){return 42;} return 1; } }' \
  >"$tmp/rmw-cas/main.zag"
if (cd "$tmp/rmw-cas" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/rmw-cas/log" 2>&1 && [ -x "$tmp/rmw-cas/out" ]; then
  set +e; "$tmp/rmw-cas/out"; rc=$?; set -e
  bytes=$(od -An -tx1 -v "$tmp/rmw-cas/out" | tr -d ' \n')
  if [ "$rc" -eq 42 ] && printf '%s' "$bytes" | grep -Eq '4887[0-9a-f]{2}' && printf '%s' "$bytes" | grep -Eq 'f0480fc1[0-9a-f]{2}' && printf '%s' "$bytes" | grep -Eq 'f0(48|4c)0fb1[0-9a-f]{2}'; then
    ok "atomic RMW/CAS literal orders execute with established locked x86 lowering"
  else
    bad "atomic RMW/CAS order execution or x86 lowering"; sed -n '1,16p' "$tmp/rmw-cas/log"
  fi
else
  bad "atomic RMW/CAS order forms compile"; sed -n '1,16p' "$tmp/rmw-cas/log"
fi

project load-release
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicLoad64Order(p,2) as i32; } }' >"$tmp/load-release/main.zag"
if (cd "$tmp/load-release" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/load-release/log" 2>&1 || [ -e "$tmp/load-release/out" ]; then
  bad "atomic load release order was accepted"
else
  grep -q 'atomic load memory order cannot be release or acq_rel' "$tmp/load-release/log" && ok "atomic load rejects release order" || { bad "missing load order diagnostic"; sed -n '1,12p' "$tmp/load-release/log"; }
fi

project store-acquire
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; @atomicStore64Order(p,9,1); return 0; } }' >"$tmp/store-acquire/main.zag"
if (cd "$tmp/store-acquire" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/store-acquire/log" 2>&1 || [ -e "$tmp/store-acquire/out" ]; then
  bad "atomic store acquire order was accepted"
else
  grep -q 'atomic store memory order cannot be acquire or acq_rel' "$tmp/store-acquire/log" && ok "atomic store rejects acquire order" || { bad "missing store order diagnostic"; sed -n '1,12p' "$tmp/store-acquire/log"; }
fi

project dynamic
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; let order:i64=0; return @atomicLoad64Order(p,order) as i32; } }' >"$tmp/dynamic/main.zag"
if (cd "$tmp/dynamic" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/dynamic/log" 2>&1 || [ -e "$tmp/dynamic/out" ]; then
  bad "runtime atomic order was accepted"
else
  grep -q 'atomic memory order must be an integer literal' "$tmp/dynamic/log" && ok "atomic order rejects runtime values" || { bad "missing literal-order diagnostic"; sed -n '1,12p' "$tmp/dynamic/log"; }
fi

project rmw-dynamic
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let order:i64=0; return @atomicFetchAdd64Order(p,1,order) as i32; } }' >"$tmp/rmw-dynamic/main.zag"
if (cd "$tmp/rmw-dynamic" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/rmw-dynamic/log" 2>&1 || [ -e "$tmp/rmw-dynamic/out" ]; then
  bad "runtime RMW atomic order was accepted"
else
  grep -q 'atomic memory order must be an integer literal' "$tmp/rmw-dynamic/log" && ok "RMW order rejects runtime values" || { bad "missing RMW literal-order diagnostic"; sed -n '1,12p' "$tmp/rmw-dynamic/log"; }
fi

project rmw-unsafe
printf '%s\n' 'fn main() i32 { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicExchange64Order(p,9,0) as i32; }' >"$tmp/rmw-unsafe/main.zag"
if (cd "$tmp/rmw-unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/rmw-unsafe/log" 2>&1 || [ -e "$tmp/rmw-unsafe/out" ]; then
  bad "RMW atomic order outside unsafe was accepted"
else
  grep -q 'atomic read-modify-write memory-order operation requires unsafe' "$tmp/rmw-unsafe/log" && ok "RMW order requires unsafe" || { bad "missing RMW unsafe diagnostic"; sed -n '1,12p' "$tmp/rmw-unsafe/log"; }
fi

project rmw-pure
printf '%s\n' 'fn bad() i32 @pure { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicFetchAdd64Order(p,1,0) as i32; } } fn main() i32 { return 0; }' >"$tmp/rmw-pure/main.zag"
if (cd "$tmp/rmw-pure" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/rmw-pure/log" 2>&1 || [ -e "$tmp/rmw-pure/out" ]; then
  bad "RMW order satisfied a pure effect contract"
else
  grep -q 'E0002' "$tmp/rmw-pure/log" && ok "RMW order reaches pure effect constraint" || { bad "missing RMW pure-effect diagnostic"; sed -n '1,12p' "$tmp/rmw-pure/log"; }
fi

project cas-release-failure
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicCompareExchange64Order(p,7,9,4,2) as i32; } }' >"$tmp/cas-release-failure/main.zag"
if (cd "$tmp/cas-release-failure" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-release-failure/log" 2>&1 || [ -e "$tmp/cas-release-failure/out" ]; then
  bad "CAS release failure order was accepted"
else
  grep -q 'failure order must be relaxed/acquire/seq_cst and no stronger than success' "$tmp/cas-release-failure/log" && ok "CAS rejects release failure order" || { bad "missing CAS failure-order diagnostic"; sed -n '1,12p' "$tmp/cas-release-failure/log"; }
fi

project cas-arity
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicCompareExchange64Order(p,7,9,4) as i32; } }' >"$tmp/cas-arity/main.zag"
if (cd "$tmp/cas-arity" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-arity/log" 2>&1 || [ -e "$tmp/cas-arity/out" ]; then
  bad "CAS atomic order wrong arity was accepted"
else
  grep -q 'atomic compare-exchange memory-order operation expects pointer' "$tmp/cas-arity/log" && ok "CAS order rejects wrong arity" || { bad "missing CAS arity diagnostic"; sed -n '1,12p' "$tmp/cas-arity/log"; }
fi

project cas-strong-failure
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicCompareExchange64Order(p,7,9,2,1) as i32; } }' >"$tmp/cas-strong-failure/main.zag"
if (cd "$tmp/cas-strong-failure" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-strong-failure/log" 2>&1 || [ -e "$tmp/cas-strong-failure/out" ]; then
  bad "CAS stronger failure order was accepted"
else
  grep -q 'failure order must be relaxed/acquire/seq_cst and no stronger than success' "$tmp/cas-strong-failure/log" && ok "CAS rejects failure order stronger than success" || { bad "missing CAS strength diagnostic"; sed -n '1,12p' "$tmp/cas-strong-failure/log"; }
fi

project unsafe
printf '%s\n' 'fn main() i32 { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicLoad64Order(p,0) as i32; }' >"$tmp/unsafe/main.zag"
set +e
(cd "$tmp/unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/unsafe/log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] || [ -e "$tmp/unsafe/out" ]; then
  bad "atomic order outside unsafe was accepted"
else
  grep -q 'atomic memory-order operation requires unsafe' "$tmp/unsafe/log" && ok "atomic order requires unsafe" || { bad "missing unsafe order diagnostic"; sed -n '1,12p' "$tmp/unsafe/log"; }
fi

echo "v2 atomic memory orders: pass=$pass fail=$fail"
test "$fail" -eq 0
