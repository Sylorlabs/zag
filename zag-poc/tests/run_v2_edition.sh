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
