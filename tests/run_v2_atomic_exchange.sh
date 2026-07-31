#!/usr/bin/env bash
# Narrow executable proof for the bounded public v2 atomic operations.  It does not
# start threads: this verifies the emitted x86 atomic transactions and its fail-closed source /
# runtime boundary, not a broader concurrency model.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-v2-atomic.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
project() { mkdir -p "$tmp/$1"; printf 'name = "v2atomic"\nversion = "0"\nedition = "2027"\n' >"$tmp/$1/zag.mod"; }

project exchange
printf '%s\n' \
  'fn id(value:i64) i64 { return value; } fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let cp:*const i64=(&value) as *const i64; let first:i64=@atomicLoad64(cp); @atomicStore64(p,19); let old:i64=@atomicExchange64(p,42); let added:i64=@atomicFetchAdd64(p,id(5)); let subbed:i64=@atomicFetchSub64(p,id(5)); let won:i64=@atomicCompareExchange64(p,42,99); let lost:i64=@atomicCompareExchange64(p,47,7); let called:i64=@atomicCompareExchange64(p,id(99),id(123)); let anded:i64=@atomicFetchAnd64(p,id(255)); let ored:i64=@atomicFetchOr64(p,id(256)); let xored:i64=@atomicFetchXor64(p,id(384)); let last:i64=@atomicLoad64(p); if(first==7&&old==19&&added==42&&subbed==47&&won==42&&lost==99&&called==99&&anded==123&&ored==123&&xored==379&&last==251&&value==251){return 42;} return 1; } }' \
  >"$tmp/exchange/main.zag"
