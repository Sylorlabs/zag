#!/usr/bin/env bash
# Native allocator lifetime integrity: this is runtime coverage for values that
# evade the edition-2027 local ownership proof (for example a v1 ABI boundary).
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-allocator-lifetime.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(32) as *i8; _zag_free(p); let q:*i8 = _zag_malloc(32) as *i8; _zag_free(q); return 0; }' >"$tmp/reuse.zag"
if "$ZNC" "$tmp/reuse.zag" -o "$tmp/reuse" --no-zagd --no-analyze --no-foreground-cache >"$tmp/reuse.log" 2>&1 && "$tmp/reuse"; then
  echo "  ok  allocator restores a live header on free-list reuse"; pass=$((pass + 1))
else
  echo "  XX  allocator reuse after free"; sed -n '1,8p' "$tmp/reuse.log"; fail=$((fail + 1))
fi

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(0 - 1) as *i8; if (p == null as *i8) { return 2; } return 3; }' >"$tmp/negative_malloc.zag"
if "$ZNC" "$tmp/negative_malloc.zag" -o "$tmp/negative_malloc" --no-zagd --no-analyze --no-foreground-cache >"$tmp/negative_malloc.log" 2>&1; then
  set +e
  "$tmp/negative_malloc" >"$tmp/negative_malloc.out" 2>"$tmp/negative_malloc.err"
  rc=$?
  set -e
  if [ "$rc" -eq 1 ] && grep -q 'zag runtime: invalid negative allocation size' "$tmp/negative_malloc.err"; then
    echo "  ok  negative malloc size fails before size-class selection"; pass=$((pass + 1))
  else
    echo "  XX  negative malloc was not rejected deterministically (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  negative malloc program did not compile"; sed -n '1,8p' "$tmp/negative_malloc.log"; fail=$((fail + 1))
fi

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(32) as *i8; let q:*i8 = _zag_realloc(p, 0 - 1) as *i8; if (q == null as *i8) { return 2; } return 3; }' >"$tmp/negative_realloc.zag"
if "$ZNC" "$tmp/negative_realloc.zag" -o "$tmp/negative_realloc" --no-zagd --no-analyze --no-foreground-cache >"$tmp/negative_realloc.log" 2>&1; then
  set +e
  "$tmp/negative_realloc" >"$tmp/negative_realloc.out" 2>"$tmp/negative_realloc.err"
  rc=$?
  set -e
  if [ "$rc" -eq 1 ] && grep -q 'zag runtime: invalid negative realloc size' "$tmp/negative_realloc.err"; then
    echo "  ok  negative realloc size fails before pointer probing"; pass=$((pass + 1))
  else
    echo "  XX  negative realloc was not rejected deterministically (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  negative realloc program did not compile"; sed -n '1,8p' "$tmp/negative_realloc.log"; fail=$((fail + 1))
fi

cat >"$tmp/null_realloc.zag" <<'ZAG'
extern fn _zag_allocator_allocation_count() i64
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    let base_count:i64 = _zag_allocator_allocation_count();
    let base_live:i64 = _zag_allocator_live_bytes();
    let p:*i8 = _zag_realloc(null as *i8, 17) as *i8;
    if (p == null as *i8) { return 1; }
    if (_zag_allocator_allocation_count() != base_count + 1 ||
        _zag_allocator_live_bytes() != base_live + 32) { return 2; }
    _zag_free(p);
    if (_zag_allocator_live_bytes() != base_live) { return 3; }
    return 0;
}
ZAG
if "$ZNC" "$tmp/null_realloc.zag" -o "$tmp/null_realloc" --no-zagd --no-analyze --no-foreground-cache >"$tmp/null_realloc.log" 2>&1 && "$tmp/null_realloc"; then
  echo "  ok  realloc(null, n) follows malloc allocation semantics"; pass=$((pass + 1))
else
  echo "  XX  realloc(null, n) did not follow malloc semantics"; sed -n '1,8p' "$tmp/null_realloc.log"; fail=$((fail + 1))
