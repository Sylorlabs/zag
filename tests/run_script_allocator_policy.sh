#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$(pwd)/${ZNC#./}" ;; esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-allocator-policy.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/project"
printf '%s\n' 'name = "script-allocator-policy"' >"$tmp/project/zag.mod"
cat >"$tmp/project/policy.zag" <<'ZAG'
script;
extern fn _zag_allocator_live_bytes() i64
let memory: *i8 = script_alloc(24);
if (memory == null as *i8) { return 1; }
return _zag_allocator_live_bytes() as i32;
ZAG

# The default arena and explicit bounded heap have observably distinct native
# allocation behavior. Building the same source under each policy also proves
# the foreground machine-code key cannot cross the explicit CLI override.
printf '%s\n' \
    'mode=off' \
    'allocator=script_process_arena' \
    'device=cpu' \
    'layout=compiler_owned' \
    'cpu=generic' \
    'script_memory_bytes=1048576' >"$tmp/project/.zagd.conf"
(cd "$tmp/project" && "$ZNC" policy.zag -o arena --no-zagd --no-analyze \
    --cache-report >arena-build.log)
grep -q 'znc cache: MISS' "$tmp/project/arena-build.log"
set +e
"$tmp/project/arena"
arena_status=$?
set -e
test "$arena_status" -eq 152

(cd "$tmp/project" && "$ZNC" policy.zag -o heap \
    --script-allocator script_bounded_heap --no-zagd --no-analyze \
    --cache-report >heap-build.log)
grep -q 'znc cache: MISS' "$tmp/project/heap-build.log"
set +e
"$tmp/project/heap"
heap_status=$?
set -e
test "$heap_status" -eq 192

(cd "$tmp/project" && "$ZNC" policy.zag -o heap-hit \
    --script-allocator script_bounded_heap --no-zagd --no-analyze \
    --cache-report >heap-hit-build.log)
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' \
    "$tmp/project/heap-hit-build.log"
set +e
"$tmp/project/heap-hit"
heap_hit_status=$?
set -e
test "$heap_hit_status" -eq 192

cat >"$tmp/project/limit.zag" <<'ZAG'
script;
let full:*i8 = script_alloc(1048560);
let denied:*i8 = script_alloc(1);
if (full != null as *i8 && denied == null as *i8 &&
    script_alloc_used() == 1048576) { return 0; }
return 2;
ZAG
(cd "$tmp/project" && "$ZNC" limit.zag -o limit \
    --script-allocator script_bounded_heap --no-zagd --no-analyze \
    --no-foreground-cache >/dev/null)
"$tmp/project/limit"

# Explain and strict checking distinguish an explicit allocator choice from an
# automatic default without pretending that a Script-only choice is already an
# ordinary strict-Zag allocator contract.
(cd "$tmp/project" && "$ZNC" explain policy.zag --format json \
    --script-allocator script_bounded_heap --no-zagd) >"$tmp/explain.json"
grep -q '"allocator":{"value":"script_bounded_heap","basis":"explicit"}' \
    "$tmp/explain.json"
grep -q '"reclamation":{"value":"all tracked bounded-heap blocks freed at generated shutdown","basis":"proven"}' \
    "$tmp/explain.json"

if (cd "$tmp/project" && "$ZNC" check policy.zag --strict \
    --script-allocator script_bounded_heap --no-zagd \
    >"$tmp/strict.log" 2>&1); then
    echo "explicit Script allocator unexpectedly satisfied strict promotion" >&2
    exit 1
fi
grep -q 'resolved: explicit Script allocator policy selected: script_bounded_heap' \
    "$tmp/strict.log"
grep -q 'Script allocator contract must still be expanded to an ordinary strict-Zag allocator' \
    "$tmp/strict.log"

# Harden exposes both the stable policy name and packed policy id in its
# structured report and generated candidate.
cat >"$tmp/project/harden.zag" <<'ZAG'
script;
return 0;
ZAG
(cd "$tmp/project" && "$ZNC" harden harden.zag --format json \
    --script-allocator script_bounded_heap --no-zagd) >"$tmp/harden.json"
grep -q '"allocator_policy":{"value":"script_bounded_heap","id":2,"basis":"explicit"' \
    "$tmp/harden.json"
(cd "$tmp/project" && "$ZNC" harden harden.zag --output hardened.zag \
    --script-allocator script_bounded_heap --no-zagd >/dev/null)
grep -q '^// allocator policy: script_bounded_heap$' "$tmp/project/hardened.zag"
grep -q '^const __zag_hardened_allocator_policy_id: i32 = 2;$' \
    "$tmp/project/hardened.zag"

# A project may choose the bounded heap as its automatic Script default.
sed -i 's/allocator=script_process_arena/allocator=script_bounded_heap/' \
    "$tmp/project/.zagd.conf"
(cd "$tmp/project" && "$ZNC" explain harden.zag --format json --no-zagd) \
    >"$tmp/automatic.json"
grep -q '"allocator":{"value":"script_bounded_heap","basis":"derived"}' \
    "$tmp/automatic.json"
(cd "$tmp/project" && "$ZNC" harden.zag -o automatic --no-zagd \
    --no-analyze --no-foreground-cache >/dev/null)
"$tmp/project/automatic"

# Unsupported configuration fails closed, while an explicit supported CLI
# allocator overrides that project default before code generation.
sed -i 's/allocator=script_bounded_heap/allocator=unknown_allocator/' \
    "$tmp/project/.zagd.conf"
if (cd "$tmp/project" && "$ZNC" harden.zag -o rejected --no-zagd \
    --no-analyze --no-foreground-cache >"$tmp/rejected.log" 2>&1); then
    echo "unsupported Script allocator unexpectedly compiled" >&2
    exit 1
