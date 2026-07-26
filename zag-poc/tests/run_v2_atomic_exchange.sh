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
  'fn main() i32 { unsafe { let value:i64=7; let p:*mut i64=(&value) as *mut i64; let old:i64=@atomicExchange64(p,19); let now:i64=@atomicExchange64(p,42); if(old==7&&now==19&&value==42){return 42;} return 1; } }' \
  >"$tmp/exchange/main.zag"
if (cd "$tmp/exchange" && "$ZNC" main.zag --safety=checked --no-zagd --no-analyze --no-foreground-cache -o out) >"$tmp/exchange/log" 2>&1 && [ -x "$tmp/exchange/out" ]; then
  set +e; "$tmp/exchange/out"; rc=$?; set -e
  # Zag emits a section-less ELF; inspect the raw opcode rather than relying
  # on objdump's section table.  The lowering is REX.W 87 /r (48 87 xx).
  if [ "$rc" -eq 42 ] && od -An -tx1 -v "$tmp/exchange/out" | tr -d ' \n' | grep -Eq '4887[0-9a-f]{2}'; then
    ok "atomic exchange executes and emitted ELF contains memory xchg"
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
