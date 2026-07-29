#!/usr/bin/env bash
# Regression for fail-closed effect propagation through opaque indirect calls.
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-v2-effects.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

mkdir -p "$tmp/aggregate"
printf 'name = "v2effectaggregate"\nversion = "0"\nedition = "2027"\n' >"$tmp/aggregate/zag.mod"
printf 'struct Holder { op:fn() i32 } fn clean() i32 { return 42; } fn bad() i32 @pure { let h:Holder=Holder{.op=clean}; return h.op(); } fn main() i32 { return 0; }\n' >"$tmp/aggregate/main.zag"
if (cd "$tmp/aggregate" && "$ZNC" check main.zag) >"$tmp/aggregate/log" 2>&1 || [ -e "$tmp/aggregate/out" ]; then
  bad "opaque aggregate function call rejects in @pure"; sed -n '1,12p' "$tmp/aggregate/log"
elif grep -q 'E0002' "$tmp/aggregate/log"; then
  ok "opaque aggregate function call cannot launder an untracked effect"
else
  bad "opaque aggregate-call rejection reports effect violation"; sed -n '1,12p' "$tmp/aggregate/log"
fi

mkdir -p "$tmp/direct"
printf 'name = "v2effectdirect"\nversion = "0"\nedition = "2027"\n' >"$tmp/direct/zag.mod"
printf 'fn clean() i32 { return 42; } fn good() i32 @pure { return clean(); } fn main() i32 { return good(); }\n' >"$tmp/direct/main.zag"
if (cd "$tmp/direct" && "$ZNC" main.zag -o out) >"$tmp/direct/log" 2>&1 && [ -x "$tmp/direct/out" ]; then
  set +e
  "$tmp/direct/out"
  rc=$?
  set -e
  if [ "$rc" -eq 42 ]; then
    ok "resolved direct call remains usable in @pure"
  else
    bad "resolved direct call executes"; sed -n '1,12p' "$tmp/direct/log"
  fi
else
  bad "resolved direct call compiles"; sed -n '1,12p' "$tmp/direct/log"
fi

expect_pure_reject() {
  local name=$1
  local source=$2
  mkdir -p "$tmp/$name"
  printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$name" >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  if (cd "$tmp/$name" && "$ZNC" check main.zag --no-zagd --no-analyze) >"$tmp/$name/log" 2>&1; then
    bad "$name effect unexpectedly accepted in @pure"
  elif grep -q 'E0002' "$tmp/$name/log"; then
    ok "$name effect propagates through a direct helper"
  else
    bad "$name rejection reports effect violation"; sed -n '1,12p' "$tmp/$name/log"
  fi
}

expect_pure_reject atomic_helper \
  'fn touch() void { unsafe { let x:i64=0; @atomicStore64((&x) as *mut i64,1); } } fn bad() void @pure { touch(); } fn main() void {}'
expect_pure_reject ffi_helper \
  'extern fn getpid() i64 @cabi; fn foreign() i64 { unsafe { return getpid(); } } fn bad() i64 @pure { return foreign(); } fn main() i32 { return 0; }'
expect_pure_reject device_helper \
  'fn lane() i32 { return @gpuThreadIdx(0); } fn bad() i32 @pure { return lane(); } fn main() i32 { return 0; }'
expect_pure_reject device_reassignment \
  'fn clean() i32 { return 0; } fn lane() i32 { return @gpuThreadIdx(0); } fn bad() i32 @pure { let op:fn() i32 @pure=clean; op=lane; return op(); } fn main() i32 { return 0; }'

echo "──── v2 effect adversarial: pass=$pass fail=$fail ────"
[ "$fail" -eq 0 ]
