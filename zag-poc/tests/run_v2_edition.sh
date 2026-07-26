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
mkdir -p "$tmp/v2-error-aggregate"
printf 'name = "v2erroraggregate"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-error-aggregate/zag.mod"
printf 'error { Bad } struct Triple { a:i32, b:i32, c:i32 } fn make(flag:i32) !Triple { if (flag == 0) { return error.Bad; } return Triple{.a=7,.b=11,.c=24}; } fn work(flag:i32) !i32 { let value:Triple=try make(flag); return value.a+value.b+value.c; } fn main() i32 { return work(1) catch 1; }\n' >"$tmp/v2-error-aggregate/main.zag"
if (cd "$tmp/v2-error-aggregate" && "$ZNC" main.zag -o out) >"$tmp/v2-error-aggregate/log" 2>&1 && [ -x "$tmp/v2-error-aggregate/out" ]; then
  set +e
  "$tmp/v2-error-aggregate/out"
  error_aggregate_rc=$?
  set -e
  if [ "$error_aggregate_rc" -eq 42 ]; then
    echo "  ok  aggregate error-union payload survives try propagation"; pass=$((pass + 1))
  else
    echo "  XX  aggregate error-union payload execution (exit=$error_aggregate_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  aggregate error-union payload compiles"; sed -n '1,12p' "$tmp/v2-error-aggregate/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-unchecked"
printf 'name = "v2systemallocatorunchecked"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-unchecked/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-unchecked/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); try allocator.deallocate(block); return 0; } fn main() i32 { return work() catch 1; }\n' >"$tmp/v2-system-allocator-unchecked/main.zag"
if (cd "$tmp/v2-system-allocator-unchecked" && "$ZNC" main.zag -o out) >"$tmp/v2-system-allocator-unchecked/log" 2>&1 ||
   [ -e "$tmp/v2-system-allocator-unchecked/out" ]; then
  echo "  XX  SystemAllocator unchecked boundary rejects"; sed -n '1,16p' "$tmp/v2-system-allocator-unchecked/log"; fail=$((fail + 1))
elif grep -q 'SystemAllocator requires --safety=checked' "$tmp/v2-system-allocator-unchecked/log"; then
  echo "  ok  SystemAllocator unchecked boundary rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  SystemAllocator unchecked rejection missing diagnostic"; sed -n '1,16p' "$tmp/v2-system-allocator-unchecked/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-internal-free-unchecked"
printf 'name = "v2systemallocatorinternalfreeunchecked"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-internal-free-unchecked/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-internal-free-unchecked/std"
printf '@import("std/allocator.zag") fn main() i32 { unsafe { _zag_allocation_free(null as *u8); } return 0; }\n' >"$tmp/v2-system-allocator-internal-free-unchecked/main.zag"
if (cd "$tmp/v2-system-allocator-internal-free-unchecked" && "$ZNC" main.zag -o out) >"$tmp/v2-system-allocator-internal-free-unchecked/log" 2>&1 ||
   [ -e "$tmp/v2-system-allocator-internal-free-unchecked/out" ]; then
  echo "  XX  unchecked internal allocator free rejects"; sed -n '1,16p' "$tmp/v2-system-allocator-internal-free-unchecked/log"; fail=$((fail + 1))
elif grep -q 'SystemAllocator requires --safety=checked' "$tmp/v2-system-allocator-internal-free-unchecked/log"; then
  echo "  ok  unchecked internal allocator free rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  unchecked internal allocator-free rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator"
