#!/usr/bin/env bash
# V2 edition boundary: syntax must be rejected before parsing/codegen and must
# never leave an executable behind.  This is intentionally a compiler test, not
# a grep-only documentation test.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-v2-edition.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
# This is a foreground compiler/ownership test. Starting a project daemon for
# every disposable test case races cleanup and can retain orphan processes;
# daemon behavior is covered independently by run_zagd_daemon.sh.
export ZAG_V2_TEST_ZNC="$ZNC"
ZNC="$tmp/znc-no-zagd"
printf '%s\n' '#!/usr/bin/env bash' 'exec "$ZAG_V2_TEST_ZNC" "$@" --no-zagd' >"$ZNC"
chmod +x "$ZNC"
pass=0 fail=0

reject() {
  name=$1 edition=$2
  mkdir -p "$tmp/$name"
  printf 'name = "v2test"\nversion = "0"\nedition = "%s"\n' "$edition" >"$tmp/$name/zag.mod"
  printf 'fn main() i32 { unsafe { return 42; } }\n' >"$tmp/$name/main.zag"
  out="$tmp/$name/out"
  if (cd "$tmp/$name" && "$ZNC" main.zag -o "$out") >"$tmp/$name/log" 2>&1 || [ -e "$out" ]; then
    echo "  XX  $name"; sed -n '1,8p' "$tmp/$name/log"; fail=$((fail + 1))
  elif grep -q "$3" "$tmp/$name/log"; then
    echo "  ok  $name"; pass=$((pass + 1))
  else
    echo "  XX  $name (missing diagnostic)"; sed -n '1,8p' "$tmp/$name/log"; fail=$((fail + 1))
  fi
}

