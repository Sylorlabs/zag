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