fi

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(32) as *i8; _zag_free(p); _zag_free(p); return 0; }' >"$tmp/double_free.zag"
if "$ZNC" "$tmp/double_free.zag" -o "$tmp/double_free" --no-zagd --no-analyze --no-foreground-cache >"$tmp/double_free.log" 2>&1; then
  set +e
  "$tmp/double_free" >"$tmp/double_free.out" 2>"$tmp/double_free.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q 'zag runtime: invalid or double free' "$tmp/double_free.err"; then
    echo "  ok  dynamic double free fails closed"; pass=$((pass + 1))
  else
    echo "  XX  dynamic double free did not fail closed (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  dynamic double free program did not compile"; sed -n '1,8p' "$tmp/double_free.log"; fail=$((fail + 1))
fi

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(32) as *i8; _zag_free(p); let q:*i8 = _zag_realloc(p, 64) as *i8; return 0; }' >"$tmp/stale_realloc.zag"
if "$ZNC" "$tmp/stale_realloc.zag" -o "$tmp/stale_realloc" --no-zagd --no-analyze --no-foreground-cache >"$tmp/stale_realloc.log" 2>&1; then
  set +e
  "$tmp/stale_realloc" >"$tmp/stale_realloc.out" 2>"$tmp/stale_realloc.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q 'zag runtime: realloc of invalid or freed allocation' "$tmp/stale_realloc.err"; then
    echo "  ok  stale realloc fails closed"; pass=$((pass + 1))
  else
    echo "  XX  stale realloc did not fail closed (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  stale realloc program did not compile"; sed -n '1,8p' "$tmp/stale_realloc.log"; fail=$((fail + 1))
fi

# Large allocations use dedicated mmap mappings. Their header is unmapped by
# the first free, so this covers the separate bounded provenance path rather
# than merely repeating the small free-list checks above.
printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(524289) as *i8; _zag_free(p); _zag_free(p); return 0; }' >"$tmp/large_double_free.zag"
if "$ZNC" "$tmp/large_double_free.zag" -o "$tmp/large_double_free" --no-zagd --no-analyze --no-foreground-cache >"$tmp/large_double_free.log" 2>&1; then
  set +e
  "$tmp/large_double_free" >"$tmp/large_double_free.out" 2>"$tmp/large_double_free.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q 'zag runtime: invalid or double free' "$tmp/large_double_free.err"; then
    echo "  ok  large-map double free fails before unmapped-header access"; pass=$((pass + 1))
  else
    echo "  XX  large-map double free was not rejected cleanly (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  large-map double-free program did not compile"; sed -n '1,8p' "$tmp/large_double_free.log"; fail=$((fail + 1))
fi

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(524289) as *i8; _zag_free(p); let q:*i8 = _zag_realloc(p, 1048576) as *i8; return 0; }' >"$tmp/large_stale_realloc.zag"
if "$ZNC" "$tmp/large_stale_realloc.zag" -o "$tmp/large_stale_realloc" --no-zagd --no-analyze --no-foreground-cache >"$tmp/large_stale_realloc.log" 2>&1; then
  set +e
  "$tmp/large_stale_realloc" >"$tmp/large_stale_realloc.out" 2>"$tmp/large_stale_realloc.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q 'zag runtime: realloc of invalid or freed allocation' "$tmp/large_stale_realloc.err"; then
    echo "  ok  large-map stale realloc fails before unmapped-header access"; pass=$((pass + 1))
  else
    echo "  XX  large-map stale realloc was not rejected cleanly (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  large-map stale-realloc program did not compile"; sed -n '1,8p' "$tmp/large_stale_realloc.log"; fail=$((fail + 1))
fi

# A freed large allocation is unmapped rather than returned to a small-block
# free list. A stale raw dereference must therefore trap at the OS boundary;
# this is a real runtime guard for the dedicated-map subset, not a claim of
# general small-allocation use-after-free instrumentation.
printf '%s\n' 'fn main() i32 { let p:*i32 = _zag_malloc(524289) as *i32; p.* = 42; _zag_free(p); return p.*; }' >"$tmp/large_stale_deref.zag"
if "$ZNC" "$tmp/large_stale_deref.zag" -o "$tmp/large_stale_deref" --no-zagd --no-analyze --no-foreground-cache >"$tmp/large_stale_deref.log" 2>&1; then
  set +e
  "$tmp/large_stale_deref" >"$tmp/large_stale_deref.out" 2>"$tmp/large_stale_deref.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  ok  large-map stale dereference traps after unmap"; pass=$((pass + 1))
  else
    echo "  XX  large-map stale dereference unexpectedly returned"; fail=$((fail + 1))
  fi