reject "v1 rejects v2 unsafe syntax" 2026 E0200
mkdir -p "$tmp/v2-checked-null"
printf 'name = "v2checkednull"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-null/zag.mod"
printf 'fn main() i32 { unsafe { let p:*const i32=null as *const i32; return p.*; } }\n' >"$tmp/v2-checked-null/main.zag"
if (cd "$tmp/v2-checked-null" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-null/log" 2>&1 && [ -x "$tmp/v2-checked-null/out" ]; then
  set +e
  "$tmp/v2-checked-null/out" >"$tmp/v2-checked-null/out.log" 2>"$tmp/v2-checked-null/err.log"
  checked_null_rc=$?
  set -e
  if [ "$checked_null_rc" -ne 0 ] && grep -q 'zag safety: null raw pointer access' "$tmp/v2-checked-null/err.log"; then
    echo "  ok  checked safety traps null raw-pointer dereference"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety null dereference (exit=$checked_null_rc)"; sed -n '1,8p' "$tmp/v2-checked-null/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety null program did not compile"; sed -n '1,8p' "$tmp/v2-checked-null/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-aggregate"
printf 'name = "v2checkedaggregate"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-aggregate/zag.mod"
printf 'struct Triple { a:i64, b:i64, c:i64 } fn main() i32 { unsafe { let p:*Triple=_zag_malloc(24) as *Triple; p.*.a=7; p.*.b=11; p.*.c=24; let result:i64=p.*.a+p.*.b+p.*.c; _zag_free(p); return result as i32; } }\n' >"$tmp/v2-checked-aggregate/main.zag"
if (cd "$tmp/v2-checked-aggregate" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-aggregate/log" 2>&1 &&
   [ -x "$tmp/v2-checked-aggregate/out" ]; then
  set +e
  "$tmp/v2-checked-aggregate/out"
  checked_aggregate_rc=$?
  set -e
  if [ "$checked_aggregate_rc" -eq 42 ]; then
    echo "  ok  checked safety permits valid 8-aligned 24-byte aggregate access"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety aggregate access (exit=$checked_aggregate_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety aggregate program did not compile"; sed -n '1,8p' "$tmp/v2-checked-aggregate/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-misaligned"
printf 'name = "v2checkedmisaligned"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-misaligned/zag.mod"
printf 'fn main() i32 { unsafe { let bytes:*i8=_zag_malloc(32) as *i8; let p:*const i32=(&bytes[1]) as *const i32; let result:i32=p.*; _zag_free(bytes); return result; } }\n' >"$tmp/v2-checked-misaligned/main.zag"
if (cd "$tmp/v2-checked-misaligned" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-misaligned/log" 2>&1 && [ -x "$tmp/v2-checked-misaligned/out" ]; then
  set +e
  "$tmp/v2-checked-misaligned/out" >"$tmp/v2-checked-misaligned/out.log" 2>"$tmp/v2-checked-misaligned/err.log"
  checked_misaligned_rc=$?
  set -e
  if [ "$checked_misaligned_rc" -ne 0 ] && grep -q 'zag safety: misaligned raw pointer access' "$tmp/v2-checked-misaligned/err.log"; then
    echo "  ok  checked safety traps misaligned raw-pointer dereference"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety misaligned dereference (exit=$checked_misaligned_rc)"; sed -n '1,8p' "$tmp/v2-checked-misaligned/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety misaligned program did not compile"; sed -n '1,8p' "$tmp/v2-checked-misaligned/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-wasm"
printf 'name = "v2checkedwasm"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-wasm/zag.mod"
printf 'fn main() i32 { return 0; }\n' >"$tmp/v2-checked-wasm/main.zag"
if (cd "$tmp/v2-checked-wasm" && "$ZNC" main.zag -o out --target wasm --safety=checked) >"$tmp/v2-checked-wasm/log" 2>&1 || [ -e "$tmp/v2-checked-wasm/out" ]; then
  echo "  XX  checked safety rejects unsupported target"; sed -n '1,8p' "$tmp/v2-checked-wasm/log"; fail=$((fail + 1))
elif grep -q 'implemented only for the native x86-64 target' "$tmp/v2-checked-wasm/log"; then
  echo "  ok  checked safety rejects unsupported target without artifact"
  pass=$((pass + 1))
else
  echo "  XX  checked safety target rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-callback-lifetime"
printf 'name = "v2callbacklifetime"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-callback-lifetime/zag.mod"
printf 'fn maker() fn() i32 { let x:i32=42; return fn[&x]() i32 { return x.*; }; } fn main() i32 { let f:fn() i32=maker(); return f(); }\n' >"$tmp/v2-callback-lifetime/main.zag"
if (cd "$tmp/v2-callback-lifetime" && "$ZNC" main.zag -o out) >"$tmp/v2-callback-lifetime/log" 2>&1 || [ -e "$tmp/v2-callback-lifetime/out" ]; then
  echo "  XX  callback capture lifetime rejects without artifact"; sed -n '1,8p' "$tmp/v2-callback-lifetime/log"; fail=$((fail + 1))
elif grep -q 'capturing closure requires an explicit v2 lifetime contract' "$tmp/v2-callback-lifetime/log"; then
  echo "  ok  callback capture lifetime rejects without artifact"
  pass=$((pass + 1))
else
  echo "  XX  callback capture lifetime diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-unsafe"
printf 'name = "v2unsafe"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-unsafe/zag.mod"
printf 'fn main() i32 { unsafe { print_i64(42); } return 0; }\n' >"$tmp/v2-unsafe/main.zag"
if (cd "$tmp/v2-unsafe" && "$ZNC" main.zag -o out) >"$tmp/v2-unsafe/log" 2>&1 &&
   [ -x "$tmp/v2-unsafe/out" ] && [ "$("$tmp/v2-unsafe/out")" = 42 ]; then
  echo "  ok  v2 executes lexical unsafe block"; pass=$((pass + 1))
else
  echo "  XX  v2 executes lexical unsafe block"; sed -n '1,8p' "$tmp/v2-unsafe/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-unsafe-fn"
printf 'name = "v2unsafefn"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-unsafe-fn/zag.mod"
printf 'unsafe fn load(p: *const i32) i32 { return p.*; } fn main() i32 { let x: i32 = 42; unsafe { return load((&x) as *const i32); } }\n' >"$tmp/v2-unsafe-fn/main.zag"
if (cd "$tmp/v2-unsafe-fn" && "$ZNC" main.zag -o out) >"$tmp/v2-unsafe-fn/log" 2>&1 &&
   [ -x "$tmp/v2-unsafe-fn/out" ]; then
  set +e
  "$tmp/v2-unsafe-fn/out"
  unsafe_fn_ec=$?
  set -e
  if [ "$unsafe_fn_ec" -eq 42 ]; then
    echo "  ok  unsafe function executes from unsafe call site"; pass=$((pass + 1))
  else
    echo "  XX  unsafe function execution (exit=$unsafe_fn_ec)"; fail=$((fail + 1))
  fi
else
  echo "  XX  unsafe function compiles"; sed -n '1,8p' "$tmp/v2-unsafe-fn/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-safe-call"
printf 'name = "v2safecall"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-safe-call/zag.mod"
printf 'unsafe fn raw() i32 { return 42; } fn main() i32 { return raw(); }\n' >"$tmp/v2-safe-call/main.zag"
if (cd "$tmp/v2-safe-call" && "$ZNC" main.zag -o out) >"$tmp/v2-safe-call/log" 2>&1 || [ -e "$tmp/v2-safe-call/out" ]; then
  echo "  XX  safe call site rejects unsafe function"; sed -n '1,8p' "$tmp/v2-safe-call/log"; fail=$((fail + 1))
elif grep -q 'call to unsafe function requires unsafe' "$tmp/v2-safe-call/log"; then
  echo "  ok  safe call site rejects unsafe function without artifact"; pass=$((pass + 1))
else
  echo "  XX  unsafe call rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-unsafe-value"
printf 'name = "v2unsafevalue"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-unsafe-value/zag.mod"
printf 'unsafe fn raw() i32 { return 42; } fn main() i32 { let f: fn() i32 = raw; return f(); }\n' >"$tmp/v2-unsafe-value/main.zag"
if (cd "$tmp/v2-unsafe-value" && "$ZNC" main.zag -o out) >"$tmp/v2-unsafe-value/log" 2>&1 || [ -e "$tmp/v2-unsafe-value/out" ]; then
  echo "  XX  unsafe function value rejects without artifact"; sed -n '1,8p' "$tmp/v2-unsafe-value/log"; fail=$((fail + 1))
elif grep -q 'unsafe function values are not implemented' "$tmp/v2-unsafe-value/log"; then
  echo "  ok  unsafe function value rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  unsafe function value rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-pure-unsafe"
printf 'name = "v2pureunsafe"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-pure-unsafe/zag.mod"
printf 'unsafe fn raw() i32 { return 42; } fn bad() i32 @pure { unsafe { return raw(); } } fn main() i32 { return 0; }\n' >"$tmp/v2-pure-unsafe/main.zag"
if (cd "$tmp/v2-pure-unsafe" && "$ZNC" main.zag -o out) >"$tmp/v2-pure-unsafe/log" 2>&1 || [ -e "$tmp/v2-pure-unsafe/out" ]; then
  echo "  XX  pure function rejects Unsafe effect"; sed -n '1,8p' "$tmp/v2-pure-unsafe/log"; fail=$((fail + 1))
elif grep -q E0002 "$tmp/v2-pure-unsafe/log"; then
  echo "  ok  Unsafe effect propagates into pure constraint"; pass=$((pass + 1))
else
  echo "  XX  pure Unsafe-effect rejection missing E0002"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-unsafe-type"
printf 'name = "v2unsafetype"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-unsafe-type/zag.mod"
printf 'fn main() i32 { unsafe { let x: i32 = "wrong"; } return 0; }\n' >"$tmp/v2-unsafe-type/main.zag"
if (cd "$tmp/v2-unsafe-type" && "$ZNC" main.zag -o out) >"$tmp/v2-unsafe-type/log" 2>&1 || [ -e "$tmp/v2-unsafe-type/out" ]; then
  echo "  XX  unsafe block retains ordinary typing"; sed -n '1,8p' "$tmp/v2-unsafe-type/log"; fail=$((fail + 1))
elif grep -q E0203 "$tmp/v2-unsafe-type/log"; then
  echo "  ok  unsafe block retains ordinary typing without artifact"; pass=$((pass + 1))
else
  echo "  XX  unsafe block type rejection missing E0203"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-format"
printf 'name = "v2format"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-format/zag.mod"
printf 'unsafe fn raw() i32{return 42;} fn main() i32{unsafe{return raw();}}\n' >"$tmp/v2-format/main.zag"
if (cd "$tmp/v2-format" && "$ZNC" fmt --in-place main.zag) >"$tmp/v2-format/log" 2>&1 &&
   grep -q '^unsafe fn raw' "$tmp/v2-format/main.zag" && grep -q 'unsafe {' "$tmp/v2-format/main.zag" &&
   ! grep -q '__zag_unsafe' "$tmp/v2-format/main.zag"; then
  echo "  ok  formatter preserves dedicated unsafe nodes"; pass=$((pass + 1))
else
  echo "  XX  formatter preserves dedicated unsafe nodes"; sed -n '1,12p' "$tmp/v2-format/main.zag"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-cross-target"
printf 'name = "v2cross"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cross-target/zag.mod"
printf 'unsafe fn raw() i32 { return 42; } fn main() i32 { unsafe { return raw(); } }\n' >"$tmp/v2-cross-target/main.zag"
if (cd "$tmp/v2-cross-target" && "$ZNC" main.zag --target arm64 -o main.arm64) >"$tmp/v2-cross-target/arm64.log" 2>&1 &&
   [ -x "$tmp/v2-cross-target/main.arm64" ]; then
  echo "  ok  AArch64 preserves unsafe function and block"; pass=$((pass + 1))
else
  echo "  XX  AArch64 preserves unsafe function and block"; sed -n '1,8p' "$tmp/v2-cross-target/arm64.log"; fail=$((fail + 1))
fi
if (cd "$tmp/v2-cross-target" && "$ZNC" main.zag --target wasm -o main.wasm) >"$tmp/v2-cross-target/wasm.log" 2>&1 &&
   [ -s "$tmp/v2-cross-target/main.wasm" ]; then
  echo "  ok  WASM preserves unsafe function and block"; pass=$((pass + 1))
else
  echo "  XX  WASM preserves unsafe function and block"; sed -n '1,8p' "$tmp/v2-cross-target/wasm.log"; fail=$((fail + 1))
fi
printf 'fn unsafeKernel(out: []i32) void @kernel { unsafe { out[0] = 42; } } fn main() void { }\n' >"$tmp/v2-cross-target/gpu.zag"
if (cd "$tmp/v2-cross-target" && "$ZNC" gpu.zag --target gpu-amd) >"$tmp/v2-cross-target/gpu.log" 2>&1 &&
   grep -q 'memref.store' "$tmp/v2-cross-target/gpu.mlir"; then
  echo "  ok  GPU MLIR preserves unsafe block body"; pass=$((pass + 1))
else
  echo "  XX  GPU MLIR preserves unsafe block body"; sed -n '1,8p' "$tmp/v2-cross-target/gpu.log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-pointer"
printf 'name = "v2pointer"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-pointer/zag.mod"
printf 'fn keep(p: *const i32) *const i32 { return p; } fn main() i32 { print_i64(42); return 0; }\n' >"$tmp/v2-pointer/main.zag"
if (cd "$tmp/v2-pointer" && "$ZNC" main.zag -o out) >"$tmp/v2-pointer/log" 2>&1 &&
   [ -x "$tmp/v2-pointer/out" ] && [ "$("$tmp/v2-pointer/out")" = 42 ]; then
  echo "  ok  v2 raw-pointer categories reach typed native lowering"; pass=$((pass + 1))
else
  echo "  XX  v2 raw-pointer categories reach typed native lowering"; sed -n '1,8p' "$tmp/v2-pointer/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-deref"
printf 'name = "v2deref"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-deref/zag.mod"
printf 'fn main() i32 { let x: i32 = 42; unsafe { let p: *const i32 = (&x) as *const i32; return p.*; } }\n' >"$tmp/v2-deref/main.zag"
if (cd "$tmp/v2-deref" && "$ZNC" main.zag -o out) >"$tmp/v2-deref/log" 2>&1 && [ -x "$tmp/v2-deref/out" ]; then
  set +e
  "$tmp/v2-deref/out"
  deref_ec=$?
  set -e
  if [ "$deref_ec" -eq 42 ]; then
    echo "  ok  unsafe raw-pointer dereference executes"; pass=$((pass + 1))
  else
    echo "  XX  unsafe raw-pointer dereference executes (exit=$deref_ec)"; fail=$((fail + 1))
  fi
else
  echo "  XX  unsafe raw-pointer dereference compiles"; sed -n '1,8p' "$tmp/v2-deref/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-safe-deref"
printf 'name = "v2safederef"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-safe-deref/zag.mod"
printf 'fn read(p: *const i32) i32 { return p.*; } fn main() i32 { return 0; }\n' >"$tmp/v2-safe-deref/main.zag"
if (cd "$tmp/v2-safe-deref" && "$ZNC" main.zag -o out) >"$tmp/v2-safe-deref/log" 2>&1 ||
   [ -e "$tmp/v2-safe-deref/out" ]; then
  echo "  XX  safe scope rejects raw-pointer dereference"; sed -n '1,8p' "$tmp/v2-safe-deref/log"; fail=$((fail + 1))
elif grep -q E0204 "$tmp/v2-safe-deref/log"; then
  echo "  ok  safe scope rejects raw-pointer dereference without artifact"; pass=$((pass + 1))
else
  echo "  XX  safe scope raw-pointer rejection missing E0204"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-const-write"
printf 'name = "v2constwrite"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-const-write/zag.mod"
printf 'fn write(p: *const i32) void { unsafe { p.* = 1; } } fn main() i32 { return 0; }\n' >"$tmp/v2-const-write/main.zag"
if (cd "$tmp/v2-const-write" && "$ZNC" main.zag -o out) >"$tmp/v2-const-write/log" 2>&1 ||
   [ -e "$tmp/v2-const-write/out" ]; then
  echo "  XX  const raw pointer rejects mutation"; sed -n '1,8p' "$tmp/v2-const-write/log"; fail=$((fail + 1))
elif grep -q 'cannot write through' "$tmp/v2-const-write/log"; then
  echo "  ok  const raw pointer rejects mutation without artifact"; pass=$((pass + 1))
else
  echo "  XX  const raw pointer mutation rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-double-free"
printf 'name = "v2doublefree"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-double-free/zag.mod"
printf 'fn main() i32 { unsafe { let p: *mut i32 = new(42) as *mut i32; delete(p); delete(p); } return 0; }\n' >"$tmp/v2-double-free/main.zag"
if (cd "$tmp/v2-double-free" && "$ZNC" main.zag -o out) >"$tmp/v2-double-free/log" 2>&1 || [ -e "$tmp/v2-double-free/out" ]; then
  echo "  XX  statically evident double free rejects without artifact"; sed -n '1,8p' "$tmp/v2-double-free/log"; fail=$((fail + 1))
elif grep -q 'double free of named allocation' "$tmp/v2-double-free/log"; then
  echo "  ok  statically evident double free rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  double-free rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-use-after-free"
printf 'name = "v2useafterfree"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-use-after-free/zag.mod"
printf 'fn main() i32 { unsafe { let p: *mut i32 = new(42) as *mut i32; delete(p); print_i64(p as i64); } return 0; }\n' >"$tmp/v2-use-after-free/main.zag"
if (cd "$tmp/v2-use-after-free" && "$ZNC" main.zag -o out) >"$tmp/v2-use-after-free/log" 2>&1 || [ -e "$tmp/v2-use-after-free/out" ]; then
  echo "  XX  statically evident use after free rejects without artifact"; sed -n '1,8p' "$tmp/v2-use-after-free/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `p`' "$tmp/v2-use-after-free/log"; then
  echo "  ok  statically evident use after free rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  use-after-free rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-alias-use-after-free"
printf 'name = "v2aliasuseafterfree"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-alias-use-after-free/zag.mod"
printf 'fn main() i32 { unsafe { let p: *mut i32 = new(42) as *mut i32; let q: *mut i32 = p; delete(p); print_i64(q as i64); } return 0; }\n' >"$tmp/v2-alias-use-after-free/main.zag"
if (cd "$tmp/v2-alias-use-after-free" && "$ZNC" main.zag -o out) >"$tmp/v2-alias-use-after-free/log" 2>&1 || [ -e "$tmp/v2-alias-use-after-free/out" ]; then
  echo "  XX  local alias use after free rejects without artifact"; sed -n '1,8p' "$tmp/v2-alias-use-after-free/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `p`' "$tmp/v2-alias-use-after-free/log"; then
  echo "  ok  local alias use after free rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  alias use-after-free rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-conditional-use-after-free"
printf 'name = "v2conditionaluseafterfree"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-conditional-use-after-free/zag.mod"
printf 'fn main() i32 { unsafe { let p: *mut i32 = new(42) as *mut i32; if (1 == 1) { delete(p); } print_i64(p as i64); } return 0; }\n' >"$tmp/v2-conditional-use-after-free/main.zag"
if (cd "$tmp/v2-conditional-use-after-free" && "$ZNC" main.zag -o out) >"$tmp/v2-conditional-use-after-free/log" 2>&1 || [ -e "$tmp/v2-conditional-use-after-free/out" ]; then
  echo "  XX  conditional use after free rejects without artifact"; sed -n '1,8p' "$tmp/v2-conditional-use-after-free/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `p`' "$tmp/v2-conditional-use-after-free/log"; then
  echo "  ok  conditional use after free rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  conditional use-after-free rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-leak"
printf 'name = "v2ownedleak"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-leak/zag.mod"
printf 'fn main() i32 { unsafe { let p: *mut i32 = new(42) as *mut i32; } return 0; }\n' >"$tmp/v2-owned-leak/main.zag"
if (cd "$tmp/v2-owned-leak" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-leak/log" 2>&1 || [ -e "$tmp/v2-owned-leak/out" ]; then
  echo "  XX  owned allocation leak rejects without artifact"; sed -n '1,8p' "$tmp/v2-owned-leak/log"; fail=$((fail + 1))
elif grep -q 'owned allocation `p` is neither released nor returned' "$tmp/v2-owned-leak/log"; then
  echo "  ok  owned allocation leak rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  owned allocation leak rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-alias-return"
printf 'name = "v2ownedaliasreturn"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-alias-return/zag.mod"
printf 'struct Node { value:i32 } fn allocate() *mut Node { unsafe { let p: *mut Node = new(Node{.value=42}) as *mut Node; let q: *mut Node = p; return q; } } fn main() i32 { let p: *mut Node = allocate(); unsafe { delete(p); } return 0; }\n' >"$tmp/v2-owned-alias-return/main.zag"
if (cd "$tmp/v2-owned-alias-return" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-alias-return/log" 2>&1 && [ -x "$tmp/v2-owned-alias-return/out" ]; then
  echo "  ok  alias return transfers owned allocation"; pass=$((pass + 1))
else
  echo "  XX  alias return ownership transfer"; sed -n '1,8p' "$tmp/v2-owned-alias-return/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-assignment-leak"
printf 'name = "v2ownedassignmentleak"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-assignment-leak/zag.mod"
printf 'struct Node { value:i32 } fn main() i32 { unsafe { let p:*mut Node; p = new(Node{.value=42}) as *mut Node; } return 0; }\n' >"$tmp/v2-owned-assignment-leak/main.zag"
if (cd "$tmp/v2-owned-assignment-leak" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-assignment-leak/log" 2>&1 || [ -e "$tmp/v2-owned-assignment-leak/out" ]; then
  echo "  XX  assignment-owned allocation leak rejects without artifact"; sed -n '1,8p' "$tmp/v2-owned-assignment-leak/log"; fail=$((fail + 1))
elif grep -q 'owned allocation `p` is neither released nor returned' "$tmp/v2-owned-assignment-leak/log"; then
  echo "  ok  assignment-owned allocation leak rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  assignment-owned allocation leak rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-assignment-release"
printf 'name = "v2ownedassignmentrelease"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-assignment-release/zag.mod"
printf 'struct Node { value:i32 } fn main() i32 { unsafe { let p:*mut Node; p = new(Node{.value=42}) as *mut Node; delete(p); } return 0; }\n' >"$tmp/v2-owned-assignment-release/main.zag"
if (cd "$tmp/v2-owned-assignment-release" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-assignment-release/log" 2>&1 && [ -x "$tmp/v2-owned-assignment-release/out" ]; then
  echo "  ok  assignment-owned allocation release compiles"; pass=$((pass + 1))
else
  echo "  XX  assignment-owned allocation release"; sed -n '1,8p' "$tmp/v2-owned-assignment-release/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-consume"
printf 'name = "v2ownedconsume"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-consume/zag.mod"
printf 'struct Node { value:i32 } fn consume(p:*mut Node) void @consumes { unsafe { delete(p); } } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; consume(p); print_i64(p as i64); } return 0; }\n' >"$tmp/v2-owned-consume/main.zag"
if (cd "$tmp/v2-owned-consume" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-consume/log" 2>&1 || [ -e "$tmp/v2-owned-consume/out" ]; then
  echo "  XX  consumed owner use rejects without artifact"; sed -n '1,8p' "$tmp/v2-owned-consume/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `p`' "$tmp/v2-owned-consume/log"; then
  echo "  ok  consumed owner use rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  consume ownership rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-conditional-release"
printf 'name = "v2ownedconditionalrelease"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-conditional-release/zag.mod"
printf 'struct Node { value:i32 } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; if (1 == 1) { delete(p); } } return 0; }\n' >"$tmp/v2-owned-conditional-release/main.zag"
if (cd "$tmp/v2-owned-conditional-release" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-conditional-release/log" 2>&1 || [ -e "$tmp/v2-owned-conditional-release/out" ]; then
  echo "  XX  conditional release rejects without artifact"; sed -n '1,8p' "$tmp/v2-owned-conditional-release/log"; fail=$((fail + 1))
elif grep -q 'not released or returned on every control-flow path' "$tmp/v2-owned-conditional-release/log"; then
  echo "  ok  conditional release rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  conditional release rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-uncontracted-escape"
printf 'name = "v2owneduncontractedescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-uncontracted-escape/zag.mod"
printf 'struct Node { value:i32 } fn retain(p:*mut Node) void { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; retain(p); delete(p); } return 0; }\n' >"$tmp/v2-owned-uncontracted-escape/main.zag"
if (cd "$tmp/v2-owned-uncontracted-escape" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-uncontracted-escape/log" 2>&1 || [ -e "$tmp/v2-owned-uncontracted-escape/out" ]; then
  echo "  XX  uncontracted owned escape rejects without artifact"; sed -n '1,8p' "$tmp/v2-owned-uncontracted-escape/log"; fail=$((fail + 1))
elif grep -q 'owned allocation escapes through uncontracted call `retain`' "$tmp/v2-owned-uncontracted-escape/log"; then
  echo "  ok  uncontracted owned escape rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  uncontracted owned escape rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-borrow-contract"
printf 'name = "v2ownedborrowcontract"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-borrow-contract/zag.mod"
printf 'struct Node { value:i32 } fn inspect(p:*mut Node) void @borrows { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; inspect(p); delete(p); } return 0; }\n' >"$tmp/v2-owned-borrow-contract/main.zag"
if (cd "$tmp/v2-owned-borrow-contract" && "$ZNC" check main.zag) >"$tmp/v2-owned-borrow-contract/log" 2>&1; then
  echo "  ok  declared borrow permits owned call"; pass=$((pass + 1))
else
  echo "  XX  declared borrow permits owned call"; sed -n '1,8p' "$tmp/v2-owned-borrow-contract/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-borrow-mut-contract"
printf 'name = "v2ownedborrowmutcontract"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-borrow-mut-contract/zag.mod"
printf 'struct Node { value:i32 } fn edit(p:*mut Node) void @borrows_mut { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; edit(p); delete(p); } return 0; }\n' >"$tmp/v2-owned-borrow-mut-contract/main.zag"
if (cd "$tmp/v2-owned-borrow-mut-contract" && "$ZNC" check main.zag) >"$tmp/v2-owned-borrow-mut-contract/log" 2>&1; then
  echo "  ok  declared mutable borrow permits owned call"; pass=$((pass + 1))
else
  echo "  XX  declared mutable borrow permits owned call"; sed -n '1,8p' "$tmp/v2-owned-borrow-mut-contract/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-consume-contract"
printf 'name = "v2ownedconsumecontract"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-consume-contract/zag.mod"
printf 'struct Node { value:i32 } fn dispose(p:*mut Node) void @consumes { unsafe { delete(p); } } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; dispose(p); } return 0; }\n' >"$tmp/v2-owned-consume-contract/main.zag"
if (cd "$tmp/v2-owned-consume-contract" && "$ZNC" check main.zag) >"$tmp/v2-owned-consume-contract/log" 2>&1; then
  echo "  ok  declared consume permits owned transfer"; pass=$((pass + 1))
else
  echo "  XX  declared consume permits owned transfer"; sed -n '1,8p' "$tmp/v2-owned-consume-contract/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-condition-alias-escape"
printf 'name = "v2ownedconditionaliasescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-condition-alias-escape/zag.mod"
printf 'struct Node { value:i32 } fn retain(p:*mut Node) i32 { return 0; } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; let q:*mut Node=p; if (retain(q) == 0) { } delete(p); } return 0; }\n' >"$tmp/v2-owned-condition-alias-escape/main.zag"
if (cd "$tmp/v2-owned-condition-alias-escape" && "$ZNC" check main.zag) >"$tmp/v2-owned-condition-alias-escape/log" 2>&1; then
  echo "  XX  alias passed through conditional uncontracted call rejects"; sed -n '1,8p' "$tmp/v2-owned-condition-alias-escape/log"; fail=$((fail + 1))
elif grep -q 'owned allocation escapes through uncontracted call `retain`' "$tmp/v2-owned-condition-alias-escape/log"; then
  echo "  ok  alias passed through conditional uncontracted call rejects"; pass=$((pass + 1))
else
  echo "  XX  conditional alias ownership escape diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-shared-borrow-write"
printf 'name = "v2sharedborrowwrite"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-shared-borrow-write/zag.mod"
printf 'fn inspect(p:*mut i32) *mut i32 @borrows { unsafe { p.* = 1; return p; } } fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let q:*mut i32=inspect(p); delete(p); } return 0; }\n' >"$tmp/v2-shared-borrow-write/main.zag"
if (cd "$tmp/v2-shared-borrow-write" && "$ZNC" main.zag -o out) >"$tmp/v2-shared-borrow-write/log" 2>&1 || [ -e "$tmp/v2-shared-borrow-write/out" ]; then
  echo "  XX  shared borrow mutation rejects without artifact"; sed -n '1,8p' "$tmp/v2-shared-borrow-write/log"; fail=$((fail + 1))
elif grep -q 'cannot mutate through a shared borrow' "$tmp/v2-shared-borrow-write/log"; then
  echo "  ok  shared borrow mutation rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  shared borrow mutation rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-switch-release"
printf 'name = "v2ownedswitchrelease"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-switch-release/zag.mod"
printf 'struct Node { value:i32 } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; switch (1) { 1 => { delete(p); } else => { delete(p); } } } return 0; }\n' >"$tmp/v2-owned-switch-release/main.zag"
if (cd "$tmp/v2-owned-switch-release" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-switch-release/log" 2>&1 && [ -x "$tmp/v2-owned-switch-release/out" ]; then
  echo "  ok  all switch paths release owner"; pass=$((pass + 1))
else
  echo "  XX  all switch paths release owner"; sed -n '1,8p' "$tmp/v2-owned-switch-release/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-switch-partial"
printf 'name = "v2ownedswitchpartial"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-switch-partial/zag.mod"
printf 'struct Node { value:i32 } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; switch (1) { 1 => { delete(p); } else => { } } } return 0; }\n' >"$tmp/v2-owned-switch-partial/main.zag"
if (cd "$tmp/v2-owned-switch-partial" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-switch-partial/log" 2>&1 || [ -e "$tmp/v2-owned-switch-partial/out" ]; then
  echo "  XX  partial switch release rejects without artifact"; sed -n '1,8p' "$tmp/v2-owned-switch-partial/log"; fail=$((fail + 1))
elif grep -q 'not released or returned on every control-flow path' "$tmp/v2-owned-switch-partial/log"; then
  echo "  ok  partial switch release rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  partial switch release rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-switch-escape"
printf 'name = "v2ownedswitchescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-switch-escape/zag.mod"
printf 'struct Node { value:i32 } fn retain(p:*mut Node) void { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; switch (1) { 1 => { retain(p); } else => { } } delete(p); } return 0; }\n' >"$tmp/v2-owned-switch-escape/main.zag"
if (cd "$tmp/v2-owned-switch-escape" && "$ZNC" check main.zag) >"$tmp/v2-owned-switch-escape/log" 2>&1 || [ -e "$tmp/v2-owned-switch-escape/out" ]; then
  echo "  XX  switch ownership escape rejects"; sed -n '1,8p' "$tmp/v2-owned-switch-escape/log"; fail=$((fail + 1))
elif grep -q 'owned allocation escapes through uncontracted call `retain`' "$tmp/v2-owned-switch-escape/log"; then
  echo "  ok  switch ownership escape rejects"; pass=$((pass + 1))
else
  echo "  XX  switch ownership escape diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-exclusive-borrow-active"
printf 'name = "v2exclusiveborrowactive"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-exclusive-borrow-active/zag.mod"
printf 'fn edit(p:*mut i32) *mut i32 @borrows_mut { unsafe { p.* = 7; return p; } } fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let q:*mut i32=edit(p); print_i64(p as i64); delete(p); } return 0; }\n' >"$tmp/v2-exclusive-borrow-active/main.zag"
if (cd "$tmp/v2-exclusive-borrow-active" && "$ZNC" main.zag -o out) >"$tmp/v2-exclusive-borrow-active/log" 2>&1 || [ -e "$tmp/v2-exclusive-borrow-active/out" ]; then
  echo "  XX  active exclusive borrow rejects owner use without artifact"; sed -n '1,8p' "$tmp/v2-exclusive-borrow-active/log"; fail=$((fail + 1))
elif grep -q 'exclusive mutable borrow is active' "$tmp/v2-exclusive-borrow-active/log"; then
  echo "  ok  active exclusive borrow rejects owner use without artifact"; pass=$((pass + 1))
else
  echo "  XX  active exclusive borrow rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-shared-blocks-exclusive"
printf 'name = "v2sharedblocksexclusive"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-shared-blocks-exclusive/zag.mod"
printf 'fn inspect(p:*mut i32) *mut i32 @borrows { return p; } fn edit(p:*mut i32) *mut i32 @borrows_mut { unsafe { return p; } } fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let s:*mut i32=inspect(p); let m:*mut i32=edit(p); delete(p); } return 0; }\n' >"$tmp/v2-shared-blocks-exclusive/main.zag"
if (cd "$tmp/v2-shared-blocks-exclusive" && "$ZNC" main.zag -o out) >"$tmp/v2-shared-blocks-exclusive/log" 2>&1 || [ -e "$tmp/v2-shared-blocks-exclusive/out" ]; then
  echo "  XX  shared borrow blocks exclusive borrow without artifact"; sed -n '1,8p' "$tmp/v2-shared-blocks-exclusive/log"; fail=$((fail + 1))
elif grep -q 'exclusive mutable borrow while a shared borrow is active' "$tmp/v2-shared-blocks-exclusive/log"; then
  echo "  ok  shared borrow blocks exclusive borrow without artifact"; pass=$((pass + 1))
else
  echo "  XX  shared/exclusive borrow rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-borrow-alias-consume"
printf 'name = "v2borrowaliasconsume"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-borrow-alias-consume/zag.mod"
printf 'struct Node { value:i32 } fn inspect(p:*mut Node) *mut Node @borrows { return p; } fn consume(p:*mut Node) void @consumes { unsafe { delete(p); } } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; let s:*mut Node=inspect(p); let alias:*mut Node=s; consume(alias); } return 0; }\n' >"$tmp/v2-borrow-alias-consume/main.zag"
if (cd "$tmp/v2-borrow-alias-consume" && "$ZNC" main.zag -o out) >"$tmp/v2-borrow-alias-consume/log" 2>&1 || [ -e "$tmp/v2-borrow-alias-consume/out" ]; then
  echo "  XX  borrow alias cannot be consumed without artifact"; sed -n '1,8p' "$tmp/v2-borrow-alias-consume/log"; fail=$((fail + 1))
elif grep -q 'cannot pass a borrow to a consuming call' "$tmp/v2-borrow-alias-consume/log"; then
  echo "  ok  borrow alias cannot be consumed without artifact"; pass=$((pass + 1))
else
  echo "  XX  borrow alias consume rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-consumes-body-leak"
printf 'name = "v2consumesbodyleak"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-consumes-body-leak/zag.mod"
printf 'struct Node { value:i32 } fn discard(p:*mut Node) void @consumes { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; discard(p); } return 0; }\n' >"$tmp/v2-consumes-body-leak/main.zag"
if (cd "$tmp/v2-consumes-body-leak" && "$ZNC" main.zag -o out) >"$tmp/v2-consumes-body-leak/log" 2>&1 || [ -e "$tmp/v2-consumes-body-leak/out" ]; then
  echo "  XX  @consumes body must discharge its owner"; sed -n '1,8p' "$tmp/v2-consumes-body-leak/log"; fail=$((fail + 1))
elif grep -q '@consumes parameter `p` is not released or transferred on every control-flow path' "$tmp/v2-consumes-body-leak/log"; then
  echo "  ok  @consumes body must discharge its owner"; pass=$((pass + 1))
else
  echo "  XX  @consumes discharge diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-borrow-forward-escape"
printf 'name = "v2borrowforwardescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-borrow-forward-escape/zag.mod"
printf 'struct Node { value:i32 } fn retain(p:*mut Node) void { } fn inspect(p:*mut Node) void @borrows { retain(p); } fn main() i32 { return 0; }\n' >"$tmp/v2-borrow-forward-escape/main.zag"
if (cd "$tmp/v2-borrow-forward-escape" && "$ZNC" check main.zag) >"$tmp/v2-borrow-forward-escape/log" 2>&1; then
  echo "  XX  borrowed parameter forwarding must be contracted"; sed -n '1,8p' "$tmp/v2-borrow-forward-escape/log"; fail=$((fail + 1))
elif grep -q 'borrowed value `p` escapes through uncontracted call `retain`' "$tmp/v2-borrow-forward-escape/log"; then
  echo "  ok  borrowed parameter forwarding must be contracted"; pass=$((pass + 1))
else
  echo "  XX  borrowed forwarding diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-return-drop"
printf 'name = "v2ownedreturndrop"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-return-drop/zag.mod"
printf 'struct Node { value:i32 } fn allocate() *mut Node { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; return p; } } fn main() i32 { let leaked:*mut Node=allocate(); return 0; }\n' >"$tmp/v2-owned-return-drop/main.zag"
if (cd "$tmp/v2-owned-return-drop" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-return-drop/log" 2>&1 || [ -e "$tmp/v2-owned-return-drop/out" ]; then
  echo "  XX  owned helper result must be discharged"; sed -n '1,8p' "$tmp/v2-owned-return-drop/log"; fail=$((fail + 1))
elif grep -q 'owned allocation `leaked` is neither released nor returned' "$tmp/v2-owned-return-drop/log"; then
  echo "  ok  owned helper result must be discharged"; pass=$((pass + 1))
else
  echo "  XX  owned helper result diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-return-mixed"
printf 'name = "v2ownedreturnmixed"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-return-mixed/zag.mod"
printf 'struct Node { value:i32 } fn choose(flag:i32) *mut Node { unsafe { if (flag == 1) { let p:*mut Node=new(Node{.value=42}) as *mut Node; return p; } return null as *mut Node; } } fn main() i32 { return 0; }\n' >"$tmp/v2-owned-return-mixed/main.zag"
if (cd "$tmp/v2-owned-return-mixed" && "$ZNC" check main.zag) >"$tmp/v2-owned-return-mixed/log" 2>&1; then
  echo "  XX  mixed owned return provenance must reject"; sed -n '1,8p' "$tmp/v2-owned-return-mixed/log"; fail=$((fail + 1))
elif grep -q 'function `choose` mixes owned and non-owned return provenance' "$tmp/v2-owned-return-mixed/log"; then
  echo "  ok  mixed owned return provenance must reject"; pass=$((pass + 1))
else
  echo "  XX  mixed owned return diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-live-owner-overwrite"
printf 'name = "v2liveowneroverwrite"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-live-owner-overwrite/zag.mod"
printf 'struct Node { value:i32 } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=1}) as *mut Node; p=new(Node{.value=2}) as *mut Node; delete(p); } return 0; }\n' >"$tmp/v2-live-owner-overwrite/main.zag"
if (cd "$tmp/v2-live-owner-overwrite" && "$ZNC" main.zag -o out) >"$tmp/v2-live-owner-overwrite/log" 2>&1 || [ -e "$tmp/v2-live-owner-overwrite/out" ]; then
  echo "  XX  live owner overwrite must reject"; sed -n '1,8p' "$tmp/v2-live-owner-overwrite/log"; fail=$((fail + 1))
elif grep -q 'live owned allocation `p` is overwritten before release or transfer' "$tmp/v2-live-owner-overwrite/log"; then
  echo "  ok  live owner overwrite must reject"; pass=$((pass + 1))
else
  echo "  XX  live owner overwrite diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-cast-escape"
printf 'name = "v2ownedcastescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-cast-escape/zag.mod"
printf 'struct Node { value:i32 } fn retain(p:*mut Node) void { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; retain(p as *mut Node); delete(p); } return 0; }\n' >"$tmp/v2-owned-cast-escape/main.zag"
if (cd "$tmp/v2-owned-cast-escape" && "$ZNC" check main.zag) >"$tmp/v2-owned-cast-escape/log" 2>&1; then
  echo "  XX  cast cannot launder owned escape"; sed -n '1,8p' "$tmp/v2-owned-cast-escape/log"; fail=$((fail + 1))
elif grep -q 'owned allocation escapes through uncontracted call `retain`' "$tmp/v2-owned-cast-escape/log"; then
  echo "  ok  cast cannot launder owned escape"; pass=$((pass + 1))
else
  echo "  XX  cast ownership escape diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-aggregate-escape"
printf 'name = "v2ownedaggregateescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-aggregate-escape/zag.mod"
printf 'struct Node { value:i32 } struct Box { ptr:*mut Node } fn retain_box(value:Box) void { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; retain_box(Box{.ptr=p}); delete(p); } return 0; }\n' >"$tmp/v2-owned-aggregate-escape/main.zag"
if (cd "$tmp/v2-owned-aggregate-escape" && "$ZNC" check main.zag) >"$tmp/v2-owned-aggregate-escape/log" 2>&1; then
  echo "  XX  aggregate cannot launder owned escape"; sed -n '1,8p' "$tmp/v2-owned-aggregate-escape/log"; fail=$((fail + 1))
elif grep -q 'owned allocation escapes through uncontracted call `retain_box`' "$tmp/v2-owned-aggregate-escape/log"; then
  echo "  ok  aggregate cannot launder owned escape"; pass=$((pass + 1))
else
  echo "  XX  aggregate ownership escape diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-nested-escape"
printf 'name = "v2ownednestedescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-nested-escape/zag.mod"
printf 'struct Node { value:i32 } fn view(p:*mut Node) *mut Node @borrows { return p; } fn retain(p:*mut Node) void { } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; retain(view(p)); delete(p); } return 0; }\n' >"$tmp/v2-owned-nested-escape/main.zag"
if (cd "$tmp/v2-owned-nested-escape" && "$ZNC" check main.zag) >"$tmp/v2-owned-nested-escape/log" 2>&1; then
  echo "  XX  nested call cannot launder owned escape"; sed -n '1,8p' "$tmp/v2-owned-nested-escape/log"; fail=$((fail + 1))
elif grep -q 'owned allocation escapes through uncontracted call `retain`' "$tmp/v2-owned-nested-escape/log"; then
  echo "  ok  nested call cannot launder owned escape"; pass=$((pass + 1))
else
  echo "  XX  nested ownership escape diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-branch-alias"
printf 'name = "v2ownedbranchalias"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-branch-alias/zag.mod"
printf 'struct Node { value:i32 } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; let q:*mut Node; if (1 == 1) { q=p; } else { q=p; } delete(p); print_i64(q as i64); } return 0; }\n' >"$tmp/v2-owned-branch-alias/main.zag"
if (cd "$tmp/v2-owned-branch-alias" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-branch-alias/log" 2>&1 || [ -e "$tmp/v2-owned-branch-alias/out" ]; then
  echo "  XX  agreed branch alias use after free must reject"; sed -n '1,8p' "$tmp/v2-owned-branch-alias/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `p`' "$tmp/v2-owned-branch-alias/log"; then
  echo "  ok  agreed branch alias use after free must reject"; pass=$((pass + 1))
else
  echo "  XX  branch alias lifetime diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-exclusive-borrow-assignment"
printf 'name = "v2exclusiveborrowassignment"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-exclusive-borrow-assignment/zag.mod"
printf 'fn edit(p:*mut i32) *mut i32 @borrows_mut { unsafe { return p; } } fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let q:*mut i32; q=edit(p); print_i64(p as i64); delete(p); } return 0; }\n' >"$tmp/v2-exclusive-borrow-assignment/main.zag"
if (cd "$tmp/v2-exclusive-borrow-assignment" && "$ZNC" main.zag -o out) >"$tmp/v2-exclusive-borrow-assignment/log" 2>&1 || [ -e "$tmp/v2-exclusive-borrow-assignment/out" ]; then
  echo "  XX  assigned exclusive borrow keeps owner unavailable"; sed -n '1,8p' "$tmp/v2-exclusive-borrow-assignment/log"; fail=$((fail + 1))
elif grep -q 'exclusive mutable borrow is active' "$tmp/v2-exclusive-borrow-assignment/log"; then
  echo "  ok  assigned exclusive borrow keeps owner unavailable"; pass=$((pass + 1))
else
  echo "  XX  assigned exclusive borrow diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-nullable-deref"
printf 'name = "v2nullablederef"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-nullable-deref/zag.mod"
printf 'unsafe fn load(p: ?*const i32) i32 { return p.*; } fn main() i32 { return 0; }\n' >"$tmp/v2-nullable-deref/main.zag"
if (cd "$tmp/v2-nullable-deref" && "$ZNC" main.zag -o out) >"$tmp/v2-nullable-deref/log" 2>&1 || [ -e "$tmp/v2-nullable-deref/out" ]; then
  echo "  XX  nullable raw pointer dereference requires unwrap"; sed -n '1,8p' "$tmp/v2-nullable-deref/log"; fail=$((fail + 1))
elif grep -q 'nullable raw pointer must be explicitly unwrapped' "$tmp/v2-nullable-deref/log"; then
  echo "  ok  nullable raw pointer dereference requires explicit unwrap without artifact"; pass=$((pass + 1))
else
  echo "  XX  nullable raw pointer rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-nullable-unwrapped"
printf 'name = "v2nullableunwrapped"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-nullable-unwrapped/zag.mod"
printf 'unsafe fn load(p: ?*const i32) i32 { return p.?.*; } fn main() i32 { let x: i32 = 42; unsafe { return load((&x) as *const i32); } }\n' >"$tmp/v2-nullable-unwrapped/main.zag"
if (cd "$tmp/v2-nullable-unwrapped" && "$ZNC" main.zag -o out) >"$tmp/v2-nullable-unwrapped/log" 2>&1 && [ -x "$tmp/v2-nullable-unwrapped/out" ]; then
  set +e
  "$tmp/v2-nullable-unwrapped/out"
  nullable_ec=$?
  set -e
  if [ "$nullable_ec" -eq 42 ]; then
    echo "  ok  explicitly unwrapped nullable raw pointer executes"; pass=$((pass + 1))
  else
    echo "  XX  explicitly unwrapped nullable raw pointer execution (exit=$nullable_ec)"; fail=$((fail + 1))
  fi
else
  echo "  XX  explicitly unwrapped nullable raw pointer compiles"; sed -n '1,8p' "$tmp/v2-nullable-unwrapped/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-address-space-cast"
printf 'name = "v2addressspace"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-address-space-cast/zag.mod"
printf 'unsafe fn bad(p: *host i32) *device i32 { return p as *device i32; } fn main() i32 { return 0; }\n' >"$tmp/v2-address-space-cast/main.zag"
if (cd "$tmp/v2-address-space-cast" && "$ZNC" main.zag -o out) >"$tmp/v2-address-space-cast/log" 2>&1 || [ -e "$tmp/v2-address-space-cast/out" ]; then
  echo "  XX  distinct raw-pointer address spaces reject casts"; sed -n '1,8p' "$tmp/v2-address-space-cast/log"; fail=$((fail + 1))
elif grep -q 'cannot cast between distinct raw-pointer address spaces' "$tmp/v2-address-space-cast/log"; then
  echo "  ok  distinct raw-pointer address spaces reject casts without artifact"; pass=$((pass + 1))
else
  echo "  XX  address-space cast rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-cast-alias-use-after-free"
printf 'name = "v2castaliasuaf"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cast-alias-use-after-free/zag.mod"
printf 'fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let q:*mut i32=p as *mut i32; delete(p); print_i64(q as i64); } return 0; }\n' >"$tmp/v2-cast-alias-use-after-free/main.zag"
if (cd "$tmp/v2-cast-alias-use-after-free" && "$ZNC" main.zag -o out) >"$tmp/v2-cast-alias-use-after-free/log" 2>&1 || [ -e "$tmp/v2-cast-alias-use-after-free/out" ]; then
  echo "  XX  cast local alias use after free rejects without artifact"; sed -n '1,8p' "$tmp/v2-cast-alias-use-after-free/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `p`' "$tmp/v2-cast-alias-use-after-free/log"; then
  echo "  ok  cast local alias use after free rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  cast alias use-after-free diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-cast-alias-double-free"
printf 'name = "v2castaliasdoublefree"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cast-alias-double-free/zag.mod"
printf 'fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let q:*mut i32=p as *mut i32; delete(q); delete(p); } return 0; }\n' >"$tmp/v2-cast-alias-double-free/main.zag"
if (cd "$tmp/v2-cast-alias-double-free" && "$ZNC" main.zag -o out) >"$tmp/v2-cast-alias-double-free/log" 2>&1 || [ -e "$tmp/v2-cast-alias-double-free/out" ]; then
  echo "  XX  cast local alias double free rejects without artifact"; sed -n '1,8p' "$tmp/v2-cast-alias-double-free/log"; fail=$((fail + 1))
elif grep -q 'double free of named allocation' "$tmp/v2-cast-alias-double-free/log"; then
  echo "  ok  cast local alias double free rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  cast alias double-free diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-cast-alias-release"
printf 'name = "v2castaliasrelease"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cast-alias-release/zag.mod"
printf 'fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let q:*mut i32=p as *mut i32; delete(q as *mut i32); } return 0; }\n' >"$tmp/v2-cast-alias-release/main.zag"
if (cd "$tmp/v2-cast-alias-release" && "$ZNC" main.zag -o out) >"$tmp/v2-cast-alias-release/log" 2>&1 && [ -x "$tmp/v2-cast-alias-release/out" ]; then
  echo "  ok  cast owner alias release is recognized"; pass=$((pass + 1))
else
  echo "  XX  cast owner alias release"; sed -n '1,8p' "$tmp/v2-cast-alias-release/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-cast-borrow-consume"
printf 'name = "v2castborrowconsume"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cast-borrow-consume/zag.mod"
printf 'struct Node { value:i32 } fn inspect(p:*mut Node) *mut Node @borrows { return p; } fn consume(p:*mut Node) void @consumes { unsafe { delete(p); } } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; let s:*mut Node=inspect(p) as *mut Node; let alias:*mut Node=s as *mut Node; consume(alias as *mut Node); } return 0; }\n' >"$tmp/v2-cast-borrow-consume/main.zag"
if (cd "$tmp/v2-cast-borrow-consume" && "$ZNC" main.zag -o out) >"$tmp/v2-cast-borrow-consume/log" 2>&1 || [ -e "$tmp/v2-cast-borrow-consume/out" ]; then
  echo "  XX  cast borrow alias cannot be consumed without artifact"; sed -n '1,8p' "$tmp/v2-cast-borrow-consume/log"; fail=$((fail + 1))
elif grep -q 'cannot pass a borrow to a consuming call' "$tmp/v2-cast-borrow-consume/log"; then
  echo "  ok  cast borrow alias cannot be consumed without artifact"; pass=$((pass + 1))
else
  echo "  XX  cast borrow consume diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-cast-borrow-release"
printf 'name = "v2castborrowrelease"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cast-borrow-release/zag.mod"
printf 'struct Node { value:i32 } fn inspect(p:*mut Node) *mut Node @borrows { return p; } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; let s:*mut Node=inspect(p) as *mut Node; let alias:*mut Node=s as *mut Node; delete(alias as *mut Node); } return 0; }\n' >"$tmp/v2-cast-borrow-release/main.zag"
if (cd "$tmp/v2-cast-borrow-release" && "$ZNC" main.zag -o out) >"$tmp/v2-cast-borrow-release/log" 2>&1 || [ -e "$tmp/v2-cast-borrow-release/out" ]; then
  echo "  XX  cast borrow alias cannot be released without artifact"; sed -n '1,8p' "$tmp/v2-cast-borrow-release/log"; fail=$((fail + 1))
elif grep -q 'cannot pass a borrow to a consuming call' "$tmp/v2-cast-borrow-release/log"; then
  echo "  ok  cast borrow alias cannot be released without artifact"; pass=$((pass + 1))
else
  echo "  XX  cast borrow release diagnostic missing"; fail=$((fail + 1))
fi
# This is deliberately a bounded lifetime rule: a raw pointer may be returned
# when it comes from a parameter, but an address taken from a callee-local frame
# must never cross that return boundary. The two negative cases cover the direct
# spelling and a direct local alias through a raw-pointer cast.
mkdir -p "$tmp/v2-return-local-address"
printf 'name = "v2returnlocaladdress"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-local-address/zag.mod"
printf 'fn bad() *const i32 { let x:i32=42; unsafe { return (&x) as *const i32; } } fn main() i32 { return 0; }\n' >"$tmp/v2-return-local-address/main.zag"
if (cd "$tmp/v2-return-local-address" && "$ZNC" main.zag -o out) >"$tmp/v2-return-local-address/log" 2>&1 || [ -e "$tmp/v2-return-local-address/out" ]; then
  echo "  XX  direct local address return rejects without artifact"; sed -n '1,8p' "$tmp/v2-return-local-address/log"; fail=$((fail + 1))
elif grep -q 'address of local `x` escapes through return' "$tmp/v2-return-local-address/log"; then
  echo "  ok  direct local address return rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  direct local address return diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-return-local-address-alias"
printf 'name = "v2returnlocaladdressalias"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-local-address-alias/zag.mod"
printf 'fn bad() *const i32 { let x:i32=42; unsafe { let p:*const i32=(&x) as *const i32; return p; } } fn main() i32 { return 0; }\n' >"$tmp/v2-return-local-address-alias/main.zag"
if (cd "$tmp/v2-return-local-address-alias" && "$ZNC" main.zag -o out) >"$tmp/v2-return-local-address-alias/log" 2>&1 || [ -e "$tmp/v2-return-local-address-alias/out" ]; then
  echo "  XX  direct local-address alias return rejects without artifact"; sed -n '1,8p' "$tmp/v2-return-local-address-alias/log"; fail=$((fail + 1))
elif grep -q 'address of local `x` escapes through return' "$tmp/v2-return-local-address-alias/log"; then
  echo "  ok  direct local-address alias return rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  direct local-address alias return diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-return-parameter-pointer"
printf 'name = "v2returnparameterpointer"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-parameter-pointer/zag.mod"
printf 'fn keep(p:*const i32) *const i32 { return p; } fn main() i32 { let x:i32=42; unsafe { let p:*const i32=keep((&x) as *const i32); return p.*; } }\n' >"$tmp/v2-return-parameter-pointer/main.zag"
if (cd "$tmp/v2-return-parameter-pointer" && "$ZNC" main.zag -o out) >"$tmp/v2-return-parameter-pointer/log" 2>&1 &&
   [ -x "$tmp/v2-return-parameter-pointer/out" ]; then
  set +e
  "$tmp/v2-return-parameter-pointer/out"
  return_parameter_ec=$?
  set -e
  if [ "$return_parameter_ec" -eq 42 ]; then
    echo "  ok  parameter pointer return remains valid"; pass=$((pass + 1))
  else
    echo "  XX  parameter pointer return (exit=$return_parameter_ec)"; fail=$((fail + 1))
  fi
else
  echo "  XX  parameter pointer return"; sed -n '1,8p' "$tmp/v2-return-parameter-pointer/log"; fail=$((fail + 1))
fi
# Aggregate values can carry a frame address just as a raw pointer can. The
# first two cases cover a direct struct literal and a local aggregate alias;
# the field case proves that taking the address of stack-owned substorage is
# included. A pointer inherited from a caller remains a valid positive case.
mkdir -p "$tmp/v2-return-local-address-aggregate"
printf 'name = "v2returnlocaladdressaggregate"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-local-address-aggregate/zag.mod"
printf 'struct Box { ptr:*const i32 } fn bad() Box { let x:i32=42; unsafe { return Box{.ptr=(&x) as *const i32}; } } fn main() i32 { return 0; }\n' >"$tmp/v2-return-local-address-aggregate/main.zag"
if (cd "$tmp/v2-return-local-address-aggregate" && "$ZNC" main.zag -o out) >"$tmp/v2-return-local-address-aggregate/log" 2>&1 || [ -e "$tmp/v2-return-local-address-aggregate/out" ]; then
  echo "  XX  aggregate local-address return rejects without artifact"; sed -n '1,8p' "$tmp/v2-return-local-address-aggregate/log"; fail=$((fail + 1))
elif grep -q 'address of local `x` escapes through return' "$tmp/v2-return-local-address-aggregate/log"; then
  echo "  ok  aggregate local-address return rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  aggregate local-address return diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-return-local-address-union"
printf 'name = "v2returnlocaladdressunion"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-local-address-union/zag.mod"
printf 'union Choice { ptr:*const i32, value:i32 } fn bad() Choice { let x:i32=42; unsafe { return Choice{.ptr=(&x) as *const i32}; } } fn main() i32 { return 0; }\n' >"$tmp/v2-return-local-address-union/main.zag"
if (cd "$tmp/v2-return-local-address-union" && "$ZNC" main.zag -o out) >"$tmp/v2-return-local-address-union/log" 2>&1 || [ -e "$tmp/v2-return-local-address-union/out" ]; then
  echo "  XX  union local-address return rejects without artifact"; sed -n '1,8p' "$tmp/v2-return-local-address-union/log"; fail=$((fail + 1))
elif grep -q 'address of local `x` escapes through return' "$tmp/v2-return-local-address-union/log"; then
  echo "  ok  union local-address return rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  union local-address return diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-return-local-address-aggregate-alias"
printf 'name = "v2returnlocaladdressaggregatealias"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-local-address-aggregate-alias/zag.mod"
printf 'struct Box { ptr:*const i32 } fn bad() Box { let x:i32=42; unsafe { let box:Box=Box{.ptr=(&x) as *const i32}; return box; } } fn main() i32 { return 0; }\n' >"$tmp/v2-return-local-address-aggregate-alias/main.zag"
if (cd "$tmp/v2-return-local-address-aggregate-alias" && "$ZNC" main.zag -o out) >"$tmp/v2-return-local-address-aggregate-alias/log" 2>&1 || [ -e "$tmp/v2-return-local-address-aggregate-alias/out" ]; then
  echo "  XX  aggregate alias local-address return rejects without artifact"; sed -n '1,8p' "$tmp/v2-return-local-address-aggregate-alias/log"; fail=$((fail + 1))
elif grep -q 'address of local `x` escapes through return' "$tmp/v2-return-local-address-aggregate-alias/log"; then
  echo "  ok  aggregate alias local-address return rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  aggregate alias local-address diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-return-local-field-address"
printf 'name = "v2returnlocalfieldaddress"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-local-field-address/zag.mod"
printf 'struct Pair { value:i32 } struct Box { ptr:*const i32 } fn bad() Box { let pair:Pair=Pair{.value=42}; unsafe { return Box{.ptr=(&pair.value) as *const i32}; } } fn main() i32 { return 0; }\n' >"$tmp/v2-return-local-field-address/main.zag"
if (cd "$tmp/v2-return-local-field-address" && "$ZNC" main.zag -o out) >"$tmp/v2-return-local-field-address/log" 2>&1 || [ -e "$tmp/v2-return-local-field-address/out" ]; then
  echo "  XX  local field-address return rejects without artifact"; sed -n '1,8p' "$tmp/v2-return-local-field-address/log"; fail=$((fail + 1))
elif grep -q 'address of local `pair` escapes through return' "$tmp/v2-return-local-field-address/log"; then
  echo "  ok  local field-address return rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  local field-address return diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-return-parameter-aggregate"
printf 'name = "v2returnparameteraggregate"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-return-parameter-aggregate/zag.mod"
printf 'struct Box { ptr:*const i32 } fn wrap(p:*const i32) Box { return Box{.ptr=p}; } fn main() i32 { return 0; }\n' >"$tmp/v2-return-parameter-aggregate/main.zag"
if (cd "$tmp/v2-return-parameter-aggregate" && "$ZNC" check main.zag) >"$tmp/v2-return-parameter-aggregate/log" 2>&1; then
  echo "  ok  caller-provided pointer may cross an aggregate return"; pass=$((pass + 1))
else
  echo "  XX  caller-provided aggregate pointer return"; sed -n '1,8p' "$tmp/v2-return-parameter-aggregate/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v1-return-local-address-aggregate"
printf 'name = "v1returnlocaladdressaggregate"\nversion = "0"\nedition = "2026"\n' >"$tmp/v1-return-local-address-aggregate/zag.mod"
printf 'struct Box { ptr:*i32 } fn legacy() Box { let x:i32=42; return Box{.ptr=&x}; } fn main() i32 { return 0; }\n' >"$tmp/v1-return-local-address-aggregate/main.zag"
if (cd "$tmp/v1-return-local-address-aggregate" && "$ZNC" check main.zag) >"$tmp/v1-return-local-address-aggregate/log" 2>&1; then
  echo "  ok  edition-2026 aggregate semantics remain unchanged"; pass=$((pass + 1))
else
  echo "  XX  edition-2026 aggregate compatibility"; sed -n '1,8p' "$tmp/v1-return-local-address-aggregate/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v1-pointer"
printf 'name = "v1pointer"\nversion = "0"\nedition = "2026"\n' >"$tmp/v1-pointer/zag.mod"
printf 'fn main() i32 { let p: *mut i32; return 0; }\n' >"$tmp/v1-pointer/main.zag"
if (cd "$tmp/v1-pointer" && "$ZNC" main.zag -o out) >"$tmp/v1-pointer/log" 2>&1 || [ -e "$tmp/v1-pointer/out" ]; then
  echo "  XX  v1 rejects v2 pointer qualifier"; sed -n '1,8p' "$tmp/v1-pointer/log"; fail=$((fail + 1))
elif grep -q E0200 "$tmp/v1-pointer/log"; then
  echo "  ok  v1 rejects v2 pointer qualifier"; pass=$((pass + 1))
else
  echo "  XX  v1 rejects v2 pointer qualifier (missing diagnostic)"; fail=$((fail + 1))
fi
# `check` must use the same edition boundary as a build; otherwise it could
# silently parse a v2 token as an ordinary identifier without producing output.
mkdir -p "$tmp/v1-check"
printf 'name = "v1check"\nversion = "0"\nedition = "2026"\n' >"$tmp/v1-check/zag.mod"
printf 'fn main() i32 { unsafe { return 42; } }\n' >"$tmp/v1-check/main.zag"
if (cd "$tmp/v1-check" && "$ZNC" check main.zag) >"$tmp/v1-check/log" 2>&1; then
  echo "  XX  v1 check rejects v2 unsafe syntax"; sed -n '1,8p' "$tmp/v1-check/log"; fail=$((fail + 1))
elif grep -q E0200 "$tmp/v1-check/log"; then
  echo "  ok  v1 check rejects v2 unsafe syntax"; pass=$((pass + 1))
else
  echo "  XX  v1 check rejects v2 unsafe syntax (missing diagnostic)"; fail=$((fail + 1))
fi
# A source may live under a project directory.  The nearest ancestor manifest
# controls its edition; only consulting the source directory would silently
# turn a v2 project back into v1.
mkdir -p "$tmp/nested/src"
printf 'name = "nested"\nversion = "0"\nedition = "2027"\n' >"$tmp/nested/zag.mod"
printf 'fn main() i32 { unsafe { print_i64(42); } return 0; }\n' >"$tmp/nested/src/main.zag"
if (cd "$tmp/nested" && "$ZNC" src/main.zag -o out) >"$tmp/nested/log" 2>&1 &&
   [ -x "$tmp/nested/out" ] && [ "$("$tmp/nested/out")" = 42 ]; then
  echo "  ok  nested source inherits project edition"; pass=$((pass + 1))
else
  echo "  XX  nested source inherits project edition"; sed -n '1,8p' "$tmp/nested/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v1-asm"
printf 'name = "v1asm"\nversion = "0"\nedition = "2026"\n' >"$tmp/v1-asm/zag.mod"
printf 'fn main() i32 { asm { } return 0; }\n' >"$tmp/v1-asm/main.zag"
if (cd "$tmp/v1-asm" && "$ZNC" main.zag -o out) >"$tmp/v1-asm/log" 2>&1 || [ -e "$tmp/v1-asm/out" ]; then
  echo "  XX  v1 rejects v2 inline assembly"; sed -n '1,8p' "$tmp/v1-asm/log"; fail=$((fail + 1))
elif grep -q E0200 "$tmp/v1-asm/log"; then
  echo "  ok  v1 rejects v2 inline assembly"; pass=$((pass + 1))
else
  echo "  XX  v1 rejects v2 inline assembly (missing diagnostic)"; fail=$((fail + 1))
fi
# v1 comments and strings are not syntax and must not accidentally trigger the
# raw source scanner used by the early edition gate.
mkdir -p "$tmp/v1-text"
printf 'name = "v1text"\nversion = "0"\nedition = "2026"\n' >"$tmp/v1-text/zag.mod"
printf 'fn main() i32 { print_str("unsafe *mut"); // volatile atomic asm *device\n return 42; }\n' >"$tmp/v1-text/main.zag"
if (cd "$tmp/v1-text" && "$ZNC" main.zag -o out) >"$tmp/v1-text/log" 2>&1 && [ -x "$tmp/v1-text/out" ] && [ "$("$tmp/v1-text/out")" = 'unsafe *mut' ]; then
  echo "  ok  v1 text mentioning v2 words still compiles"; pass=$((pass + 1))
else
  echo "  XX  v1 text mentioning v2 words still compiles"; sed -n '1,8p' "$tmp/v1-text/log"; fail=$((fail + 1))
fi
echo "════ v2-edition pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
