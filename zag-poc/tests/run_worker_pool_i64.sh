#!/usr/bin/env bash
# Focused authority for the bounded synchronous Linux/x86-64 worker pool.
# This proves atomic index claiming, explicit joins, bounds, reproducibility,
# and allocator balance. Its cancellation case is cooperative and one-shot;
# it does not claim async/await, MPMC, scheduler integration, or general
# race-freedom inference.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-worker-pool-i64.XXXXXX)
cleanup() {
    if [ "${KEEP_TMP:-0}" = 1 ]; then
        echo "kept $tmp" >&2
    else
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT

project="$tmp/project"
mkdir -p "$project"
printf '%s\n' \
    'name = "worker-pool-i64"' \
    'version = "0"' \
    'edition = "2027"' >"$project/zag.mod"

build() {
    local out=$1
    cp "$root/tests/worker_pool_i64.zag" "$project/main.zag"
    (cd "$project" && "$compiler" main.zag \
        --safety=checked --analyze-strict --no-zagd --no-foreground-cache \
        -o "$out") >"$out.build.log" 2>&1
    test -x "$out"
    file "$out" | grep -q 'ELF 64-bit LSB executable, x86-64'
    file "$out" | grep -q 'statically linked'
    ! readelf -l "$out" | grep -q 'INTERP'
    ! readelf -d "$out" 2>/dev/null | grep -q 'NEEDED'
}

build "$tmp/worker-pool"
timeout 10 "$tmp/worker-pool" >"$tmp/out" 2>"$tmp/err"
printf '%s\n' 'worker-pool jobs=16 workers=4 cancelled=1 total=1512' >"$tmp/expected"
cmp -s "$tmp/expected" "$tmp/out"
test ! -s "$tmp/err"

build "$tmp/worker-pool-second"
cmp -s "$tmp/worker-pool" "$tmp/worker-pool-second"
timeout 10 "$tmp/worker-pool-second" >"$tmp/out-second" 2>"$tmp/err-second"
cmp -s "$tmp/expected" "$tmp/out-second"
test ! -s "$tmp/err-second"

if command -v strace >/dev/null 2>&1 &&
   timeout 5 strace -qq -e trace=none -o "$tmp/strace-probe" /bin/true \
       >/dev/null 2>&1; then
    timeout 10 strace -f -qq -e trace=clone,futex,mmap,munmap \
        -o "$tmp/worker.strace" "$tmp/worker-pool" >"$tmp/trace-out" 2>"$tmp/trace-err"
    cmp -s "$tmp/expected" "$tmp/trace-out"
    test ! -s "$tmp/trace-err"
    test "$(grep -c 'clone(' "$tmp/worker.strace")" -eq 8
    test "$(grep -c 'FUTEX_WAIT' "$tmp/worker.strace")" -ge 1
    trace_status=pass
else
    trace_status=portable-skip
fi

printf 'worker pool i64: pass (bounded atomic pool, static reproducible ELF, trace=%s)\n' \
    "$trace_status"