else
  echo "  XX  large-map stale-dereference program did not compile"; sed -n '1,8p' "$tmp/large_stale_deref.log"; fail=$((fail + 1))
fi

cat >"$tmp/large_to_small_address_reuse.zag" <<'ZAG'
fn main() i32 {
    // Payload + allocator header is exactly one 1 MiB mapping. Linux normally
    // reuses that just-unmapped range for the next 1 MiB small arena.
    let large:*i8 = _zag_malloc(1048568) as *i8;
    let former:i64 = large as i64;
    _zag_free(large);
    let i:i32 = 0;
    while (i < 50000) {
        let small:*i8 = _zag_malloc(16) as *i8;
        if ((small as i64) == former) {
            _zag_free(small);
            return 0;
        }
        i = i + 1;
    }
    // Address placement is an OS choice. Absence of reuse is not a runtime
    // failure; the compiler-sized foreground-cache test supplies the observed
    // end-to-end witness on the release host.
    return 0;
}
ZAG
if "$ZNC" "$tmp/large_to_small_address_reuse.zag" -o "$tmp/large_to_small_address_reuse" --no-zagd --no-analyze --no-foreground-cache >"$tmp/large_to_small_address_reuse.log" 2>&1 && "$tmp/large_to_small_address_reuse"; then
  echo "  ok  small-arena acquisition tolerates a reused large-map address"; pass=$((pass + 1))
else
  echo "  XX  large-map tombstone rejected a newly acquired small block"; sed -n '1,8p' "$tmp/large_to_small_address_reuse.log"; fail=$((fail + 1))
fi

cat >"$tmp/large_telemetry.zag" <<'ZAG'
extern fn _zag_allocator_allocation_count() i64
extern fn _zag_allocator_live_bytes() i64
extern fn _zag_allocator_peak_live_bytes() i64
fn main() i32 {
    let base_count:i64 = _zag_allocator_allocation_count();
    let base_live:i64 = _zag_allocator_live_bytes();
    let base_peak:i64 = _zag_allocator_peak_live_bytes();
    let p:*i8 = _zag_malloc(524289) as *i8;
    if (_zag_allocator_allocation_count() != base_count + 1 || _zag_allocator_live_bytes() != base_live + 524289 || _zag_allocator_peak_live_bytes() < base_live + 524289) { return 1; }
    _zag_free(p);
    if (_zag_allocator_live_bytes() != base_live || _zag_allocator_peak_live_bytes() < base_peak) { return 2; }
    return 0;
}
ZAG
if "$ZNC" "$tmp/large_telemetry.zag" -o "$tmp/large_telemetry" --no-zagd --no-analyze --no-foreground-cache >"$tmp/large_telemetry.log" 2>&1 && "$tmp/large_telemetry"; then
  echo "  ok  large-map allocation telemetry commits only around a live mapping"; pass=$((pass + 1))
else
  echo "  XX  large-map allocation telemetry witness"; sed -n '1,8p' "$tmp/large_telemetry.log"; fail=$((fail + 1))
fi

cat >"$tmp/large_realloc_telemetry.zag" <<'ZAG'
extern fn _zag_allocator_allocation_count() i64
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    let base_count:i64 = _zag_allocator_allocation_count();
    let base_live:i64 = _zag_allocator_live_bytes();
    let p:*i8 = _zag_malloc(524289) as *i8;
    let q:*i8 = _zag_realloc(p, 524300) as *i8;
    if (_zag_allocator_allocation_count() != base_count + 2 || _zag_allocator_live_bytes() != base_live + 524300) { return 1; }
    _zag_free(q);
    if (_zag_allocator_live_bytes() != base_live) { return 2; }
    return 0;
}
ZAG
if "$ZNC" "$tmp/large_realloc_telemetry.zag" -o "$tmp/large_realloc_telemetry" --no-zagd --no-analyze --no-foreground-cache >"$tmp/large_realloc_telemetry.log" 2>&1 && "$tmp/large_realloc_telemetry"; then
  echo "  ok  large-map realloc preserves live-byte accounting"; pass=$((pass + 1))