fi
grep -q 'supported allocator=script_process_arena or script_bounded_heap' \
    "$tmp/rejected.log"
(cd "$tmp/project" && "$ZNC" harden.zag -o overridden \
    --script-allocator script_bounded_heap --no-zagd --no-analyze \
    --no-foreground-cache >/dev/null)
"$tmp/project/overridden"

# The bounded heap charges its 16-byte ownership header, including zero-length
# requests, so repeated tiny allocations cannot bypass the Script limit. Its
# generated shutdown returns every tracked block to the native allocator.
mkdir -p "$tmp/runtime"
printf '%s\n' 'name = "script-bounded-heap-runtime"' 'edition = "2027"' \
    >"$tmp/runtime/zag.mod"
cat >"$tmp/runtime/main.zag" <<'ZAG'
extern fn _zag_script_context_init(limit:i64, capabilities:i64, execution_policy:i64) *opaque
extern fn _zag_script_context_shutdown(context:*opaque) void
extern fn _zag_script_alloc(context:*opaque, count:i64) *i8
extern fn _zag_script_alloc_used(context:*opaque) i64
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    unsafe {
        let context:*opaque = _zag_script_context_init(1048576, 7, 16843010);
        if (context == null as *opaque || _zag_allocator_live_bytes() != 128) { return 1; }
        let first:*i8 = _zag_script_alloc(context, 24);
        let empty:*i8 = _zag_script_alloc(context, 0);
        if (first == null as *i8 || empty == null as *i8) { return 2; }
        if (_zag_script_alloc_used(context) != 56) { return 3; }
        if (_zag_allocator_live_bytes() != 208) { return 4; }
        let words:*i64 = context as *i64;
        let overflow:*i8 = _zag_script_alloc(context, 9223372036854775807);
        if (overflow != null as *i8) { return 5; }
        if (_zag_script_alloc_used(context) != 56 || words[11] != 2 ||
            words[12] != 1 || _zag_allocator_live_bytes() != 208) { return 6; }
        _zag_script_context_shutdown(context);
        if (_zag_allocator_live_bytes() != 0) { return 7; }
    }
    return 0;
}
ZAG
(cd "$tmp/runtime" && "$ZNC" main.zag -o runtime --no-zagd --no-analyze \
    --no-foreground-cache >/dev/null)
"$tmp/runtime/runtime"

# Process-result handles must use the same policy-specific storage contract as
# ordinary Script allocations. Policy 2 charges its 16-byte ownership header,
# links the full block for shutdown, and commits used/count only after the
# complete 48-byte charge fits.
cat >"$tmp/runtime/process_result.zag" <<'ZAG'
extern fn _zag_script_context_init(limit:i64, capabilities:i64, execution_policy:i64) *opaque
extern fn _zag_script_context_shutdown(context:*opaque) void
extern fn _zag_script_alloc_used(context:*opaque) i64
extern fn _zag_script_process_result_abi_new(context:*opaque, status:i32, state:i32, output:[]u8) *opaque
extern fn _zag_process_result_status(handle:*opaque) i32
extern fn _zag_process_result_state(handle:*opaque) i32
extern fn _zag_process_result_output(handle:*opaque) []u8
extern fn _zag_allocator_allocation_count() i64
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    unsafe {
        let context:*opaque = _zag_script_context_init(64, 7, 16843010);
        if (context == null as *opaque || _zag_allocator_live_bytes() != 128) { return 1; }
        let words:*i64 = context as *i64;
        let result:*opaque = _zag_script_process_result_abi_new(
            context, 23, 2, "heap-result");
        if (result == null as *opaque) { return 2; }
        if (_zag_process_result_status(result) != 23 ||
            _zag_process_result_state(result) != 2 ||
            !@strEq(_zag_process_result_output(result), "heap-result")) { return 3; }
        if (_zag_script_alloc_used(context) != 48 || words[11] != 1 ||
            words[12] != 0 || _zag_allocator_allocation_count() != 2 ||
            _zag_allocator_live_bytes() != 192) { return 4; }
        let native_count_before:i64 = _zag_allocator_allocation_count();
        let rejected:*opaque = _zag_script_process_result_abi_new(
            context, 99, 3, "must-not-fit");
        if (rejected != null as *opaque) { return 5; }
        if (_zag_script_alloc_used(context) != 48 || words[11] != 1 ||
            words[12] != 1 ||
            _zag_allocator_allocation_count() != native_count_before ||
            _zag_allocator_live_bytes() != 192) { return 6; }
        _zag_script_context_shutdown(context);
        if (_zag_allocator_live_bytes() != 0) { return 7; }
    }
    return 0;
}
ZAG
(cd "$tmp/runtime" && "$ZNC" process_result.zag -o process_result \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null)
"$tmp/runtime/process_result"

cat >"$tmp/runtime/invalid.zag" <<'ZAG'
extern fn _zag_script_context_init(limit:i64, capabilities:i64, execution_policy:i64) *opaque
fn main() i32 {
    unsafe {
        let context:*opaque = _zag_script_context_init(1048576, 7, 16843011);
        if (context == null as *opaque) { return 2; }
    }
    return 0;
}
ZAG
(cd "$tmp/runtime" && "$ZNC" invalid.zag -o invalid --no-zagd --no-analyze \
    --no-foreground-cache >/dev/null)
if "$tmp/runtime/invalid" >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
    echo "unknown internal Script allocator policy unexpectedly ran" >&2
    exit 1
fi
grep -q 'zag runtime: invalid Script execution policy' "$tmp/invalid.err"

echo "script allocator policy: PASS"
