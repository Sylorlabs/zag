#!/usr/bin/env bash
# Focused native gate for bounded epoll/eventfd, SPSC channels, and the
# join-only async-worker reference app.  It deliberately makes no broader
# async/await, cancellation, scheduler, MPMC, or race-freedom claim.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-linux-concurrency-services.XXXXXX)
cleanup() {
    if [ "${KEEP_TMP:-0}" = 1 ]; then
        echo "kept $tmp" >&2
    else
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT
pass=0
expected_pass=4
release_evidence=${ZAGSCRIPT_RELEASE_EVIDENCE:-0}
case "$release_evidence" in
    0|1) ;;
    *) echo 'ZAGSCRIPT_RELEASE_EVIDENCE must be 0 or 1' >&2; exit 2 ;;
esac

project="$tmp/project"
mkdir -p "$project"
printf '%s\n' \
    'name = "linux-concurrency-services"' \
    'version = "0"' \
    'edition = "2027"' >"$project/zag.mod"

build() {
    local source=$1
    local output=$2
    cp "$source" "$project/main.zag"
    (cd "$project" && "$compiler" main.zag \
        --safety=checked --analyze-strict --no-zagd --no-foreground-cache \
        -o "$output") >"$output.build.log" 2>&1
    test -x "$output"
}

assert_static_x86_64() {
    local app=$1
    test -x "$app"
    file "$app" | grep -q 'ELF 64-bit LSB executable, x86-64'
    file "$app" | grep -q 'statically linked'
    readelf -h "$app" >"$app.header"
    grep -Eq 'Class:[[:space:]]+ELF64' "$app.header"
    grep -Eq 'Type:[[:space:]]+EXEC' "$app.header"
    grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$app.header"
    if readelf -l "$app" | grep -q 'INTERP'; then
        echo "$app unexpectedly has a dynamic interpreter" >&2
        exit 1
    fi
    if readelf -d "$app" 2>/dev/null | grep -q 'NEEDED'; then
        echo "$app unexpectedly has a dynamic dependency" >&2
        exit 1
    fi
}

build "$root/tests/linux_epoll_channel.zag" "$tmp/contracts"
assert_static_x86_64 "$tmp/contracts"
timeout 10 "$tmp/contracts" >"$tmp/contracts.out" 2>"$tmp/contracts.err"
test ! -s "$tmp/contracts.out"
test ! -s "$tmp/contracts.err"
pass=$((pass + 1))

build "$root/tests/linux_epoll_channel.zag" "$tmp/contracts-second"
assert_static_x86_64 "$tmp/contracts-second"
cmp -s "$tmp/contracts" "$tmp/contracts-second"
timeout 10 "$tmp/contracts-second" \
    >"$tmp/contracts-second.out" 2>"$tmp/contracts-second.err"
test ! -s "$tmp/contracts-second.out"
test ! -s "$tmp/contracts-second.err"
pass=$((pass + 1))

build "$root/tests/reference_apps/async_worker/main.zag" "$tmp/worker"
assert_static_x86_64 "$tmp/worker"
timeout 10 "$tmp/worker" >"$tmp/worker.out" 2>"$tmp/worker.err"
printf '%s\n' 'async-worker jobs=8 result_sum=212' >"$tmp/expected.out"
cmp -s "$tmp/expected.out" "$tmp/worker.out"
test ! -s "$tmp/worker.err"
pass=$((pass + 1))

build "$root/tests/reference_apps/async_worker/main.zag" "$tmp/worker-second"
assert_static_x86_64 "$tmp/worker-second"
cmp -s "$tmp/worker" "$tmp/worker-second"
timeout 10 "$tmp/worker-second" \
    >"$tmp/worker-second.out" 2>"$tmp/worker-second.err"
cmp -s "$tmp/expected.out" "$tmp/worker-second.out"
test ! -s "$tmp/worker-second.err"
pass=$((pass + 1))

trace_available=0
if command -v strace >/dev/null 2>&1 &&
   timeout 5 strace -qq -e trace=none -o "$tmp/strace-probe" /bin/true \
       >/dev/null 2>&1; then
    trace_available=1
fi
if [ "$trace_available" -eq 1 ]; then
    timeout 10 strace -f -qq \
        -e trace=epoll_create1,epoll_ctl,epoll_wait,eventfd2,read,write,close,futex,mmap,munmap,clone \
        -o "$tmp/contracts.strace" "$tmp/contracts" \
        >"$tmp/strace-contracts.out" 2>"$tmp/strace-contracts.err"
    test ! -s "$tmp/strace-contracts.out"
    test ! -s "$tmp/strace-contracts.err"
    grep -q 'epoll_create1(EPOLL_CLOEXEC)' "$tmp/contracts.strace"
    grep -q 'eventfd2(0, EFD_CLOEXEC|EFD_NONBLOCK)' "$tmp/contracts.strace"
    grep -q 'epoll_ctl(.*EPOLL_CTL_ADD' "$tmp/contracts.strace"
    grep -Eq 'epoll_wait\(.*40\)[[:space:]]+= 0' "$tmp/contracts.strace"
    test "$(grep -c 'epoll_wait(' "$tmp/contracts.strace")" -eq 3
    grep -q 'FUTEX_WAIT' "$tmp/contracts.strace"
    test "$(grep -c 'FUTEX_WAIT' "$tmp/contracts.strace")" -eq 1
    grep -q 'ETIMEDOUT' "$tmp/contracts.strace"

    timeout 10 strace -f -qq \
        -e trace=clone,futex,mmap,munmap \
        -o "$tmp/worker.strace" "$tmp/worker" \
        >"$tmp/strace-worker.out" 2>"$tmp/strace-worker.err"
    cmp -s "$tmp/expected.out" "$tmp/strace-worker.out"
    test ! -s "$tmp/strace-worker.err"
    test "$(grep -c 'clone(' "$tmp/worker.strace")" -eq 1
    grep -q 'FUTEX_WAIT' "$tmp/worker.strace"
    if grep -q 'ETIMEDOUT' "$tmp/worker.strace"; then
        echo 'normal async worker hit a channel timeout' >&2
        exit 1
    fi
    trace_status=evidence-pass
elif [ "$release_evidence" -eq 1 ]; then
    echo 'Linux concurrency release evidence requires strace kernel witnesses' >&2
    exit 2
else
    trace_status=portable-skip
fi

test "$pass" -eq "$expected_pass"
printf 'Linux concurrency services: pass=%d fail=0 trace=%s\n' \
    "$pass" "$trace_status"