else
  echo "  XX  large-map realloc telemetry witness"; sed -n '1,8p' "$tmp/large_realloc_telemetry.log"; fail=$((fail + 1))
fi

cat >"$tmp/alloc_failure.zag" <<'ZAG'
fn main() i32 {
    let p:*i8 = _zag_malloc(134217728) as *i8;
    if (p == null as *i8) { return 2; }
    return 3;
}
ZAG
if "$ZNC" "$tmp/alloc_failure.zag" -o "$tmp/alloc_failure" --no-zagd --no-analyze --no-foreground-cache >"$tmp/alloc_failure-build.log" 2>&1; then
  set +e
  (ulimit -v 65536; "$tmp/alloc_failure") >"$tmp/alloc_failure.out" 2>"$tmp/alloc_failure.err"
  alloc_failure_status=$?
  set -e
  if [ "$alloc_failure_status" -eq 1 ] && grep -q 'zag runtime: allocation failed' "$tmp/alloc_failure.err"; then
    echo "  ok  OS allocation failure is deterministic"; pass=$((pass + 1))
  else
    echo "  XX  OS allocation failure status=$alloc_failure_status"; sed -n '1,8p' "$tmp/alloc_failure.err"; fail=$((fail + 1))
  fi
else
  echo "  XX  allocation failure program did not compile"; sed -n '1,8p' "$tmp/alloc_failure-build.log"; fail=$((fail + 1))
fi

printf '%s\n' \
  'extern fn _zag_allocator_allocation_count() i64' \
  'extern fn _zag_allocator_live_bytes() i64' \
  'extern fn _zag_allocator_peak_live_bytes() i64' \
  'fn main() i32 {' \
  '  if (_zag_allocator_allocation_count() != 0 || _zag_allocator_live_bytes() != 0 || _zag_allocator_peak_live_bytes() != 0) { return 1; }' \
  '  let p:*i8 = _zag_malloc(1) as *i8;' \
  '  let q:*i8 = _zag_malloc(17) as *i8;' \
  '  if (_zag_allocator_allocation_count() != 2 || _zag_allocator_live_bytes() != 48 || _zag_allocator_peak_live_bytes() != 48) { return 2; }' \
  '  _zag_free(p);' \
  '  if (_zag_allocator_live_bytes() != 32) { return 3; }' \
  '  q = _zag_realloc(q, 33) as *i8;' \
  '  if (_zag_allocator_allocation_count() != 3 || _zag_allocator_live_bytes() != 64 || _zag_allocator_peak_live_bytes() != 96) { return 4; }' \
  '  _zag_free(q);' \
  '  if (_zag_allocator_live_bytes() != 0 || _zag_allocator_peak_live_bytes() != 96) { return 5; }' \
  '  return 0;' \
  '}' >"$tmp/telemetry.zag"
if "$ZNC" "$tmp/telemetry.zag" -o "$tmp/telemetry" --no-zagd --no-analyze --no-foreground-cache >"$tmp/telemetry.log" 2>&1 && "$tmp/telemetry"; then
  echo "  ok  allocation count and peak-live-capacity witness"; pass=$((pass + 1))
else
  echo "  XX  allocation telemetry witness"; sed -n '1,8p' "$tmp/telemetry.log"; fail=$((fail + 1))
fi

printf '%s\n' \
  'script;' \
  'extern fn _zag_allocator_allocation_count() i64' \
  'extern fn _zag_allocator_live_bytes() i64' \
  'extern fn _zag_allocator_peak_live_bytes() i64' \
  'if (_zag_allocator_allocation_count() != 1 || _zag_allocator_live_bytes() != 128 || _zag_allocator_peak_live_bytes() != 128) { return 1; }' \
  'let memory:*i8 = script_alloc(24);' \
  'if (memory == null as *i8) { return 2; }' \
  'if (_zag_allocator_allocation_count() != 2 || _zag_allocator_live_bytes() != 152 || _zag_allocator_peak_live_bytes() != 152) { return 3; }' \
  'return 0;' >"$tmp/script_telemetry.zag"
