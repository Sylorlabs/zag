#!/usr/bin/env bash
# Compiler-reserved AtomicI64 proof.  The public surface is receiver-only;
# this script proves both native transactions and that ordinary value/pointer
# escape hatches remain closed.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-v2-atomic-storage.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
project() { mkdir -p "$tmp/$1"; printf 'name = "v2atomicstorage"\nversion = "0"\nedition = "2027"\n' >"$tmp/$1/zag.mod"; }

project valid
printf '%s\n' 'global let shared:AtomicI64; fn main() i32 { let a:AtomicI64=@atomicI64(7); unsafe { let first:i64=a.load(1); a.store(19,2); let old:i64=a.exchange(42,0); let add:i64=a.fetch_add(5,1); let sub:i64=a.fetch_sub(5,2); let anded:i64=a.fetch_and(255,3); let ored:i64=a.fetch_or(256,4); let xored:i64=a.fetch_xor(384,0); let won:i64=a.compare_exchange(170,251,4,1); let lost:i64=a.compare_exchange(7,0,4,4); shared.store(9,2); let global:i64=shared.load(1); if(first==7&&old==19&&add==42&&sub==47&&anded==42&&ored==42&&xored==298&&won==170&&lost==251&&global==9){return 42;} return 1; } }' >"$tmp/valid/main.zag"
if (cd "$tmp/valid" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/valid/log" 2>&1 && [ -x "$tmp/valid/out" ]; then
  set +e; "$tmp/valid/out"; rc=$?; set -e
  bytes=$(od -An -tx1 -v "$tmp/valid/out" | tr -d ' \n')
  if [ "$rc" -eq 42 ] && printf '%s' "$bytes" | grep -Eq 'f0480fc1[0-9a-f]{2}' && printf '%s' "$bytes" | grep -Eq 'f0(48|4c)0fb1[0-9a-f]{2}'; then ok "receiver operations execute as native atomic instructions"; else bad "AtomicI64 runtime/lowering"; sed -n '1,16p' "$tmp/valid/log"; fi
else bad "AtomicI64 valid program compiles"; sed -n '1,16p' "$tmp/valid/log"; fi

reject() { name=$1; source=$2; needle=$3; project "$name"; printf '%s\n' "$source" >"$tmp/$name/main.zag"; if (cd "$tmp/$name" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/$name/log" 2>&1 || [ -e "$tmp/$name/out" ]; then bad "$name was accepted"; else grep -q "$needle" "$tmp/$name/log" && ok "$name is rejected" || { bad "$name diagnostic"; sed -n '1,12p' "$tmp/$name/log"; }; fi; }
reject safe 'fn main() i32 { let a:AtomicI64=@atomicI64(0); return a.load(1) as i32; }' 'AtomicI64 operations require unsafe'
reject read 'fn main() i32 { let a:AtomicI64=@atomicI64(0); unsafe { let x:i64=a; return x as i32; } }' 'AtomicI64 storage is opaque'
reject assign 'fn main() i32 { let a:AtomicI64=@atomicI64(0); unsafe { a=0; return 0; } }' 'AtomicI64 storage is opaque'
reject address 'fn main() i32 { let a:AtomicI64=@atomicI64(0); unsafe { let p:*AtomicI64=&a; return 0; } }' 'AtomicI64 storage cannot be wrapped or addressed'
reject parameter 'fn take(a:AtomicI64) i32 { return 0; } fn main() i32 { return 0; }' 'AtomicI64 cannot be a function parameter'
reject field 'struct Bad { a:AtomicI64 } fn main() i32 { return 0; }' 'AtomicI64 cannot be embedded in structs'
reject inferred 'fn main() i32 { let a=@atomicI64(0); return 0; }' 'AtomicI64 local requires an explicit'
reject init-type 'fn main() i32 { let a:AtomicI64=@atomicI64(true); return 0; }' 'AtomicI64 initializer must be i64'
reject global-pointer 'global let p:*mut AtomicI64; fn main() i32 { return 0; }' 'AtomicI64 global storage cannot be wrapped or addressed'
reject literal 'struct Box { value:i64 } fn main() i32 { let b:Box=Box{.value=@atomicI64(0)}; return 0; }' 'AtomicI64 storage cannot be embedded in an aggregate literal'

echo "AtomicI64 storage pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
