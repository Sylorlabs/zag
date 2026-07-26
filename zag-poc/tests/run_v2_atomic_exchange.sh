#!/usr/bin/env bash
# Narrow executable proof for the only public v2 atomic operation.  It does not
# start threads: this verifies the emitted x86 XCHG and its fail-closed source /
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
  'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let cp:*const i64=(&value) as *const i64; let first:i64=@atomicLoad64(cp); @atomicStore64(p,19); let old:i64=@atomicExchange64(p,42); let last:i64=@atomicLoad64(p); if(first==7&&old==19&&last==42&&value==42){return 42;} return 1; } }' \
  >"$tmp/exchange/main.zag"
if (cd "$tmp/exchange" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/exchange/log" 2>&1 && [ -x "$tmp/exchange/out" ]; then
  set +e; "$tmp/exchange/out"; rc=$?; set -e
  # Zag emits a section-less ELF; inspect raw opcodes. Exchange/store are
  # REX.W XCHG (48 87 /r); load is LOCK REX.W XADD (f0 48 0f c1 /r).
  if [ "$rc" -eq 42 ] && od -An -tx1 -v "$tmp/exchange/out" | tr -d ' \n' | grep -Eq '4887[0-9a-f]{2}' && od -An -tx1 -v "$tmp/exchange/out" | tr -d ' \n' | grep -Eq 'f0480fc1[0-9a-f]{2}'; then
    ok "atomic load/store/exchange execute with locked xadd and xchg"
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

project type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*const i64=(&value) as *const i64; return @atomicExchange64(p,9) as i32; } }' >"$tmp/type/main.zag"
if (cd "$tmp/type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/type/log" 2>&1 || [ -e "$tmp/type/out" ]; then
  bad "const atomic pointer was accepted"
else
  grep -q 'requires an explicitly mutable' "$tmp/type/log" && ok "atomic exchange rejects non-mutable pointer" || bad "missing pointer diagnostic"
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

project value-type
printf '%s\n' 'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let wrong:i32=9; @atomicStore64(p,wrong); return @atomicExchange64(p,wrong) as i32; } }' >"$tmp/value-type/main.zag"
if (cd "$tmp/value-type" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/value-type/log" 2>&1 || [ -e "$tmp/value-type/out" ]; then
  bad "atomic store/exchange accepted a non-i64 value"
else
  grep -q 'atomic store/exchange value must be i64' "$tmp/value-type/log" && ok "atomic store/exchange require i64 values" || bad "missing atomic value-type diagnostic"
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