printf 'name = "v2systemallocator"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); unsafe { block.ptr[0]=42; let result:i32=block.ptr[0] as i32; try allocator.deallocate(block); return result; } } fn main() i32 { return work() catch 1; }\n' >"$tmp/v2-system-allocator/main.zag"
if (cd "$tmp/v2-system-allocator" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator/log" 2>&1 && [ -x "$tmp/v2-system-allocator/out" ]; then
  set +e
  "$tmp/v2-system-allocator/out"
  system_allocator_rc=$?
  set -e
  if [ "$system_allocator_rc" -eq 42 ]; then
    echo "  ok  SystemAllocator returns and consumes exact Allocation handle"; pass=$((pass + 1))
  else
    echo "  XX  SystemAllocator handle execution (exit=$system_allocator_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  SystemAllocator handle compiles"; sed -n '1,16p' "$tmp/v2-system-allocator/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-telemetry"
printf 'name = "v2systemallocatortelemetry"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-telemetry/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-telemetry/std"
printf '@import("std/allocator.zag") extern fn _zag_allocator_allocation_count() i64 extern fn _zag_allocator_live_bytes() i64 extern fn _zag_allocator_peak_live_bytes() i64 fn work() !i32 { let base_count:i64=_zag_allocator_allocation_count(); let base_live:i64=_zag_allocator_live_bytes(); let base_peak:i64=_zag_allocator_peak_live_bytes(); let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); if (_zag_allocator_allocation_count()!=base_count+1 || _zag_allocator_live_bytes()!=base_live+32 || _zag_allocator_peak_live_bytes()<base_live+32 || _zag_allocator_peak_live_bytes()<base_peak) { return 7; } try allocator.deallocate(block); if (_zag_allocator_allocation_count()!=base_count+1 || _zag_allocator_live_bytes()!=base_live || _zag_allocator_peak_live_bytes()<base_peak) { return 8; } return 42; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-telemetry/main.zag"
if (cd "$tmp/v2-system-allocator-telemetry" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-telemetry/log" 2>&1 && [ -x "$tmp/v2-system-allocator-telemetry/out" ]; then
  set +e
  "$tmp/v2-system-allocator-telemetry/out"
  system_allocator_telemetry_rc=$?
  set -e
  if [ "$system_allocator_telemetry_rc" -eq 42 ]; then
    echo "  ok  SystemAllocator telemetry counts allocation and retires exact capacity"; pass=$((pass + 1))
  else
    echo "  XX  SystemAllocator allocation telemetry execution (exit=$system_allocator_telemetry_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-telemetry/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  SystemAllocator allocation telemetry compiles"; sed -n '1,16p' "$tmp/v2-system-allocator-telemetry/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-forged"
printf 'name = "v2systemallocatorforged"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-forged/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-forged/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); let forged:Allocation=Allocation{.ptr=block.ptr,.len=block.len-8,.alignment=block.alignment,.generation=block.generation}; try allocator.deallocate(forged); return 0; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-forged/main.zag"
if (cd "$tmp/v2-system-allocator-forged" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-forged/log" 2>&1 && [ -x "$tmp/v2-system-allocator-forged/out" ]; then
  set +e
  "$tmp/v2-system-allocator-forged/out" >"$tmp/v2-system-allocator-forged/out.log" 2>"$tmp/v2-system-allocator-forged/err.log"
  forged_allocator_rc=$?
  set -e
  if [ "$forged_allocator_rc" -ne 0 ] && grep -q 'Allocation length does not match live allocation' "$tmp/v2-system-allocator-forged/err.log"; then
    echo "  ok  SystemAllocator rejects forged Allocation length at runtime"; pass=$((pass + 1))
  else
    echo "  XX  forged SystemAllocator handle (exit=$forged_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-forged/log"; sed -n '1,8p' "$tmp/v2-system-allocator-forged/err.log"; fail=$((fail + 1))
  fi
else
  echo "  XX  forged SystemAllocator handle did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-forged/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-forged-alignment"
printf 'name = "v2systemallocatorforgedalignment"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-forged-alignment/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-forged-alignment/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); let forged:Allocation=Allocation{.ptr=block.ptr,.len=block.len,.alignment=4,.generation=block.generation}; try allocator.deallocate(forged); return 0; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-forged-alignment/main.zag"
if (cd "$tmp/v2-system-allocator-forged-alignment" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-forged-alignment/log" 2>&1 && [ -x "$tmp/v2-system-allocator-forged-alignment/out" ]; then
  set +e
  "$tmp/v2-system-allocator-forged-alignment/out" >"$tmp/v2-system-allocator-forged-alignment/out.log" 2>"$tmp/v2-system-allocator-forged-alignment/err.log"
  forged_alignment_allocator_rc=$?
  set -e
  if [ "$forged_alignment_allocator_rc" -ne 0 ] && grep -q 'Allocation alignment does not match SystemAllocator' "$tmp/v2-system-allocator-forged-alignment/err.log"; then
    echo "  ok  SystemAllocator rejects forged Allocation alignment at runtime"; pass=$((pass + 1))
  else
    echo "  XX  forged SystemAllocator alignment (exit=$forged_alignment_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-forged-alignment/log"; sed -n '1,8p' "$tmp/v2-system-allocator-forged-alignment/err.log"; fail=$((fail + 1))
  fi
else
  echo "  XX  forged SystemAllocator alignment did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-forged-alignment/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-forged-generation"
printf 'name = "v2systemallocatorforgedgeneration"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-forged-generation/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-forged-generation/std"
# Splice a live second descriptor with the first allocation's generation. This
# must not be accepted merely because every individual field came from a valid
# current handle: identity is the exact live tuple, including generation.
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let first:Allocation=try allocator.allocate(24,8); let second:Allocation=try allocator.allocate(64,8); let forged:Allocation=Allocation{.ptr=second.ptr,.len=second.len,.alignment=second.alignment,.generation=first.generation}; try allocator.deallocate(forged); return 0; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-forged-generation/main.zag"
if (cd "$tmp/v2-system-allocator-forged-generation" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-forged-generation/log" 2>&1 && [ -x "$tmp/v2-system-allocator-forged-generation/out" ]; then
  set +e
  "$tmp/v2-system-allocator-forged-generation/out" >"$tmp/v2-system-allocator-forged-generation/out.log" 2>"$tmp/v2-system-allocator-forged-generation/err.log"
  forged_generation_allocator_rc=$?
  set -e
  if [ "$forged_generation_allocator_rc" -ne 0 ] && grep -q 'stale Allocation generation' "$tmp/v2-system-allocator-forged-generation/err.log"; then
    echo "  ok  SystemAllocator rejects live cross-handle generation splice"; pass=$((pass + 1))
  else
    echo "  XX  forged SystemAllocator generation splice (exit=$forged_generation_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-forged-generation/log"; sed -n '1,8p' "$tmp/v2-system-allocator-forged-generation/err.log"; fail=$((fail + 1))
  fi
else
  echo "  XX  forged SystemAllocator generation splice did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-forged-generation/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-stale"
printf 'name = "v2systemallocatorstale"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-stale/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-stale/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let first:Allocation=try allocator.allocate(24,8); let stale:Allocation=first; try allocator.deallocate(first); try allocator.deallocate(stale); return 0; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-stale/main.zag"
if (cd "$tmp/v2-system-allocator-stale" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-stale/log" 2>&1 && [ -x "$tmp/v2-system-allocator-stale/out" ]; then
  set +e
  "$tmp/v2-system-allocator-stale/out" >"$tmp/v2-system-allocator-stale/out.log" 2>"$tmp/v2-system-allocator-stale/err.log"
  stale_allocator_rc=$?
  set -e
  if [ "$stale_allocator_rc" -ne 0 ] && grep -q 'invalid or released Allocation handle' "$tmp/v2-system-allocator-stale/err.log"; then
    echo "  ok  SystemAllocator rejects copied released handle at runtime"; pass=$((pass + 1))
  else
    echo "  XX  stale SystemAllocator handle (exit=$stale_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-stale/log"; sed -n '1,8p' "$tmp/v2-system-allocator-stale/err.log"; fail=$((fail + 1))
  fi
else
  echo "  XX  stale SystemAllocator handle did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-stale/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-aba"
printf 'name = "v2systemallocatoraba"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-aba/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-aba/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let first:Allocation=try allocator.allocate(24,8); let stale:Allocation=first; try allocator.deallocate(first); let replacement:Allocation=try allocator.allocate(24,8); if (stale.ptr != replacement.ptr) { return 7; } try allocator.deallocate(stale); return 0; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-aba/main.zag"
if (cd "$tmp/v2-system-allocator-aba" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-aba/log" 2>&1 && [ -x "$tmp/v2-system-allocator-aba/out" ]; then
  set +e
  "$tmp/v2-system-allocator-aba/out" >"$tmp/v2-system-allocator-aba/out.log" 2>"$tmp/v2-system-allocator-aba/err.log"
  aba_allocator_rc=$?
  set -e
  if [ "$aba_allocator_rc" -ne 0 ] && grep -q 'stale Allocation generation' "$tmp/v2-system-allocator-aba/err.log"; then
    echo "  ok  SystemAllocator generation rejects ABA address reuse"; pass=$((pass + 1))
  else
    echo "  XX  SystemAllocator ABA generation (exit=$aba_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-aba/log"; sed -n '1,8p' "$tmp/v2-system-allocator-aba/err.log"; fail=$((fail + 1))
  fi
else
  echo "  XX  SystemAllocator ABA program did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-aba/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-reuse"
printf 'name = "v2systemallocatorreuse"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-reuse/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-reuse/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let first:Allocation=try allocator.allocate(24,8); try allocator.deallocate(first); let replacement:Allocation=try allocator.allocate(24,8); try allocator.deallocate(replacement); return 42; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-reuse/main.zag"
if (cd "$tmp/v2-system-allocator-reuse" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-reuse/log" 2>&1 && [ -x "$tmp/v2-system-allocator-reuse/out" ]; then
  set +e
  "$tmp/v2-system-allocator-reuse/out"
  reuse_allocator_rc=$?
  set -e
  if [ "$reuse_allocator_rc" -eq 42 ]; then
    echo "  ok  SystemAllocator accepts replacement handle after address reuse"; pass=$((pass + 1))
  else
    echo "  XX  SystemAllocator replacement handle execution (exit=$reuse_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-reuse/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  SystemAllocator replacement handle did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-reuse/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-zeroed"
printf 'name = "v2systemallocatorzeroed"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-zeroed/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-zeroed/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let dirty:Allocation=try allocator.allocate(24,8); unsafe { dirty.ptr[0]=77; } try allocator.deallocate(dirty); let zeroed:Allocation=try allocator.allocate_zeroed(24,8); unsafe { let value:i32=zeroed.ptr[0] as i32; try allocator.deallocate(zeroed); return value; } } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-zeroed/main.zag"
if (cd "$tmp/v2-system-allocator-zeroed" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-zeroed/log" 2>&1 && [ -x "$tmp/v2-system-allocator-zeroed/out" ]; then
  set +e
  "$tmp/v2-system-allocator-zeroed/out"
  zeroed_allocator_rc=$?
  set -e
  if [ "$zeroed_allocator_rc" -eq 0 ]; then
    echo "  ok  SystemAllocator zeroed allocation clears reused bytes"; pass=$((pass + 1))
  else
    echo "  XX  SystemAllocator zeroed allocation execution (exit=$zeroed_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-zeroed/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  SystemAllocator zeroed allocation did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-zeroed/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-resize"
printf 'name = "v2systemallocatorresize"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-resize/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-resize/std"
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); unsafe { block.ptr[0]=42; } let grown:Allocation=try allocator.resize(block,64,8); unsafe { let value:i32=grown.ptr[0] as i32; try allocator.deallocate(grown); return value; } } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-resize/main.zag"
if (cd "$tmp/v2-system-allocator-resize" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-resize/log" 2>&1 && [ -x "$tmp/v2-system-allocator-resize/out" ]; then
  set +e
  "$tmp/v2-system-allocator-resize/out"
  resize_allocator_rc=$?
  set -e
  if [ "$resize_allocator_rc" -eq 42 ]; then
    echo "  ok  SystemAllocator resize preserves bytes and returns replacement"; pass=$((pass + 1))
  else
    echo "  XX  SystemAllocator resize execution (exit=$resize_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-resize/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  SystemAllocator resize did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-resize/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-resize-stale"
printf 'name = "v2systemallocatorresizestale"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-resize-stale/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-resize-stale/std"
# Resize allocates the replacement first, then retires the old handle. A copy
# made before the call must therefore be rejected after success, not treated as
# a second valid descriptor for the old allocation lifetime.
printf '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); let stale:Allocation=block; let grown:Allocation=try allocator.resize(block,64,8); try allocator.deallocate(stale); try allocator.deallocate(grown); return 0; } fn main() i32 { return work() catch 9; }\n' >"$tmp/v2-system-allocator-resize-stale/main.zag"
if (cd "$tmp/v2-system-allocator-resize-stale" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-resize-stale/log" 2>&1 && [ -x "$tmp/v2-system-allocator-resize-stale/out" ]; then
  set +e
  "$tmp/v2-system-allocator-resize-stale/out" >"$tmp/v2-system-allocator-resize-stale/out.log" 2>"$tmp/v2-system-allocator-resize-stale/err.log"
  resize_stale_allocator_rc=$?
  set -e
  if [ "$resize_stale_allocator_rc" -ne 0 ] && grep -q 'invalid or released Allocation handle' "$tmp/v2-system-allocator-resize-stale/err.log"; then
    echo "  ok  SystemAllocator resize retires copied old handle"; pass=$((pass + 1))
  else
    echo "  XX  stale SystemAllocator resize handle (exit=$resize_stale_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-resize-stale/log"; sed -n '1,8p' "$tmp/v2-system-allocator-resize-stale/err.log"; fail=$((fail + 1))
  fi
else
  echo "  XX  stale SystemAllocator resize handle did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-resize-stale/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-alignment"
printf 'name = "v2systemallocatoralignment"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-alignment/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-alignment/std"
printf '%s\n' '@import("std/allocator.zag") fn work() !i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,4); if ((block.ptr as i64) % 4 != 0) { return 7; } try allocator.deallocate(block); return 42; } fn main() i32 { return work() catch 9; }' >"$tmp/v2-system-allocator-alignment/main.zag"
if (cd "$tmp/v2-system-allocator-alignment" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-alignment/log" 2>&1 && [ -x "$tmp/v2-system-allocator-alignment/out" ]; then
  set +e
  "$tmp/v2-system-allocator-alignment/out"
  alignment_allocator_rc=$?
  set -e
  if [ "$alignment_allocator_rc" -eq 42 ]; then
    echo "  ok  SystemAllocator records dynamic supported alignment"; pass=$((pass + 1))
  else
    echo "  XX  SystemAllocator dynamic alignment execution (exit=$alignment_allocator_rc)"; sed -n '1,16p' "$tmp/v2-system-allocator-alignment/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  SystemAllocator dynamic alignment did not compile"; sed -n '1,16p' "$tmp/v2-system-allocator-alignment/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-fixed-buffer-allocator"
printf 'name = "v2fixedbufferallocator"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-fixed-buffer-allocator/zag.mod"
printf 'fn main() i32 { let allocator = fixed_buffer_allocator(0, 0); return 0; }\n' >"$tmp/v2-fixed-buffer-allocator/main.zag"
if (cd "$tmp/v2-fixed-buffer-allocator" && "$ZNC" main.zag -o out) >"$tmp/v2-fixed-buffer-allocator/log" 2>&1 || [ -e "$tmp/v2-fixed-buffer-allocator/out" ]; then
  echo "  XX  fixed-buffer allocator rejects before an artifact"; sed -n '1,12p' "$tmp/v2-fixed-buffer-allocator/log"; fail=$((fail + 1))
elif grep -q 'fixed-buffer and arena allocators are unsupported' "$tmp/v2-fixed-buffer-allocator/log"; then
  echo "  ok  fixed-buffer allocator has an explicit lifetime-contract rejection"; pass=$((pass + 1))
else
  echo "  XX  fixed-buffer allocator rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-callback-escape"
printf 'name = "v2systemallocatorcallbackescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-callback-escape/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-callback-escape/std"
printf '@import("std/allocator.zag") fn make() !fn() i32 { let allocator:SystemAllocator=system_allocator(); let block:Allocation=try allocator.allocate(24,8); return fn[block]() i32 { return block.len as i32; }; } fn main() i32 { return 0; }\n' >"$tmp/v2-system-allocator-callback-escape/main.zag"
if (cd "$tmp/v2-system-allocator-callback-escape" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-callback-escape/log" 2>&1 ||
   [ -e "$tmp/v2-system-allocator-callback-escape/out" ]; then
  echo "  XX  Allocation handle callback capture rejects"; sed -n '1,16p' "$tmp/v2-system-allocator-callback-escape/log"; fail=$((fail + 1))
elif grep -q 'captured aggregate closures require a destruction protocol' "$tmp/v2-system-allocator-callback-escape/log"; then
  echo "  ok  Allocation handle callback capture rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  Allocation handle callback rejection missing lifetime diagnostic"; sed -n '1,16p' "$tmp/v2-system-allocator-callback-escape/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-system-allocator-global-escape"
printf 'name = "v2systemallocatorglobalescape"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-system-allocator-global-escape/zag.mod"
ln -s "$PWD/selfhost/std" "$tmp/v2-system-allocator-global-escape/std"
printf '@import("std/allocator.zag") global let block:Allocation; fn main() i32 { return 0; }\n' >"$tmp/v2-system-allocator-global-escape/main.zag"
if (cd "$tmp/v2-system-allocator-global-escape" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-system-allocator-global-escape/log" 2>&1 ||
   [ -e "$tmp/v2-system-allocator-global-escape/out" ]; then
  echo "  XX  Allocation handle global storage rejects"; sed -n '1,16p' "$tmp/v2-system-allocator-global-escape/log"; fail=$((fail + 1))
elif grep -q 'aggregates, callbacks, and optionals have no global lifetime contract' "$tmp/v2-system-allocator-global-escape/log"; then
  echo "  ok  Allocation handle global storage rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  Allocation handle global rejection missing lifetime diagnostic"; sed -n '1,16p' "$tmp/v2-system-allocator-global-escape/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-captureless-callback"
printf 'name = "v2capturelesscallback"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-captureless-callback/zag.mod"
printf 'fn main() i32 { let f:fn() i32=fn[]() i32 { return 42; }; return f(); }\n' >"$tmp/v2-captureless-callback/main.zag"
if (cd "$tmp/v2-captureless-callback" && "$ZNC" main.zag -o out) >"$tmp/v2-captureless-callback/log" 2>&1 && [ -x "$tmp/v2-captureless-callback/out" ]; then
  set +e
  "$tmp/v2-captureless-callback/out"
  captureless_callback_rc=$?
  set -e
  if [ "$captureless_callback_rc" -eq 42 ]; then
    echo "  ok  captureless callback executes without a lifetime environment"; pass=$((pass + 1))
  else
    echo "  XX  captureless callback execution (exit=$captureless_callback_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  captureless callback compile"; sed -n '1,8p' "$tmp/v2-captureless-callback/log"; fail=$((fail + 1))
fi
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
mkdir -p "$tmp/v2-checked-heap-oob"
printf 'name = "v2checkedheapoob"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-heap-oob/zag.mod"
printf 'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; let value:i8=p[16]; _zag_free(p); return value as i32; } }\n' >"$tmp/v2-checked-heap-oob/main.zag"
if (cd "$tmp/v2-checked-heap-oob" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-heap-oob/log" 2>&1 && [ -x "$tmp/v2-checked-heap-oob/out" ]; then
  set +e
  "$tmp/v2-checked-heap-oob/out" >"$tmp/v2-checked-heap-oob/out.log" 2>"$tmp/v2-checked-heap-oob/err.log"
  checked_heap_oob_rc=$?
  set -e
  if [ "$checked_heap_oob_rc" -ne 0 ] && grep -q 'zag safety: allocator pointer access out of bounds' "$tmp/v2-checked-heap-oob/err.log"; then
    echo "  ok  checked safety traps tracked heap pointer one-past access"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety heap bounds check (exit=$checked_heap_oob_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety heap bounds program did not compile"; sed -n '1,8p' "$tmp/v2-checked-heap-oob/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-heap-live"
printf 'name = "v2checkedheaplive"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-heap-live/zag.mod"
printf 'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p[0]=42; let value:i8=p[0]; _zag_free(p); return value as i32; } }\n' >"$tmp/v2-checked-heap-live/main.zag"
if (cd "$tmp/v2-checked-heap-live" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-heap-live/log" 2>&1 &&
   [ -x "$tmp/v2-checked-heap-live/out" ]; then
  set +e
  "$tmp/v2-checked-heap-live/out"
  checked_heap_live_rc=$?
  set -e
  if [ "$checked_heap_live_rc" -eq 42 ]; then
    echo "  ok  checked safety permits in-bounds tracked heap access"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety in-bounds heap access (exit=$checked_heap_live_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety in-bounds heap program did not compile"; sed -n '1,8p' "$tmp/v2-checked-heap-live/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-heap-uaf"
printf 'name = "v2checkedheapuaf"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-heap-uaf/zag.mod"
printf 'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p.*=7; let saved:i64=(p as i64)+0; _zag_free(p); let q:*i8=saved as *i8; return q.* as i32; } }\n' >"$tmp/v2-checked-heap-uaf/main.zag"
if (cd "$tmp/v2-checked-heap-uaf" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-heap-uaf/log" 2>&1 && [ -x "$tmp/v2-checked-heap-uaf/out" ]; then
  set +e
  "$tmp/v2-checked-heap-uaf/out" >"$tmp/v2-checked-heap-uaf/out.log" 2>"$tmp/v2-checked-heap-uaf/err.log"
  checked_heap_uaf_rc=$?
  set -e
  if [ "$checked_heap_uaf_rc" -ne 0 ] && grep -q 'zag safety: use after free of allocator pointer' "$tmp/v2-checked-heap-uaf/err.log"; then
    echo "  ok  checked safety traps tracked heap use after free"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety heap lifetime check (exit=$checked_heap_uaf_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety heap UAF program did not compile"; sed -n '1,8p' "$tmp/v2-checked-heap-uaf/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-realloc-uaf"
printf 'name = "v2checkedreallocuaf"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-realloc-uaf/zag.mod"
printf 'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p.*=7; let saved:i64=(p as i64)+0; let q:*i8=_zag_realloc(p,32) as *i8; q.*=42; _zag_free(q); let stale:*i8=saved as *i8; return stale.* as i32; } }\n' >"$tmp/v2-checked-realloc-uaf/main.zag"
if (cd "$tmp/v2-checked-realloc-uaf" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-realloc-uaf/log" 2>&1 && [ -x "$tmp/v2-checked-realloc-uaf/out" ]; then
  set +e
  "$tmp/v2-checked-realloc-uaf/out" >"$tmp/v2-checked-realloc-uaf/out.log" 2>"$tmp/v2-checked-realloc-uaf/err.log"
  checked_realloc_uaf_rc=$?
  set -e
  if [ "$checked_realloc_uaf_rc" -ne 0 ] && grep -q 'zag safety: use after free of allocator pointer' "$tmp/v2-checked-realloc-uaf/err.log"; then
    echo "  ok  checked safety traps stale pointer after realloc"; pass=$((pass + 1))
  else
    echo "  XX  checked safety realloc lifetime check (exit=$checked_realloc_uaf_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety realloc UAF program did not compile"; sed -n '1,8p' "$tmp/v2-checked-realloc-uaf/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-interior-free"
printf 'name = "v2checkedinteriorfree"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-interior-free/zag.mod"
printf 'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p.*=16; let forged:i64=(p as i64)+8; _zag_free(forged as *i8); _zag_free(p); return 0; } }\n' >"$tmp/v2-checked-interior-free/main.zag"
if (cd "$tmp/v2-checked-interior-free" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-interior-free/log" 2>&1 && [ -x "$tmp/v2-checked-interior-free/out" ]; then
  set +e
  "$tmp/v2-checked-interior-free/out" >"$tmp/v2-checked-interior-free/out.log" 2>"$tmp/v2-checked-interior-free/err.log"
  checked_interior_free_rc=$?
  set -e
  if [ "$checked_interior_free_rc" -ne 0 ] && grep -q 'zag safety: invalid or freed allocator pointer' "$tmp/v2-checked-interior-free/err.log"; then
    echo "  ok  checked safety rejects forged interior free before header access"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety forged interior free (exit=$checked_interior_free_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety interior-free program did not compile"; sed -n '1,8p' "$tmp/v2-checked-interior-free/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-checked-stack"
printf 'name = "v2checkedstack"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-checked-stack/zag.mod"
printf 'fn main() i32 { unsafe { let x:i32=42; let p:*const i32=(&x) as *const i32; return p.*; } }\n' >"$tmp/v2-checked-stack/main.zag"
if (cd "$tmp/v2-checked-stack" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-checked-stack/log" 2>&1 &&
   [ -x "$tmp/v2-checked-stack/out" ]; then
  set +e
  "$tmp/v2-checked-stack/out"
  checked_stack_rc=$?
  set -e
  if [ "$checked_stack_rc" -eq 42 ]; then
    echo "  ok  checked safety preserves untracked stack raw-pointer access"
    pass=$((pass + 1))
  else
    echo "  XX  checked safety stack pointer access (exit=$checked_stack_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked safety stack pointer access"; sed -n '1,8p' "$tmp/v2-checked-stack/log"; fail=$((fail + 1))
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
elif grep -q 'capturing pointer closure requires an explicit v2 lifetime contract' "$tmp/v2-callback-lifetime/log"; then
  echo "  ok  callback pointer capture lifetime rejects without artifact"
  pass=$((pass + 1))
else
  echo "  XX  callback capture lifetime diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-callback-owned"
printf 'name = "v2callbackowned"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-callback-owned/zag.mod"
printf 'fn maker() fn() i32 { let x:i32=42; return fn[x]() i32 { return x; }; } fn main() i32 { let f:fn() i32=maker(); let result:i32=f(); close(f); return result; }\n' >"$tmp/v2-callback-owned/main.zag"
if (cd "$tmp/v2-callback-owned" && "$ZNC" main.zag -o out) >"$tmp/v2-callback-owned/log" 2>&1 && [ -x "$tmp/v2-callback-owned/out" ]; then
  set +e
  "$tmp/v2-callback-owned/out"
  callback_owned_rc=$?
  set -e
  if [ "$callback_owned_rc" -eq 42 ]; then
    echo "  ok  scalar callback capture survives return and close"; pass=$((pass + 1))
  else
    echo "  XX  scalar callback ownership execution (exit=$callback_owned_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  scalar callback ownership compile"; sed -n '1,8p' "$tmp/v2-callback-owned/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-callback-leak"
printf 'name = "v2callbackleak"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-callback-leak/zag.mod"
printf 'fn main() i32 { let x:i32=42; let f:fn() i32=fn[x]() i32 { return x; }; return 0; }\n' >"$tmp/v2-callback-leak/main.zag"
if (cd "$tmp/v2-callback-leak" && "$ZNC" main.zag -o out) >"$tmp/v2-callback-leak/log" 2>&1 || [ -e "$tmp/v2-callback-leak/out" ]; then
  echo "  XX  callback environment leak rejects without artifact"; sed -n '1,8p' "$tmp/v2-callback-leak/log"; fail=$((fail + 1))
elif grep -q 'owned allocation `f` is neither released nor returned' "$tmp/v2-callback-leak/log"; then
  echo "  ok  callback environment leak rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  callback environment leak diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-callback-aggregate"
printf 'name = "v2callbackaggregate"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-callback-aggregate/zag.mod"
printf 'struct Pair { value:i32 } fn main() i32 { let pair:Pair=Pair{.value=42}; let f:fn() i32=fn[pair]() i32 { return pair.value; }; close(f); return 0; }\n' >"$tmp/v2-callback-aggregate/main.zag"
if (cd "$tmp/v2-callback-aggregate" && "$ZNC" main.zag -o out) >"$tmp/v2-callback-aggregate/log" 2>&1 || [ -e "$tmp/v2-callback-aggregate/out" ]; then
  echo "  XX  callback aggregate capture rejects without artifact"; sed -n '1,8p' "$tmp/v2-callback-aggregate/log"; fail=$((fail + 1))
elif grep -q 'captured aggregate closures require a destruction protocol' "$tmp/v2-callback-aggregate/log"; then
  echo "  ok  callback aggregate capture rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  callback aggregate capture diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-callback-after-close"
printf 'name = "v2callbackafterclose"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-callback-after-close/zag.mod"
printf 'fn main() i32 { let x:i32=42; let f:fn() i32=fn[x]() i32 { return x; }; close(f); return f(); }\n' >"$tmp/v2-callback-after-close/main.zag"
if (cd "$tmp/v2-callback-after-close" && "$ZNC" main.zag -o out) >"$tmp/v2-callback-after-close/log" 2>&1 || [ -e "$tmp/v2-callback-after-close/out" ]; then
  echo "  XX  callback use after close rejects without artifact"; sed -n '1,8p' "$tmp/v2-callback-after-close/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `f`' "$tmp/v2-callback-after-close/log"; then
  echo "  ok  callback use after close rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  callback use-after-close diagnostic missing"; fail=$((fail + 1))
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
elif grep -Eq 'unsafe function values are not implemented|unsafe or C-ABI function values are not implemented' "$tmp/v2-unsafe-value/log"; then
  echo "  ok  unsafe function value rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  unsafe function value rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-realtime-callback"
printf 'name = "v2realtimecallback"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-realtime-callback/zag.mod"
printf 'fn clean() i32 { return 42; } fn run(op:fn() i32 @realtime) i32 @realtime { return op(); } fn main() i32 { return run(clean); }\n' >"$tmp/v2-realtime-callback/main.zag"
if (cd "$tmp/v2-realtime-callback" && "$ZNC" main.zag -o out) >"$tmp/v2-realtime-callback/log" 2>&1 && [ -x "$tmp/v2-realtime-callback/out" ]; then
  set +e
  "$tmp/v2-realtime-callback/out"
  realtime_callback_rc=$?
  set -e
  if [ "$realtime_callback_rc" -eq 42 ]; then
    echo "  ok  realtime callback default uses complete effect universe"; pass=$((pass + 1))
  else
    echo "  XX  realtime callback execution (exit=$realtime_callback_rc)"; sed -n '1,12p' "$tmp/v2-realtime-callback/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  realtime callback contract compiles"; sed -n '1,12p' "$tmp/v2-realtime-callback/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-pure-callback-unsafe"
printf 'name = "v2purecallbackunsafe"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-pure-callback-unsafe/zag.mod"
printf 'fn dirty() i32 { unsafe { return 1; } } fn main() i32 { let op:fn() i32 !pure=dirty; return op(); }\n' >"$tmp/v2-pure-callback-unsafe/main.zag"
if (cd "$tmp/v2-pure-callback-unsafe" && "$ZNC" main.zag -o out) >"$tmp/v2-pure-callback-unsafe/log" 2>&1 || [ -e "$tmp/v2-pure-callback-unsafe/out" ]; then
  echo "  XX  pure callback contract rejects Unsafe value"; sed -n '1,12p' "$tmp/v2-pure-callback-unsafe/log"; fail=$((fail + 1))
elif grep -q 'effect contract' "$tmp/v2-pure-callback-unsafe/log"; then
  echo "  ok  pure callback contract rejects Unsafe value"; pass=$((pass + 1))
else
  echo "  XX  pure callback Unsafe diagnostic missing"; sed -n '1,12p' "$tmp/v2-pure-callback-unsafe/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-pure-callback-reassignment"
printf 'name = "v2purecallbackreassignment"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-pure-callback-reassignment/zag.mod"
printf 'fn clean() i32 { return 1; } fn bad() i32 @pure { let op:fn() i32=clean; op=fn[]() i32 { unsafe { return 7; } }; return op(); } fn main() i32 { return 0; }\n' >"$tmp/v2-pure-callback-reassignment/main.zag"
if (cd "$tmp/v2-pure-callback-reassignment" && "$ZNC" main.zag -o out) >"$tmp/v2-pure-callback-reassignment/log" 2>&1 || [ -e "$tmp/v2-pure-callback-reassignment/out" ]; then
  echo "  XX  pure callback reassignment rejects Unsafe effect"; sed -n '1,12p' "$tmp/v2-pure-callback-reassignment/log"; fail=$((fail + 1))
elif grep -Eq '@pure[^[:space:]]* constraint broken' "$tmp/v2-pure-callback-reassignment/log"; then
  echo "  ok  pure callback reassignment propagates Unsafe effect"; pass=$((pass + 1))
else
  echo "  XX  pure callback reassignment missing Unsafe diagnostic"; sed -n '1,12p' "$tmp/v2-pure-callback-reassignment/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-pure-callback-contract-reassignment"
printf 'name = "v2purecallbackcontractreassignment"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-pure-callback-contract-reassignment/zag.mod"
printf 'fn clean() i32 { return 1; } fn bad() i32 { let op:fn() i32 !pure=clean; op=fn[]() i32 { unsafe { return 7; } }; return 0; } fn main() i32 { return bad(); }\n' >"$tmp/v2-pure-callback-contract-reassignment/main.zag"
if (cd "$tmp/v2-pure-callback-contract-reassignment" && "$ZNC" main.zag -o out) >"$tmp/v2-pure-callback-contract-reassignment/log" 2>&1 || [ -e "$tmp/v2-pure-callback-contract-reassignment/out" ]; then
  echo "  XX  pure callback reassignment preserves local contract"; sed -n '1,12p' "$tmp/v2-pure-callback-contract-reassignment/log"; fail=$((fail + 1))
elif grep -q 'assigning typed local.*effect contract' "$tmp/v2-pure-callback-contract-reassignment/log"; then
  echo "  ok  pure callback reassignment preserves local contract"; pass=$((pass + 1))
else
  echo "  XX  pure callback reassignment contract diagnostic missing"; sed -n '1,12p' "$tmp/v2-pure-callback-contract-reassignment/log"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-cabi-pure"
printf 'name = "v2cabipure"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cabi-pure/zag.mod"
printf 'extern fn foreign() i64 @cabi; fn bad() i64 @pure { unsafe { return foreign(); } } fn main() i32 { return 0; }\n' >"$tmp/v2-cabi-pure/main.zag"
if (cd "$tmp/v2-cabi-pure" && "$ZNC" check main.zag) >"$tmp/v2-cabi-pure/log" 2>&1; then
  echo "  XX  C-ABI Unsafe effect reaches pure constraint"; sed -n '1,12p' "$tmp/v2-cabi-pure/log"; fail=$((fail + 1))
elif grep -q E0002 "$tmp/v2-cabi-pure/log"; then
  echo "  ok  C-ABI Unsafe effect reaches pure constraint"; pass=$((pass + 1))
else
  echo "  XX  C-ABI pure-effect diagnostic missing"; sed -n '1,12p' "$tmp/v2-cabi-pure/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-cabi-value"
printf 'name = "v2cabivalue"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-cabi-value/zag.mod"
printf 'extern fn foreign() i64 @cabi; fn main() i32 { unsafe { let f:fn() i64=foreign; return 0; } }\n' >"$tmp/v2-cabi-value/main.zag"
if (cd "$tmp/v2-cabi-value" && "$ZNC" check main.zag) >"$tmp/v2-cabi-value/log" 2>&1; then
  echo "  XX  C-ABI function value rejects without typed contract"; sed -n '1,12p' "$tmp/v2-cabi-value/log"; fail=$((fail + 1))
elif grep -q 'unsafe or C-ABI function values are not implemented' "$tmp/v2-cabi-value/log"; then
  echo "  ok  C-ABI function value rejects without typed contract"; pass=$((pass + 1))
else
  echo "  XX  C-ABI function-value diagnostic missing"; sed -n '1,12p' "$tmp/v2-cabi-value/log"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-global"
printf 'name = "v2global"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-global/zag.mod"
printf 'let global_pointer:*i32 = null as *i32; fn main() i32 { return 0; }\n' >"$tmp/v2-global/main.zag"
if (cd "$tmp/v2-global" && "$ZNC" main.zag -o out) >"$tmp/v2-global/log" 2>&1 || [ -e "$tmp/v2-global/out" ]; then
  echo "  XX  v2 mutable global fails closed"; sed -n '1,8p' "$tmp/v2-global/log"; fail=$((fail + 1))
elif grep -q E0204 "$tmp/v2-global/log" && grep -q 'global lifetime contract' "$tmp/v2-global/log"; then
  echo "  ok  v2 mutable global requires an explicit lifetime contract without artifact"; pass=$((pass + 1))
else
  echo "  XX  v2 global lifetime rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-explicit-global"
printf 'name = "v2explicitglobal"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-explicit-global/zag.mod"
printf 'global let counter:i32; fn bump() void { counter = counter + 42; } fn main() i32 { bump(); return counter; }\n' >"$tmp/v2-explicit-global/main.zag"
if (cd "$tmp/v2-explicit-global" && "$ZNC" main.zag -o out) >"$tmp/v2-explicit-global/log" 2>&1 && [ -x "$tmp/v2-explicit-global/out" ]; then
  set +e
  "$tmp/v2-explicit-global/out"
  explicit_global_rc=$?
  set -e
  if [ "$explicit_global_rc" -eq 42 ]; then
    echo "  ok  explicit zero-initialized scalar global reads and writes"; pass=$((pass + 1))
  else
    echo "  XX  explicit scalar global execution (exit=$explicit_global_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  explicit scalar global compiles"; sed -n '1,10p' "$tmp/v2-explicit-global/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-sanitize-memory"
printf 'name = "v2sanitizememory"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-sanitize-memory/zag.mod"
printf 'extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; fn main() i32 { let p:*u8 = _zag_malloc(16); _zag_free(p); return 37; }\n' >"$tmp/v2-sanitize-memory/main.zag"
if (cd "$tmp/v2-sanitize-memory" && "$ZNC" main.zag -o out --sanitize=memory) >"$tmp/v2-sanitize-memory/log" 2>&1 && [ -x "$tmp/v2-sanitize-memory/out" ]; then
  set +e
  "$tmp/v2-sanitize-memory/out"
  sanitize_memory_rc=$?
  set -e
  if [ "$sanitize_memory_rc" -eq 37 ]; then
    echo "  ok  memory sanitizer preserves released-allocation exit status"; pass=$((pass + 1))
  else
    echo "  XX  memory sanitizer released-allocation execution (exit=$sanitize_memory_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  memory sanitizer compiles released-allocation witness"; sed -n '1,10p' "$tmp/v2-sanitize-memory/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-raw-slice-release"
printf 'name = "v2rawslicerelease"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-raw-slice-release/zag.mod"
printf 'fn main() i32 { let xs:[]i32 = zalloc_i(1); xs[0] = 7; zfree_i(xs); return 0; }\n' >"$tmp/v2-raw-slice-release/main.zag"
if (cd "$tmp/v2-raw-slice-release" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-raw-slice-release/log" 2>&1 && [ -x "$tmp/v2-raw-slice-release/out" ]; then
  echo "  ok  checked raw-slice release discharges ownership"; pass=$((pass + 1))
else
  echo "  XX  checked raw-slice release discharges ownership"; sed -n '1,10p' "$tmp/v2-raw-slice-release/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-raw-slice-stale"
printf 'name = "v2rawslicestale"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-raw-slice-stale/zag.mod"
printf 'fn main() i32 { let xs:[]i32 = zalloc_i(1); xs[0] = 7; zfree_i(xs); return xs[0]; }\n' >"$tmp/v2-raw-slice-stale/main.zag"
if (cd "$tmp/v2-raw-slice-stale" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-raw-slice-stale/log" 2>&1 ||
   [ -e "$tmp/v2-raw-slice-stale/out" ]; then
  echo "  XX  released raw slice rejects use"; sed -n '1,10p' "$tmp/v2-raw-slice-stale/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `xs`' "$tmp/v2-raw-slice-stale/log"; then
  echo "  ok  released raw slice rejects use without artifact"; pass=$((pass + 1))
else
  echo "  XX  released raw slice rejection missing lifetime diagnostic"; sed -n '1,10p' "$tmp/v2-raw-slice-stale/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-global-format"
printf 'name = "v2globalformat"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-global-format/zag.mod"
printf 'global let counter:i32; fn main() i32 { counter=7; return counter; }\n' >"$tmp/v2-global-format/main.zag"
if (cd "$tmp/v2-global-format" && "$ZNC" fmt --in-place main.zag) >"$tmp/v2-global-format/log" 2>&1 &&
   grep -q '^global let counter: i32;' "$tmp/v2-global-format/main.zag"; then
  echo "  ok  formatter preserves explicit global storage"; pass=$((pass + 1))
else
  echo "  XX  formatter preserves explicit global storage"; sed -n '1,12p' "$tmp/v2-global-format/main.zag"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-global-pointer"
printf 'name = "v2globalpointer"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-global-pointer/zag.mod"
printf 'extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; global let p:*u8; fn main() i32 { unsafe { p = _zag_malloc(8); p.* = 42; let out:i32 = p.*; _zag_free(p); return out; } }\n' >"$tmp/v2-global-pointer/main.zag"
if (cd "$tmp/v2-global-pointer" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-global-pointer/log" 2>&1 && [ -x "$tmp/v2-global-pointer/out" ]; then
  set +e
  "$tmp/v2-global-pointer/out"
  global_pointer_rc=$?
  set -e
  if [ "$global_pointer_rc" -eq 42 ]; then
    echo "  ok  pointer global owns checked allocation through release"; pass=$((pass + 1))
  else
    echo "  XX  pointer global execution (exit=$global_pointer_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  pointer global checked ownership compiles"; sed -n '1,10p' "$tmp/v2-global-pointer/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-global-pointer-stale"
printf 'name = "v2globalpointerstale"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-global-pointer-stale/zag.mod"
# Preserve the address as an integer before the explicit release, then attempt
# to reload it through global storage.  This must be rejected by the typed
# lifetime proof before it can become a runtime escape hatch.
printf 'extern fn _zag_malloc(n:i64)*u8; extern fn _zag_free(p:*u8)void; global let p:*u8; global let saved:i64; fn main() i32 { unsafe { p = _zag_malloc(8); p.* = 42; saved = p as i64; _zag_free(p); p = saved as *u8; return p.* as i32; } }\n' >"$tmp/v2-global-pointer-stale/main.zag"
if (cd "$tmp/v2-global-pointer-stale" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-global-pointer-stale/log" 2>&1 ||
   [ -e "$tmp/v2-global-pointer-stale/out" ]; then
  echo "  XX  stale pointer cannot escape through global storage"; sed -n '1,10p' "$tmp/v2-global-pointer-stale/log"; fail=$((fail + 1))
elif grep -q 'use after free of named allocation `p`' "$tmp/v2-global-pointer-stale/log" &&
     grep -q 'owned allocation escapes through non-local aggregate store' "$tmp/v2-global-pointer-stale/log"; then
  echo "  ok  stale pointer cannot escape through global storage without artifact"; pass=$((pass + 1))
else
  echo "  XX  stale global pointer rejection missing lifetime diagnostic"; sed -n '1,10p' "$tmp/v2-global-pointer-stale/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-global-init"
printf 'name = "v2globalinit"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-global-init/zag.mod"
printf 'global let counter:i32 = 1; fn main() i32 { return 0; }\n' >"$tmp/v2-global-init/main.zag"
if (cd "$tmp/v2-global-init" && "$ZNC" main.zag -o out) >"$tmp/v2-global-init/log" 2>&1 || [ -e "$tmp/v2-global-init/out" ]; then
  echo "  XX  nonzero global initializer rejects without artifact"; sed -n '1,8p' "$tmp/v2-global-init/log"; fail=$((fail + 1))
elif grep -q 'zero initialization' "$tmp/v2-global-init/log"; then
  echo "  ok  nonzero global initializer rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  nonzero global initializer rejection missing diagnostic"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-top-level-const"
printf 'name = "v2toplevelconst"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-top-level-const/zag.mod"
printf 'const answer:i32=42; fn main() i32 { return answer; }\n' >"$tmp/v2-top-level-const/main.zag"
if (cd "$tmp/v2-top-level-const" && "$ZNC" main.zag -o out) >"$tmp/v2-top-level-const/log" 2>&1 && [ -x "$tmp/v2-top-level-const/out" ]; then
  set +e
  "$tmp/v2-top-level-const/out"
  top_level_const_rc=$?
  set -e
  if [ "$top_level_const_rc" -eq 42 ]; then
    echo "  ok  top-level const remains a callable value, not mutable storage"; pass=$((pass + 1))
  else
    echo "  XX  top-level const execution (exit=$top_level_const_rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  top-level const compile"; sed -n '1,8p' "$tmp/v2-top-level-const/log"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-raw-pointer-order"
printf 'name = "v2rawpointerorder"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-raw-pointer-order/zag.mod"
printf 'unsafe fn ordered(p: *mut i32, q: *mut i32) bool { return p < q; } fn main() i32 { return 0; }\n' >"$tmp/v2-raw-pointer-order/main.zag"
if (cd "$tmp/v2-raw-pointer-order" && "$ZNC" main.zag -o out) >"$tmp/v2-raw-pointer-order/log" 2>&1 ||
   [ -e "$tmp/v2-raw-pointer-order/out" ]; then
  echo "  XX  raw pointer ordering rejects without artifact"; sed -n '1,8p' "$tmp/v2-raw-pointer-order/log"; fail=$((fail + 1))
elif grep -q 'raw-pointer ordering comparisons are unsupported' "$tmp/v2-raw-pointer-order/log"; then
  echo "  ok  raw pointer ordering rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  raw pointer ordering rejection missing diagnostic"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-embedded-release"
printf 'name = "v2embeddedrelease"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-embedded-release/zag.mod"
printf 'fn main() i32 { unsafe { let p:*mut i32=new(42) as *mut i32; let ignored:i32=delete(p) as i32; } return 0; }\n' >"$tmp/v2-embedded-release/main.zag"
if (cd "$tmp/v2-embedded-release" && "$ZNC" main.zag -o out) >"$tmp/v2-embedded-release/log" 2>&1 || [ -e "$tmp/v2-embedded-release/out" ]; then
  echo "  XX  embedded release rejects without artifact"; sed -n '1,8p' "$tmp/v2-embedded-release/log"; fail=$((fail + 1))
elif grep -q 'release or @consumes call must be a standalone statement' "$tmp/v2-embedded-release/log"; then
  echo "  ok  embedded release rejects with an ownership-boundary diagnostic"; pass=$((pass + 1))
else
  echo "  XX  embedded release rejection missing diagnostic"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-owned-realloc-transfer"
printf 'name = "v2ownedrealloctransfer"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-realloc-transfer/zag.mod"
printf 'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p.*=7; let q:*i8=_zag_realloc(p,32) as *i8; q.*=42; _zag_free(q); } return 0; }\n' >"$tmp/v2-owned-realloc-transfer/main.zag"
if (cd "$tmp/v2-owned-realloc-transfer" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-realloc-transfer/log" 2>&1 && [ -x "$tmp/v2-owned-realloc-transfer/out" ] && "$tmp/v2-owned-realloc-transfer/out"; then
  echo "  ok  realloc transfers a named owner to its replacement"; pass=$((pass + 1))
else
  echo "  XX  realloc named-owner transfer"; sed -n '1,8p' "$tmp/v2-owned-realloc-transfer/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-realloc-overwrite"
printf 'name = "v2ownedreallocoverwrite"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-realloc-overwrite/zag.mod"
printf 'fn main() i32 { unsafe { let p:*i8=_zag_malloc(16) as *i8; p.*=7; p=_zag_realloc(p,32) as *i8; p.*=42; _zag_free(p); } return 0; }\n' >"$tmp/v2-owned-realloc-overwrite/main.zag"
if (cd "$tmp/v2-owned-realloc-overwrite" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-realloc-overwrite/log" 2>&1 && [ -x "$tmp/v2-owned-realloc-overwrite/out" ] && "$tmp/v2-owned-realloc-overwrite/out"; then
  echo "  ok  realloc may replace its named owner in place"; pass=$((pass + 1))
else
  echo "  XX  realloc in-place owner replacement"; sed -n '1,8p' "$tmp/v2-owned-realloc-overwrite/log"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-owned-borrow-scalar-contract"
printf 'name = "v2ownedborrowscalarcontract"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-borrow-scalar-contract/zag.mod"
printf 'struct Node { value:i32 } fn inspect(p:*mut Node, limit:i64) void @borrows { if (limit < 0) { return; } } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; inspect(p,1); delete(p); } return 0; }\n' >"$tmp/v2-owned-borrow-scalar-contract/main.zag"
if (cd "$tmp/v2-owned-borrow-scalar-contract" && "$ZNC" check main.zag) >"$tmp/v2-owned-borrow-scalar-contract/log" 2>&1; then
  echo "  ok  borrow contract permits scalar auxiliary parameter"; pass=$((pass + 1))
else
  echo "  XX  borrow contract scalar auxiliary parameter"; sed -n '1,8p' "$tmp/v2-owned-borrow-scalar-contract/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-borrow-pointer-aux"
printf 'name = "v2ownedborrowpointeraux"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-borrow-pointer-aux/zag.mod"
printf 'struct Node { value:i32 } fn bad(p:*mut Node, other:*mut Node) void @borrows { } fn main() i32 { return 0; }\n' >"$tmp/v2-owned-borrow-pointer-aux/main.zag"
if (cd "$tmp/v2-owned-borrow-pointer-aux" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-borrow-pointer-aux/log" 2>&1 || [ -e "$tmp/v2-owned-borrow-pointer-aux/out" ]; then
  echo "  XX  borrow contract pointer auxiliary parameter rejects"; sed -n '1,8p' "$tmp/v2-owned-borrow-pointer-aux/log"; fail=$((fail + 1))
elif grep -q 'borrow contract auxiliary parameters must be builtin scalars' "$tmp/v2-owned-borrow-pointer-aux/log"; then
  echo "  ok  borrow contract pointer auxiliary parameter rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  borrow contract pointer auxiliary rejection missing diagnostic"; sed -n '1,8p' "$tmp/v2-owned-borrow-pointer-aux/log"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-owned-consume-scalar-contract"
printf 'name = "v2ownedconsumescalarcontract"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-consume-scalar-contract/zag.mod"
printf 'struct Node { value:i32 } fn dispose(p:*mut Node, count:i64) void @consumes { unsafe { delete(p); } } fn main() i32 { unsafe { let p:*mut Node=new(Node{.value=42}) as *mut Node; dispose(p,1); } return 0; }\n' >"$tmp/v2-owned-consume-scalar-contract/main.zag"
if (cd "$tmp/v2-owned-consume-scalar-contract" && "$ZNC" check main.zag) >"$tmp/v2-owned-consume-scalar-contract/log" 2>&1; then
  echo "  ok  consume contract permits scalar auxiliary parameter"; pass=$((pass + 1))
else
  echo "  XX  consume contract scalar auxiliary parameter"; sed -n '1,8p' "$tmp/v2-owned-consume-scalar-contract/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-owned-consume-pointer-aux"
printf 'name = "v2ownedconsumepointeraux"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-owned-consume-pointer-aux/zag.mod"
printf 'struct Node { value:i32 } fn bad(p:*mut Node, other:*mut Node) void @consumes { unsafe { delete(p); } } fn main() i32 { return 0; }\n' >"$tmp/v2-owned-consume-pointer-aux/main.zag"
if (cd "$tmp/v2-owned-consume-pointer-aux" && "$ZNC" main.zag -o out) >"$tmp/v2-owned-consume-pointer-aux/log" 2>&1 || [ -e "$tmp/v2-owned-consume-pointer-aux/out" ]; then
  echo "  XX  consume contract pointer auxiliary parameter rejects"; sed -n '1,8p' "$tmp/v2-owned-consume-pointer-aux/log"; fail=$((fail + 1))
elif grep -q '@consumes auxiliary parameters must be builtin scalars' "$tmp/v2-owned-consume-pointer-aux/log"; then
  echo "  ok  consume contract pointer auxiliary parameter rejects without artifact"; pass=$((pass + 1))
else
  echo "  XX  consume contract pointer auxiliary rejection missing diagnostic"; sed -n '1,8p' "$tmp/v2-owned-consume-pointer-aux/log"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-nullable-index"
printf 'name = "v2nullableindex"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-nullable-index/zag.mod"
printf 'unsafe fn load(p: ?*const i32) i32 { return p[0]; } fn main() i32 { return 0; }\n' >"$tmp/v2-nullable-index/main.zag"
if (cd "$tmp/v2-nullable-index" && "$ZNC" main.zag -o out) >"$tmp/v2-nullable-index/log" 2>&1 || [ -e "$tmp/v2-nullable-index/out" ]; then
  echo "  XX  nullable raw pointer indexing requires unwrap"; sed -n '1,8p' "$tmp/v2-nullable-index/log"; fail=$((fail + 1))
elif grep -q 'nullable raw pointer must be explicitly unwrapped before indexing' "$tmp/v2-nullable-index/log"; then
  echo "  ok  nullable raw pointer indexing requires unwrap without artifact"; pass=$((pass + 1))
else
  echo "  XX  nullable raw pointer indexing rejection missing diagnostic"; fail=$((fail + 1))
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
mkdir -p "$tmp/v2-volatile-positive"
printf 'name = "v2volatilepositive"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-positive/zag.mod"
printf 'fn sixth(a:i64,b:i64,c:i64,d:i64,e:i64,f:i64) i64 { return f; } fn main() i32 { let word:i64=41; unsafe { let p:*mut i64=(&word) as *mut i64; @volatileStore(p,sixth(1,2,3,4,5,42)); return @volatileLoad(p) as i32; } }\n' >"$tmp/v2-volatile-positive/main.zag"
if (cd "$tmp/v2-volatile-positive" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-volatile-positive/log" 2>&1 && [ -x "$tmp/v2-volatile-positive/out" ]; then
  set +e
  "$tmp/v2-volatile-positive/out"
  volatile_rc=$?
  set -e
  if [ "$volatile_rc" -eq 42 ]; then
    echo "  ok  checked native volatile word transaction preserves address across value call"; pass=$((pass + 1))
  else
    echo "  XX  checked native volatile word transaction (exit=$volatile_rc)"; sed -n '1,12p' "$tmp/v2-volatile-positive/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked native volatile word transaction compiles"; sed -n '1,16p' "$tmp/v2-volatile-positive/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-byte-positive"
printf 'name = "v2volatilebytepositive"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-byte-positive/zag.mod"
# Store8 writes the low byte; Load8 must zero-extend it into the result.
printf 'fn main() i32 { let byte:u8=0; unsafe { let p:*mut u8=(&byte) as *mut u8; @volatileStore8(p,322); return @volatileLoad8(p) as i32; } }\n' >"$tmp/v2-volatile-byte-positive/main.zag"
if (cd "$tmp/v2-volatile-byte-positive" && "$ZNC" main.zag -o out --safety=checked) >"$tmp/v2-volatile-byte-positive/log" 2>&1 && [ -x "$tmp/v2-volatile-byte-positive/out" ]; then
  set +e
  "$tmp/v2-volatile-byte-positive/out"
  volatile_byte_rc=$?
  set -e
  if [ "$volatile_byte_rc" -eq 66 ]; then
    echo "  ok  checked native volatile byte transaction truncates and zero-extends"; pass=$((pass + 1))
  else
    echo "  XX  checked native volatile byte transaction (exit=$volatile_byte_rc)"; sed -n '1,12p' "$tmp/v2-volatile-byte-positive/log"; fail=$((fail + 1))
  fi
else
  echo "  XX  checked native volatile byte transaction compiles"; sed -n '1,16p' "$tmp/v2-volatile-byte-positive/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-byte-safe"
printf 'name = "v2volatilebytesafe"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-byte-safe/zag.mod"
printf 'fn read(p:*const u8) u8 { return @volatileLoad8(p); } fn main() i32 { return 0; }\n' >"$tmp/v2-volatile-byte-safe/main.zag"
if (cd "$tmp/v2-volatile-byte-safe" && "$ZNC" main.zag -o out) >"$tmp/v2-volatile-byte-safe/log" 2>&1 || [ -e "$tmp/v2-volatile-byte-safe/out" ]; then
  echo "  XX  volatile byte access outside unsafe rejects"; sed -n '1,12p' "$tmp/v2-volatile-byte-safe/log"; fail=$((fail + 1))
elif grep -q 'volatile/MMIO access requires unsafe' "$tmp/v2-volatile-byte-safe/log"; then
  echo "  ok  volatile byte access outside unsafe rejects"; pass=$((pass + 1))
else
  echo "  XX  volatile byte unsafe diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-byte-const"
printf 'name = "v2volatilebyteconst"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-byte-const/zag.mod"
printf 'fn main() i32 { let byte:u8=0; unsafe { let p:*const u8=(&byte) as *const u8; @volatileStore8(p,42); } return 0; }\n' >"$tmp/v2-volatile-byte-const/main.zag"
if (cd "$tmp/v2-volatile-byte-const" && "$ZNC" main.zag -o out) >"$tmp/v2-volatile-byte-const/log" 2>&1 || [ -e "$tmp/v2-volatile-byte-const/out" ]; then
  echo "  XX  volatile byte const store rejects"; sed -n '1,12p' "$tmp/v2-volatile-byte-const/log"; fail=$((fail + 1))
elif grep -q 'volatile/MMIO store cannot write through \*const' "$tmp/v2-volatile-byte-const/log"; then
  echo "  ok  volatile byte const store rejects"; pass=$((pass + 1))
else
  echo "  XX  volatile byte const-store diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-byte-width"
printf 'name = "v2volatilebytewidth"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-byte-width/zag.mod"
printf 'fn main() i32 { let word:i32=0; unsafe { let p:*mut i32=(&word) as *mut i32; @volatileStore8(p,42); } return 0; }\n' >"$tmp/v2-volatile-byte-width/main.zag"
if (cd "$tmp/v2-volatile-byte-width" && "$ZNC" main.zag -o out) >"$tmp/v2-volatile-byte-width/log" 2>&1 || [ -e "$tmp/v2-volatile-byte-width/out" ]; then
  echo "  XX  volatile byte pointer type rejects"; sed -n '1,12p' "$tmp/v2-volatile-byte-width/log"; fail=$((fail + 1))
elif grep -q 'volatile/MMIO byte access requires' "$tmp/v2-volatile-byte-width/log"; then
  echo "  ok  volatile byte pointer type rejects"; pass=$((pass + 1))
else
  echo "  XX  volatile byte pointer type diagnostic missing"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-safe"
printf 'name = "v2volatilesafe"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-safe/zag.mod"
printf 'fn read(p:*mut i64) i64 { return @volatileLoad(p); } fn main() i32 { let word:i64=0; unsafe { let p:*mut i64=(&word) as *mut i64; return read(p) as i32; } }\n' >"$tmp/v2-volatile-safe/main.zag"
if (cd "$tmp/v2-volatile-safe" && "$ZNC" main.zag -o out) >"$tmp/v2-volatile-safe/log" 2>&1 || [ -e "$tmp/v2-volatile-safe/out" ]; then
  echo "  XX  volatile access outside unsafe rejects"; sed -n '1,12p' "$tmp/v2-volatile-safe/log"; fail=$((fail + 1))
elif grep -q 'volatile/MMIO access requires unsafe' "$tmp/v2-volatile-safe/log"; then
  echo "  ok  volatile access outside unsafe rejects"; pass=$((pass + 1))
else
  echo "  XX  volatile unsafe diagnostic missing"; sed -n '1,12p' "$tmp/v2-volatile-safe/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-const"
printf 'name = "v2volatileconst"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-const/zag.mod"
printf 'fn main() i32 { let word:i64=0; unsafe { let p:*const i64=(&word) as *const i64; @volatileStore(p,42); } return 0; }\n' >"$tmp/v2-volatile-const/main.zag"
if (cd "$tmp/v2-volatile-const" && "$ZNC" main.zag -o out) >"$tmp/v2-volatile-const/log" 2>&1 || [ -e "$tmp/v2-volatile-const/out" ]; then
  echo "  XX  volatile const store rejects"; sed -n '1,12p' "$tmp/v2-volatile-const/log"; fail=$((fail + 1))
elif grep -q 'volatile/MMIO store cannot write through \*const' "$tmp/v2-volatile-const/log"; then
  echo "  ok  volatile const store rejects"; pass=$((pass + 1))
else
  echo "  XX  volatile const-store diagnostic missing"; sed -n '1,12p' "$tmp/v2-volatile-const/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-pure"
printf 'name = "v2volatilepure"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-pure/zag.mod"
printf 'fn read(p:*const i64) i64 @pure { unsafe { return @volatileLoad(p); } } fn main() i32 { return 0; }\n' >"$tmp/v2-volatile-pure/main.zag"
if (cd "$tmp/v2-volatile-pure" && "$ZNC" main.zag -o out) >"$tmp/v2-volatile-pure/log" 2>&1 || [ -e "$tmp/v2-volatile-pure/out" ]; then
  echo "  XX  volatile Unsafe effect reaches pure function"; sed -n '1,12p' "$tmp/v2-volatile-pure/log"; fail=$((fail + 1))
elif grep -q '@pure function' "$tmp/v2-volatile-pure/log"; then
  echo "  ok  volatile Unsafe effect reaches pure function"; pass=$((pass + 1))
else
  echo "  XX  volatile pure-effect diagnostic missing"; sed -n '1,12p' "$tmp/v2-volatile-pure/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-fence-pure"
printf 'name = "v2fencepure"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-fence-pure/zag.mod"
printf 'fn fenced() i32 @pure { @memoryFence(); return 0; } fn main() i32 { return 0; }\n' >"$tmp/v2-fence-pure/main.zag"
if (cd "$tmp/v2-fence-pure" && "$ZNC" main.zag -o out) >"$tmp/v2-fence-pure/log" 2>&1 || [ -e "$tmp/v2-fence-pure/out" ]; then
  echo "  XX  legacy fence Unsafe effect reaches pure function"; sed -n '1,12p' "$tmp/v2-fence-pure/log"; fail=$((fail + 1))
elif grep -q 'capability violation.*pure' "$tmp/v2-fence-pure/log"; then
  echo "  ok  legacy fence Unsafe effect reaches pure function"; pass=$((pass + 1))
else
  echo "  XX  legacy fence pure-effect diagnostic missing"; sed -n '1,12p' "$tmp/v2-fence-pure/log"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v2-volatile-width"
printf 'name = "v2volatilewidth"\nversion = "0"\nedition = "2027"\n' >"$tmp/v2-volatile-width/zag.mod"
printf 'fn main() i32 { let word:i32=0; unsafe { let p:*mut i32=(&word) as *mut i32; @volatileStore(p,42); } return 0; }\n' >"$tmp/v2-volatile-width/main.zag"
if (cd "$tmp/v2-volatile-width" && "$ZNC" main.zag -o out) >"$tmp/v2-volatile-width/log" 2>&1 || [ -e "$tmp/v2-volatile-width/out" ]; then
  echo "  XX  volatile narrow-width transaction rejects"; sed -n '1,12p' "$tmp/v2-volatile-width/log"; fail=$((fail + 1))
elif grep -q 'volatile/MMIO requires' "$tmp/v2-volatile-width/log"; then
  echo "  ok  volatile narrow-width transaction rejects"; pass=$((pass + 1))
else
  echo "  XX  volatile width diagnostic missing"; sed -n '1,12p' "$tmp/v2-volatile-width/log"; fail=$((fail + 1))
fi
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