if "$ZNC" "$tmp/script_telemetry.zag" -o "$tmp/script_telemetry" --no-zagd --no-analyze --no-foreground-cache >"$tmp/script_telemetry.log" 2>&1 && "$tmp/script_telemetry"; then
  echo "  ok  Zag Script allocations feed the native witness"; pass=$((pass + 1))
else
  echo "  XX  Zag Script allocation telemetry"; sed -n '1,8p' "$tmp/script_telemetry.log"; fail=$((fail + 1))
fi

mkdir "$tmp/script-shutdown"
printf '%s\n' 'name = "script-shutdown-telemetry"' 'edition = "2027"' >"$tmp/script-shutdown/zag.mod"
cat >"$tmp/script-shutdown/main.zag" <<'ZAG'
extern fn _zag_script_context_init(limit:i64, capabilities:i64, execution_policy:i64) *opaque
extern fn _zag_script_context_shutdown(context:*opaque) void
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    unsafe {
        let context:*opaque = _zag_script_context_init(1048576, 7, 16843009);
        if (context == null as *opaque || _zag_allocator_live_bytes() != 128) { return 1; }
        _zag_script_context_shutdown(context);
        if (_zag_allocator_live_bytes() != 0) { return 2; }
    }
    return 0;
}
ZAG
if "$ZNC" "$tmp/script-shutdown/main.zag" -o "$tmp/script_shutdown_telemetry" --no-zagd --no-analyze --no-foreground-cache >"$tmp/script_shutdown_telemetry.log" 2>&1 && "$tmp/script_shutdown_telemetry"; then
  echo "  ok  Script shutdown releases arena payload and context"; pass=$((pass + 1))
else
  echo "  XX  Script shutdown allocation telemetry"; sed -n '1,8p' "$tmp/script_shutdown_telemetry.log"; fail=$((fail + 1))
fi

cat >"$tmp/slice_descriptor.zag" <<'ZAG'
extern fn _zag_i64_to_str(value:i64) []u8
extern fn _zag_str_free(value:[]u8) void
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    if (_zag_allocator_live_bytes() != 0) { return 1; }
    let text:[]u8 = _zag_i64_to_str(42);
    if (_zag_allocator_live_bytes() <= 0) { return 2; }
    _zag_str_free(text);
    if (_zag_allocator_live_bytes() != 0) { return 3; }
    return 42;
}
ZAG
set +e
"$ZNC" "$tmp/slice_descriptor.zag" -o "$tmp/slice_descriptor" --no-zagd --no-analyze --no-foreground-cache >"$tmp/slice_descriptor.log" 2>&1
compile_rc=$?
if [ "$compile_rc" -eq 0 ]; then
  "$tmp/slice_descriptor" >/dev/null 2>&1
  descriptor_rc=$?
else
  descriptor_rc=$compile_rc
fi
set -e
if [ "$descriptor_rc" -eq 42 ]; then
  echo "  ok  temporary runtime slice descriptor is reclaimed"; pass=$((pass + 1))
else
  echo "  XX  temporary runtime slice descriptor leaked or failed (exit=$descriptor_rc)"; sed -n '1,8p' "$tmp/slice_descriptor.log"; fail=$((fail + 1))
fi

cat >"$tmp/word_slice_lifetime.zag" <<'ZAG'
extern fn _zag_allocator_allocation_count() i64
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    let base_count:i64 = _zag_allocator_allocation_count();
    let base_live:i64 = _zag_allocator_live_bytes();
    let ordinary:[]f32 = zalloc(7);
    if (ordinary.len != 7 || _zag_allocator_allocation_count() != base_count + 1 || _zag_allocator_live_bytes() != base_live + 56) { return 1; }
    zfree(ordinary);
    if (_zag_allocator_live_bytes() != base_live) { return 2; }
    let aligned:[]f32 = @cacheAlignedAlloc(9);
    if (aligned.len != 9 || _zag_allocator_allocation_count() != base_count + 2 || _zag_allocator_live_bytes() != base_live + 72) { return 3; }
    @cacheAlignedFree(aligned);
    if (_zag_allocator_live_bytes() != base_live) { return 4; }
    return 0;
}
ZAG
if "$ZNC" "$tmp/word_slice_lifetime.zag" -o "$tmp/word_slice_lifetime" --no-zagd --no-analyze --no-foreground-cache >"$tmp/word_slice_lifetime.log" 2>&1 && "$tmp/word_slice_lifetime"; then
  echo "  ok  zalloc and cache-aligned free restore prior live bytes"; pass=$((pass + 1))
