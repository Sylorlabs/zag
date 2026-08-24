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
if (cd "$tmp/aggregate" && "$ZNC" check main.zag --no-zagd --no-analyze) >"$tmp/aggregate/log" 2>&1 || [ -e "$tmp/aggregate/out" ]; then
  bad "opaque aggregate function call rejects in @pure"; sed -n '1,12p' "$tmp/aggregate/log"
elif grep -q 'E0002' "$tmp/aggregate/log"; then
  ok "opaque aggregate function call cannot launder an untracked effect"
else
  bad "opaque aggregate-call rejection reports effect violation"; sed -n '1,12p' "$tmp/aggregate/log"
fi

expect_accept() {
  local name=$1
  local label=$2
  local source=$3
  mkdir -p "$tmp/$name"
  printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$name" >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  if (cd "$tmp/$name" && "$ZNC" check main.zag --no-zagd --no-analyze) >"$tmp/$name/log" 2>&1; then
    ok "$label"
  else
    bad "$label"; sed -n '1,12p' "$tmp/$name/log"
  fi
}

expect_accept aggregate-row-local "verified aggregate @pure row is callable in @pure" \
  'struct Holder { op:fn() i32 @pure } fn clean() i32 { return 42; } fn good() i32 @pure { let h:Holder=Holder{.op=clean}; return h.op(); } fn main() i32 { return good(); }'
expect_accept aggregate-row-helper "verified aggregate row propagates through typed helper parameter" \
  'struct Holder { op:fn() i32 @pure } fn clean() i32 { return 42; } fn invoke(h:Holder) i32 @pure { return h.op(); } fn main() i32 { let h:Holder=Holder{.op=clean}; return invoke(h); }'
expect_accept pure-method "resolved pure method remains callable in @pure" \
  'struct Box { value:i32 } fn (self:Box) get() i32 @pure { return self.value; } fn good() i32 @pure { let b:Box=Box{.value=42}; return b.get(); } fn main() i32 { return good(); }'

mkdir -p "$tmp/aggregate-row-violation"
printf 'name = "aggregaterowviolation"\nversion = "0"\nedition = "2027"\n' >"$tmp/aggregate-row-violation/zag.mod"
printf 'struct Holder { op:fn() i32 @pure } fn dirty() i32 { return @gpuThreadIdx(0); } fn main() i32 { let h:Holder=Holder{.op=dirty}; return 0; }\n' >"$tmp/aggregate-row-violation/main.zag"
if (cd "$tmp/aggregate-row-violation" && "$ZNC" check main.zag --no-zagd --no-analyze) >"$tmp/aggregate-row-violation/log" 2>&1; then
  bad "aggregate field row accepted an effectful value"
elif grep -q 'E0007' "$tmp/aggregate-row-violation/log"; then
  ok "aggregate field row rejects an effectful stored value"
else
  bad "aggregate field row violation lacked E0007"; sed -n '1,12p' "$tmp/aggregate-row-violation/log"
fi

mkdir -p "$tmp/aggregate-row-mutation"
printf 'name = "aggregaterowmutation"\nversion = "0"\nedition = "2027"\n' >"$tmp/aggregate-row-mutation/zag.mod"
printf 'struct Holder { op:fn() i32 @pure } fn clean() i32 { return 0; } fn dirty() i32 { return @gpuThreadIdx(0); } fn main() i32 { let h:Holder=Holder{.op=clean}; h.op=dirty; return 0; }\n' >"$tmp/aggregate-row-mutation/main.zag"
if (cd "$tmp/aggregate-row-mutation" && "$ZNC" check main.zag --no-zagd --no-analyze) >"$tmp/aggregate-row-mutation/log" 2>&1; then
  bad "aggregate field mutation bypassed its effect row"
elif grep -q 'E0007' "$tmp/aggregate-row-mutation/log"; then
  ok "aggregate field mutation preserves its effect row"
else
  bad "aggregate field mutation violation lacked E0007"; sed -n '1,12p' "$tmp/aggregate-row-mutation/log"
fi

mkdir -p "$tmp/direct"
printf 'name = "v2effectdirect"\nversion = "0"\nedition = "2027"\n' >"$tmp/direct/zag.mod"
printf 'fn clean() i32 { return 42; } fn good() i32 @pure { return clean(); } fn main() i32 { return good(); }\n' >"$tmp/direct/main.zag"
if (cd "$tmp/direct" && "$ZNC" main.zag -o out --no-zagd --no-analyze) >"$tmp/direct/log" 2>&1 && [ -x "$tmp/direct/out" ]; then
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
expect_pure_reject device_method \
  'struct Box { value:i32 } fn (self:Box) lane() i32 { return @gpuThreadIdx(self.value); } fn bad() i32 @pure { let b:Box=Box{.value=0}; return b.lane(); } fn main() i32 { return 0; }'
expect_pure_reject generic_device_callback \
  'fn apply[T](op:fn() i32,x:T) i32 { return op(); } fn lane() i32 { return @gpuThreadIdx(0); } fn bad() i32 @pure { return apply[i32](lane,0); } fn main() i32 { return 0; }'

echo "──── v2 effect adversarial: pass=$pass fail=$fail ────"
[ "$fail" -eq 0 ]