if (cd "$tmp/exchange" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/exchange/log" 2>&1 && [ -x "$tmp/exchange/out" ]; then
  set +e; "$tmp/exchange/out"; rc=$?; set -e
  # Zag emits a section-less ELF; inspect raw opcodes. Exchange/store are
  # REX.W XCHG (48 87 /r), load is LOCK REX.W XADD (f0 48 0f c1 /r), and
  # fetch-add is LOCK REX.W XADD (f0 48 0f c1 /r); compare-exchange is LOCK
  # REX.W CMPXCHG (f0 48/4c 0f b1 /r; REX.R is
  # required here because the desired value is carried in r8).
  if [ "$rc" -eq 42 ] && od -An -tx1 -v "$tmp/exchange/out" | tr -d ' \n' | grep -Eq '4887[0-9a-f]{2}' && od -An -tx1 -v "$tmp/exchange/out" | tr -d ' \n' | grep -Eq 'f0480fc1[0-9a-f]{2}' && od -An -tx1 -v "$tmp/exchange/out" | tr -d ' \n' | grep -Eq 'f0(48|4c)0fb1[0-9a-f]{2}'; then
    ok "atomic load/store/exchange/fetch-add/sub/and/or/xor/compare-exchange execute with locked xadd, xchg, and cmpxchg"
  else
    bad "atomic exchange execution or xchg encoding"; sed -n '1,12p' "$tmp/exchange/log"
  fi
else
  bad "atomic exchange compiles"; sed -n '1,16p' "$tmp/exchange/log"
fi

project unsafe
printf '%s\n' 'fn main() i32 { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicExchange64(p,9) as i32; }' >"$tmp/unsafe/main.zag"
if (cd "$tmp/unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/unsafe/log" 2>&1 || [ -e "$tmp/unsafe/out" ]; then
  bad "atomic exchange outside unsafe was accepted"
else
  grep -q 'atomic exchange requires unsafe' "$tmp/unsafe/log" && ok "atomic exchange requires unsafe" || bad "missing unsafe diagnostic"
fi

project cas-unsafe
printf '%s\n' 'fn main() i32 { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicCompareExchange64(p,7,9) as i32; }' >"$tmp/cas-unsafe/main.zag"
if (cd "$tmp/cas-unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-unsafe/log" 2>&1 || [ -e "$tmp/cas-unsafe/out" ]; then
  bad "atomic compare-exchange outside unsafe was accepted"
else
  grep -q 'atomic compare-exchange requires unsafe' "$tmp/cas-unsafe/log" && ok "atomic compare-exchange requires unsafe" || bad "missing compare-exchange unsafe diagnostic"
fi

project type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicExchange64(p,9) as i32; } }' >"$tmp/type/main.zag"
if (cd "$tmp/type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/type/log" 2>&1 || [ -e "$tmp/type/out" ]; then
  bad "const atomic pointer was accepted"
else
  grep -q 'requires an explicitly mutable' "$tmp/type/log" && ok "atomic exchange rejects non-mutable pointer" || bad "missing pointer diagnostic"
fi

project cas-const
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicCompareExchange64(p,7,9) as i32; } }' >"$tmp/cas-const/main.zag"
if (cd "$tmp/cas-const" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-const/log" 2>&1 || [ -e "$tmp/cas-const/out" ]; then
  bad "const compare-exchange pointer was accepted"
else
  grep -q 'requires an explicitly mutable' "$tmp/cas-const/log" && ok "atomic compare-exchange rejects non-mutable pointer" || bad "missing compare-exchange pointer diagnostic"
fi

project store-const
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; @atomicStore64(p,9); return 0; } }' >"$tmp/store-const/main.zag"
if (cd "$tmp/store-const" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/store-const/log" 2>&1 || [ -e "$tmp/store-const/out" ]; then
  bad "atomic store through const pointer was accepted"
else
  grep -q 'stores/exchanges require \*mut' "$tmp/store-const/log" && ok "atomic store rejects const pointer" || bad "missing store mutability diagnostic"
fi

project load-arity
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicLoad64(p,1) as i32; } }' >"$tmp/load-arity/main.zag"
if (cd "$tmp/load-arity" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/load-arity/log" 2>&1 || [ -e "$tmp/load-arity/out" ]; then
  bad "atomic load accepted wrong arity"
else
  grep -q 'wrong argument count' "$tmp/load-arity/log" && ok "atomic load rejects wrong arity" || bad "missing load arity diagnostic"
fi

project cas-arity
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicCompareExchange64(p,7) as i32; } }' >"$tmp/cas-arity/main.zag"
if (cd "$tmp/cas-arity" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-arity/log" 2>&1 || [ -e "$tmp/cas-arity/out" ]; then
  bad "atomic compare-exchange accepted wrong arity"
else
  grep -q 'atomic compare-exchange has the wrong argument count' "$tmp/cas-arity/log" && ok "atomic compare-exchange rejects wrong arity" || bad "missing compare-exchange arity diagnostic"
fi

project fetch-unsafe
printf '%s\n' 'fn main() i32 { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicFetchAdd64(p,1) as i32; }' >"$tmp/fetch-unsafe/main.zag"
if (cd "$tmp/fetch-unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/fetch-unsafe/log" 2>&1 || [ -e "$tmp/fetch-unsafe/out" ]; then
  bad "fetch-add outside unsafe was accepted"
else
  grep -q 'atomic fetch-add/sub requires unsafe' "$tmp/fetch-unsafe/log" && ok "fetch-add requires unsafe" || bad "missing fetch-add unsafe diagnostic"
fi

project fetch-const
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicFetchAdd64(p,1) as i32; } }' >"$tmp/fetch-const/main.zag"
if (cd "$tmp/fetch-const" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/fetch-const/log" 2>&1 || [ -e "$tmp/fetch-const/out" ]; then
  bad "fetch-add accepted a const pointer"
else
  grep -q 'atomic fetch-add/sub requires an explicitly mutable' "$tmp/fetch-const/log" && ok "fetch-add rejects non-mutable pointer" || bad "missing fetch-add pointer diagnostic"
fi

project fetch-arity
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicFetchAdd64(p) as i32; } }' >"$tmp/fetch-arity/main.zag"
if (cd "$tmp/fetch-arity" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/fetch-arity/log" 2>&1 || [ -e "$tmp/fetch-arity/out" ]; then
  bad "fetch-add accepted wrong arity"
else
  grep -q 'atomic i64 operation has the wrong argument count' "$tmp/fetch-arity/log" && ok "fetch-add rejects wrong arity" || bad "missing fetch-add arity diagnostic"
fi

project fetch-type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let wrong:i32=1; return @atomicFetchAdd64(p,wrong) as i32; } }' >"$tmp/fetch-type/main.zag"
if (cd "$tmp/fetch-type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/fetch-type/log" 2>&1 || [ -e "$tmp/fetch-type/out" ]; then
  bad "fetch-add accepted a non-i64 value"
else
  grep -q 'atomic fetch-add/sub value must be i64' "$tmp/fetch-type/log" && ok "fetch-add requires i64 values" || bad "missing fetch-add value diagnostic"
fi

project bitwise-unsafe
printf '%s\n' 'fn main() i32 { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicFetchAnd64(p,1) as i32; }' >"$tmp/bitwise-unsafe/main.zag"
if (cd "$tmp/bitwise-unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/bitwise-unsafe/log" 2>&1 || [ -e "$tmp/bitwise-unsafe/out" ]; then
  bad "fetch-and outside unsafe was accepted"
else
  grep -q 'atomic fetch operation requires unsafe' "$tmp/bitwise-unsafe/log" && ok "fetch-and requires unsafe" || bad "missing fetch-and unsafe diagnostic"
fi

project bitwise-const
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicFetchOr64(p,1) as i32; } }' >"$tmp/bitwise-const/main.zag"
if (cd "$tmp/bitwise-const" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/bitwise-const/log" 2>&1 || [ -e "$tmp/bitwise-const/out" ]; then
  bad "fetch-or accepted a const pointer"
else
  grep -q 'atomic fetch operation requires an explicitly mutable' "$tmp/bitwise-const/log" && ok "fetch-or rejects non-mutable pointer" || bad "missing fetch-or pointer diagnostic"
fi

project bitwise-type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let wrong:i32=1; return @atomicFetchXor64(p,wrong) as i32; } }' >"$tmp/bitwise-type/main.zag"
if (cd "$tmp/bitwise-type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/bitwise-type/log" 2>&1 || [ -e "$tmp/bitwise-type/out" ]; then
  bad "fetch-xor accepted a non-i64 value"
else
  grep -q 'atomic fetch operation value must be i64' "$tmp/bitwise-type/log" && ok "fetch-xor requires i64 values" || bad "missing fetch-xor value diagnostic"
fi

project bitwise-pure
printf '%s\n' 'fn bad() i64 @pure { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicFetchOr64(p,1); } } fn main() i32 { return 0; }' >"$tmp/bitwise-pure/main.zag"
if (cd "$tmp/bitwise-pure" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/bitwise-pure/log" 2>&1 || [ -e "$tmp/bitwise-pure/out" ]; then
  bad "pure fetch-or was accepted"
else
  grep -q 'capability violation.*pure' "$tmp/bitwise-pure/log" && ok "atomic fetch-or Unsafe effect reaches pure constraint" || bad "missing fetch-or pure-effect diagnostic"
fi

project sub-unsafe
printf '%s\n' 'fn main() i32 { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicFetchSub64(p,1) as i32; }' >"$tmp/sub-unsafe/main.zag"
if (cd "$tmp/sub-unsafe" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/sub-unsafe/log" 2>&1 || [ -e "$tmp/sub-unsafe/out" ]; then
  bad "fetch-sub outside unsafe was accepted"
else
  grep -q 'atomic fetch-add/sub requires unsafe' "$tmp/sub-unsafe/log" && ok "fetch-sub requires unsafe" || bad "missing fetch-sub unsafe diagnostic"
fi

project sub-const
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicFetchSub64(p,1) as i32; } }' >"$tmp/sub-const/main.zag"
if (cd "$tmp/sub-const" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/sub-const/log" 2>&1 || [ -e "$tmp/sub-const/out" ]; then
  bad "fetch-sub accepted a const pointer"
else
  grep -q 'atomic fetch-add/sub requires an explicitly mutable' "$tmp/sub-const/log" && ok "fetch-sub rejects non-mutable pointer" || bad "missing fetch-sub pointer diagnostic"
fi

project sub-arity
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicFetchSub64(p) as i32; } }' >"$tmp/sub-arity/main.zag"
if (cd "$tmp/sub-arity" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/sub-arity/log" 2>&1 || [ -e "$tmp/sub-arity/out" ]; then
  bad "fetch-sub accepted wrong arity"
else
  grep -q 'atomic i64 operation has the wrong argument count' "$tmp/sub-arity/log" && ok "fetch-sub rejects wrong arity" || bad "missing fetch-sub arity diagnostic"
fi

project sub-type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let wrong:i32=1; return @atomicFetchSub64(p,wrong) as i32; } }' >"$tmp/sub-type/main.zag"
if (cd "$tmp/sub-type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/sub-type/log" 2>&1 || [ -e "$tmp/sub-type/out" ]; then
  bad "fetch-sub accepted a non-i64 value"
else
  grep -q 'atomic fetch-add/sub value must be i64' "$tmp/sub-type/log" && ok "fetch-sub requires i64 values" || bad "missing fetch-sub value diagnostic"
fi

project value-type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let wrong:i32=9; @atomicStore64(p,wrong); return @atomicExchange64(p,wrong) as i32; } }' >"$tmp/value-type/main.zag"
if (cd "$tmp/value-type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/value-type/log" 2>&1 || [ -e "$tmp/value-type/out" ]; then
  bad "atomic store/exchange accepted a non-i64 value"
else
  grep -q 'atomic store/exchange value must be i64' "$tmp/value-type/log" && ok "atomic store/exchange require i64 values" || bad "missing atomic value-type diagnostic"
fi

project cas-value-type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let wrong:i32=9; return @atomicCompareExchange64(p,wrong,wrong) as i32; } }' >"$tmp/cas-value-type/main.zag"
if (cd "$tmp/cas-value-type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-value-type/log" 2>&1 || [ -e "$tmp/cas-value-type/out" ]; then
  bad "atomic compare-exchange accepted non-i64 values"
else
  grep -q 'atomic compare-exchange values must be i64' "$tmp/cas-value-type/log" && ok "atomic compare-exchange requires i64 values" || bad "missing compare-exchange value diagnostic"
fi

project cas-pure
printf '%s\n' 'fn bad() i64 @pure { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; return @atomicCompareExchange64(p,7,9); } } fn main() i32 { return 0; }' >"$tmp/cas-pure/main.zag"
if (cd "$tmp/cas-pure" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/cas-pure/log" 2>&1 || [ -e "$tmp/cas-pure/out" ]; then
  bad "pure compare-exchange was accepted"
else
  grep -q 'capability violation.*pure' "$tmp/cas-pure/log" && ok "atomic compare-exchange Unsafe effect reaches pure constraint" || bad "missing compare-exchange pure-effect diagnostic"
fi

project misaligned
printf '%s\n' 'fn main() i32 { unsafe { let bytes:*i8=_zag_malloc(16) as *i8; let p:*mut i64=(&bytes[1]) as *mut i64; let result:i64=@atomicExchange64(p,1); _zag_free(bytes); return result as i32; } }' >"$tmp/misaligned/main.zag"
if (cd "$tmp/misaligned" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/misaligned/log" 2>&1 && [ -x "$tmp/misaligned/out" ]; then
  set +e; "$tmp/misaligned/out" >"$tmp/misaligned/stdout" 2>"$tmp/misaligned/stderr"; rc=$?; set -e
  if [ "$rc" -ne 0 ] && grep -q 'zag atomic: misaligned \*mut i64' "$tmp/misaligned/stderr"; then
    ok "misaligned atomic address traps before xchg"
  else
    bad "misaligned atomic address did not trap"; sed -n '1,8p' "$tmp/misaligned/stderr"
  fi
else
  bad "misaligned atomic test compiles"; sed -n '1,16p' "$tmp/misaligned/log"
fi

echo "════ v2 atomic exchange pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