else
  echo "  XX  word-slice allocation/free lifetime accounting"; sed -n '1,8p' "$tmp/word_slice_lifetime.log"; fail=$((fail + 1))
fi

cat >"$tmp/word_slice_zero.zag" <<'ZAG'
extern fn _zag_allocator_allocation_count() i64
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    let base_count:i64 = _zag_allocator_allocation_count();
    let base_live:i64 = _zag_allocator_live_bytes();
    let ordinary:[]f32 = zalloc(0);
    if (ordinary.len != 0 || _zag_allocator_allocation_count() != base_count || _zag_allocator_live_bytes() != base_live) { return 1; }
    zfree(ordinary);
    if (_zag_allocator_allocation_count() != base_count || _zag_allocator_live_bytes() != base_live) { return 2; }
    let aligned:[]f32 = @cacheAlignedAlloc(0);
    if (aligned.len != 0 || _zag_allocator_allocation_count() != base_count || _zag_allocator_live_bytes() != base_live) { return 3; }
    @cacheAlignedFree(aligned);
    if (_zag_allocator_allocation_count() != base_count || _zag_allocator_live_bytes() != base_live) { return 4; }
    return 0;
}
ZAG
if "$ZNC" "$tmp/word_slice_zero.zag" -o "$tmp/word_slice_zero" --no-zagd --no-analyze --no-foreground-cache >"$tmp/word_slice_zero.log" 2>&1 && "$tmp/word_slice_zero"; then
  echo "  ok  zero-length word slices allocate and release nothing"; pass=$((pass + 1))
else
  echo "  XX  zero-length word-slice handling"; sed -n '1,8p' "$tmp/word_slice_zero.log"; fail=$((fail + 1))
fi

cat >"$tmp/word_slice_count_once.zag" <<'ZAG'
extern fn _zag_allocator_live_bytes() i64
fn next_count(calls:*i32) i32 {
    calls.* = calls.* + 1;
    return 3;
}
fn main() i32 {
    let calls:i32 = 0;
    let base_live:i64 = _zag_allocator_live_bytes();
    let ordinary:[]f32 = zalloc(next_count(&calls));
    if (calls != 1 || ordinary.len != 3 || _zag_allocator_live_bytes() != base_live + 24) { return 1; }
    zfree(ordinary);
    if (_zag_allocator_live_bytes() != base_live) { return 2; }
    let aligned:[]f32 = @cacheAlignedAlloc(next_count(&calls));
    if (calls != 2 || aligned.len != 3 || _zag_allocator_live_bytes() != base_live + 24) { return 3; }
    @cacheAlignedFree(aligned);
    if (_zag_allocator_live_bytes() != base_live) { return 4; }
    return 0;
}
ZAG
if "$ZNC" "$tmp/word_slice_count_once.zag" -o "$tmp/word_slice_count_once" --no-zagd --no-analyze --no-foreground-cache >"$tmp/word_slice_count_once.log" 2>&1 && "$tmp/word_slice_count_once"; then
  echo "  ok  word-slice allocation count expressions evaluate once"; pass=$((pass + 1))
else
  echo "  XX  word-slice allocation count expression evaluation"; sed -n '1,8p' "$tmp/word_slice_count_once.log"; fail=$((fail + 1))
fi

cat >"$tmp/word_slice_alias_double_free.zag" <<'ZAG'
fn main() i32 {
    let original:[]f32 = zalloc(4);
    let copied:[]f32 = original;
    zfree(original);
    zfree(copied);
    return 0;
}
ZAG
set +e
"$ZNC" "$tmp/word_slice_alias_double_free.zag" -o "$tmp/word_slice_alias_double_free" --no-zagd --no-analyze --no-foreground-cache >"$tmp/word_slice_alias_double_free.compile.log" 2>&1
compile_rc=$?
if [ "$compile_rc" -eq 0 ]; then
  "$tmp/word_slice_alias_double_free" >"$tmp/word_slice_alias_double_free.stdout" 2>"$tmp/word_slice_alias_double_free.stderr"
  alias_rc=$?
else
  alias_rc=0
fi
set -e
if [ "$compile_rc" -eq 0 ] && [ "$alias_rc" -ne 0 ] && grep -q "zag runtime: invalid or double raw slice free" "$tmp/word_slice_alias_double_free.stderr"; then
  echo "  ok  copied raw-slice descriptor double free fails closed"; pass=$((pass + 1))
else
  echo "  XX  copied raw-slice descriptor was not rejected (compile=$compile_rc exit=$alias_rc)"
  sed -n '1,8p' "$tmp/word_slice_alias_double_free.compile.log"
  sed -n '1,8p' "$tmp/word_slice_alias_double_free.stderr" 2>/dev/null || true
  fail=$((fail + 1))
fi

cat >"$tmp/word_slice_registry_limit.zag" <<'ZAG'
fn hold_raw_slices(depth:i32) void {
    if (depth <= 0) { return; }
    let value:[]f32 = zalloc(1);
    hold_raw_slices(depth - 1);
    zfree(value);
}
fn main() i32 {
    hold_raw_slices(2049);
    return 0;
}
ZAG
set +e
"$ZNC" "$tmp/word_slice_registry_limit.zag" -o "$tmp/word_slice_registry_limit" --no-zagd --no-analyze --no-foreground-cache >"$tmp/word_slice_registry_limit.compile.log" 2>&1
compile_rc=$?
if [ "$compile_rc" -eq 0 ]; then
  "$tmp/word_slice_registry_limit" >"$tmp/word_slice_registry_limit.stdout" 2>"$tmp/word_slice_registry_limit.stderr"
  registry_rc=$?
else
  registry_rc=0
fi
set -e
if [ "$compile_rc" -eq 0 ] && [ "$registry_rc" -ne 0 ] && grep -q "zag runtime: raw slice allocation registry exhausted" "$tmp/word_slice_registry_limit.stderr"; then
  echo "  ok  raw-slice registry exhaustion fails closed"; pass=$((pass + 1))
else
  echo "  XX  raw-slice registry limit was not enforced (compile=$compile_rc exit=$registry_rc)"
  sed -n '1,8p' "$tmp/word_slice_registry_limit.compile.log"
  sed -n '1,8p' "$tmp/word_slice_registry_limit.stderr" 2>/dev/null || true
  fail=$((fail + 1))
fi

cat >"$tmp/file_path_bridge_lifetime.zag" <<'ZAG'
extern fn _zag_allocator_live_bytes() i64
extern fn _zag_arg(index:i32) []u8
extern fn _zag_write_file(path:[]u8,content:[]u8) i32
extern fn _zag_file_exists(path:[]u8) i32
fn main() i32 {
    let base:i64 = _zag_allocator_live_bytes();
    let i:i32 = 0;
    while (i < 512) {
        if (_zag_write_file(_zag_arg(1), "x") != 0) { return 1; }
        if (_zag_file_exists(_zag_arg(1)) != 1) { return 2; }
        if (_zag_file_exists(_zag_arg(2)) != 0) { return 3; }
        if (_zag_write_file(_zag_arg(2), "x") == 0) { return 4; }
        if (_zag_allocator_live_bytes() != base) { return 5; }
        i = i + 1;
    }
    return 0;
}
ZAG
if "$ZNC" "$tmp/file_path_bridge_lifetime.zag" -o "$tmp/file_path_bridge_lifetime" --no-zagd --no-analyze --no-foreground-cache >"$tmp/file_path_bridge_lifetime.log" 2>&1 &&
   "$tmp/file_path_bridge_lifetime" "$tmp/runtime-file" "$tmp/missing/runtime-file"; then
  echo "  ok  repeated file helper path bridges are reclaimed on success and failure"; pass=$((pass + 1))
else
  echo "  XX  repeated file helper path bridge lifetime"
  sed -n '1,8p' "$tmp/file_path_bridge_lifetime.log"
  fail=$((fail + 1))
fi

echo "════ allocator-lifetime pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
