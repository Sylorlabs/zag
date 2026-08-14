#!/usr/bin/env bash
# Release gate for the supported Zag v1 compiler path.
# Proves that a native self-rebuild and a user build succeed even when common
# C toolchain entry points are poisoned, then checks the outputs are static ELF.
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
tmp="${TMPDIR:-/tmp}/zag-native-authority.$$"

# A long native rebuild is valid evidence only for one immutable compiler
# source graph.  Bind the authority run to the same selfhost/std/zag.mod bytes
# used by the independent reproducibility gate; an editor or concurrent agent
# changing the checkout must invalidate the result rather than mix snapshots.
source_fingerprint() {
    {
        find selfhost std -type f -name '*.zag' -print0
        printf '%s\0' zag.mod
    } | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{ print $1 }'
}
source_snapshot=$(source_fingerprint)
echo "  source snapshot sha256=$source_snapshot"
assert_source_stable() {
    current_source=$(source_fingerprint)
    if [ "$current_source" != "$source_snapshot" ]; then
        echo "native authority: source changed during rebuild; discard mixed-snapshot evidence" >&2
        echo "  before=$source_snapshot" >&2
        echo "  after =$current_source" >&2
        exit 1
    fi
}

authority_pid=""
authority_cleanup() {
    if [ -n "$authority_pid" ]; then
        kill "$authority_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
authority_signal() {
    authority_cleanup
    exit 130
}
trap authority_cleanup EXIT
trap authority_signal HUP INT TERM
mkdir -p "$tmp/bin"

authority_limit=${ZAG_SELFHOST_MEMORY_MAX_BYTES:-}
authority_swap=${ZAG_SELFHOST_SWAP_MAX_BYTES:-0}
authority_guard=0
case "$authority_swap" in ''|*[!0-9]*) echo "native authority: invalid swap guard" >&2; exit 1;; esac
if command -v systemd-run >/dev/null 2>&1 &&
   systemctl --user is-system-running >/dev/null 2>&1; then
    if [ -z "$authority_limit" ]; then
        authority_total_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
        authority_available_kib=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        authority_physical_limit=$((authority_total_kib * 1024 * 60 / 100))
        authority_available_limit=$(((authority_available_kib - 2097152) * 1024))
        authority_limit=$authority_physical_limit
        if [ "$authority_limit" -gt "$authority_available_limit" ]; then
            authority_limit=$authority_available_limit
        fi
    fi
    case "$authority_limit" in ''|*[!0-9]*) echo "native authority: invalid memory guard" >&2; exit 1;; esac
    [ "$authority_limit" -ge 1073741824 ] || {
        echo "native authority: refusing self-rebuild with less than 1 GiB after reserve" >&2
        exit 1
    }
    authority_guard=1
    echo "  memory guard: cgroup memory max=$authority_limit bytes, swap max=$authority_swap bytes"
elif [ -n "$authority_limit" ] || [ "$authority_swap" -ne 0 ]; then
    echo "native authority: explicit memory or swap limit requires a user systemd manager" >&2
    exit 1
fi

authority_rebuild() {
    authority_command=(./znc selfhost/native/znc.zag
        -o "$tmp/znc-stage2" --no-analyze --no-zagd --no-foreground-cache)
    if [ "$authority_guard" -eq 1 ]; then
        timeout --foreground "$authority_timeout" systemd-run --user --quiet --wait --collect --pipe \
            -p Type=exec -p "WorkingDirectory=$PWD" \
            -p "MemoryMax=$authority_limit" -p "MemorySwapMax=$authority_swap" \
            -p CPUWeight=1 -p IOWeight=1 -p Nice=10 \
            /usr/bin/env "PATH=$tmp/bin:$PATH" "${authority_command[@]}"
    else
        timeout --foreground "$authority_timeout" env "PATH=$tmp/bin:$PATH" "${authority_command[@]}"
    fi
}

authority_timeout=${ZAG_SELFHOST_TIMEOUT_SECONDS:-900}
case "$authority_timeout" in
    ''|*[!0-9]*) echo "native authority: invalid rebuild timeout" >&2; exit 1;;
esac
[ "$authority_timeout" -ge 1 ] || {
    echo "native authority: rebuild timeout must be at least one second" >&2
    exit 1
}
authority_heartbeat=${ZAG_SELFHOST_HEARTBEAT_SECONDS:-30}
case "$authority_heartbeat" in
    ''|*[!0-9]*|0) echo "native authority: invalid heartbeat interval" >&2; exit 1;;
esac

bash tests/check_pure_zag_tree.sh

for tool in cc gcc clang as ld; do
    printf '#!/bin/sh\necho "forbidden host tool invoked: %s" >&2\nexit 97\n' "$tool" > "$tmp/bin/$tool"
    chmod +x "$tmp/bin/$tool"
done

check_static_elf() {
    artifact=$1
    label=$2
    if file "$artifact" | grep -q 'ELF 64-bit.*statically linked' && \
       ! readelf -l "$artifact" 2>/dev/null | grep -q 'INTERP' && \
       ! readelf -d "$artifact" 2>/dev/null | grep -q 'NEEDED'; then
        echo "  ok  $label is static ELF with no interpreter or shared libraries"
        pass=$((pass + 1))
    else
        echo "  XX  $label is not a self-contained static ELF"
        fail=$((fail + 1))
    fi
}

echo "── native authority: poison cc/gcc/clang/as/ld ──"
authority_rebuild >"$tmp/rebuild.log" 2>&1 &
authority_pid=$!
authority_started=$SECONDS
authority_process_running() {
    [ -r "/proc/$authority_pid/stat" ] || return 1
    authority_state=$(awk '{ print $3; exit }' "/proc/$authority_pid/stat")
    [ "$authority_state" != Z ]
}
while authority_process_running; do
    sleep "$authority_heartbeat"
    if authority_process_running; then
        authority_rss="unavailable"
        if [ -r "/proc/$authority_pid/status" ]; then
            authority_rss=$(awk '/^VmRSS:/ { print $2 " KiB"; exit }' \
                "/proc/$authority_pid/status")
        fi
        echo "  progress native self-rebuild: elapsed=$((SECONDS - authority_started))s rss=$authority_rss"
    fi
done
if wait "$authority_pid"; then
    authority_pid=""
    assert_source_stable
    echo "  ok  native seed rebuilt znc without a host C toolchain"
    pass=$((pass + 1))
    check_static_elf "$tmp/znc-stage2" "stage-2 compiler"
else
    authority_rc=$?
    authority_pid=""
    if [ "$authority_rc" -eq 124 ]; then
        echo "  XX  native self-rebuild timed out after ${authority_timeout}s"
    else
        echo "  XX  native self-rebuild failed (rc=$authority_rc)"
    fi
    if [ -f "$tmp/rebuild.log" ]; then
        sed -n '1,20p' "$tmp/rebuild.log"
    else
        echo "  (rebuild log unavailable)"
    fi
    fail=$((fail + 1))
fi

printf 'fn main() i32 { print_int(42); return 0; }\n' > "$tmp/smoke.zag"

# PATH poisoning above already proves that the one required self-rebuild cannot
# reach a host toolchain. Trace a tiny native build instead of repeating the
# largest allocation in this gate solely to count execve calls.
if command -v strace >/dev/null 2>&1; then
    if PATH="$tmp/bin:$PATH" strace -f -e trace=execve -o "$tmp/exec.log" \
       ./znc "$tmp/smoke.zag" -o "$tmp/smoke-traced" --no-analyze --no-zagd \
       --no-foreground-cache >"$tmp/traced.log" 2>&1 && \
       [ "$(grep -c 'execve(' "$tmp/exec.log")" -eq 1 ]; then
        echo "  ok  syscall trace shows no child tool execution"
        pass=$((pass + 1))
    elif grep -q 'Operation not permitted' "$tmp/traced.log"; then
        echo "  --  ptrace blocked; PATH poisoning remains enforced"
    else
        echo "  XX  native compiler executed a child process"
        cat "$tmp/exec.log" 2>/dev/null || true
        fail=$((fail + 1))
    fi
else
    echo "  --  strace unavailable; PATH poisoning remains enforced"
fi

if [ -x "$tmp/znc-stage2" ]; then
    if PATH="$tmp/bin:$PATH" "$tmp/znc-stage2" "$tmp/smoke.zag" -o "$tmp/smoke" \
       --no-zagd --no-foreground-cache >"$tmp/smoke.log" 2>&1 && \
       [ "$("$tmp/smoke")" = 42 ]; then
        echo "  ok  stage-2 compiler built and ran a Zag program"
        pass=$((pass + 1))
        check_static_elf "$tmp/smoke" "user program"
    else
        echo "  XX  stage-2 compiler could not build/run the smoke program"
        sed -n '1,20p' "$tmp/smoke.log"
        fail=$((fail + 1))
    fi
else
    echo "  --  smoke build skipped because the stage-2 compiler was not produced"
fi

if ! grep -E -n '^[[:space:]]*(cc|gcc|clang|as|ld)[[:space:]]|\./zagc([[:space:]]|$)' \
    bootstrap.sh tests/run_native.sh >"$tmp/refs"; then
    echo "  ok  supported bootstrap and native suite contain no host or legacy compiler invocation"
    pass=$((pass + 1))
else
    echo "  XX  supported workflow names a host compiler command"
    cat "$tmp/refs"
    fail=$((fail + 1))
fi

if grep -E -q '^bootstrap_compile .* selfhost/native/znc\.zag ' bootstrap.sh &&
   grep -E -q 'bootstrap_stage=3' bootstrap.sh &&
   grep -E -q 'while \[ "\$bootstrap_stage" -le 6 \]' bootstrap.sh &&
   grep -E -q 'cmp -s "\$bootstrap_prev" "\$bootstrap_next"' bootstrap.sh &&
   grep -E -q 'self-hosting did not reach a byte-identical fixpoint' bootstrap.sh &&
   awk '/^bootstrap_compile "\\$bootstrap_fixed" selfhost\/zagd_daemon\\.zag/{daemon=NR} /^mv -f "\\$bootstrap_fixed" znc$/{install=NR} END { exit !(daemon > 0 && install > daemon) }' bootstrap.sh &&
   [ "$(grep -E -c -- '--no-analyze --no-foreground-cache --no-zagd' bootstrap.sh)" -ge 3 ] &&
   grep -E -q '^bootstrap: selfhost/native/znc\.zag selfhost/zagd_daemon\.zag$' Makefile &&
   grep -E -q '^znc: bootstrap$' Makefile &&
   grep -E -q '^zagd: bootstrap$' Makefile &&
   grep -E -q -- '--no-analyze --no-zagd --no-foreground-cache' \
       tests/check_native_bootstrap_repro.sh &&
   grep -E -q -- '--no-analyze --no-zagd --no-foreground-cache' \
       tests/run_native_memory_regression.sh; then
    echo "  ok  supported self-rebuilds require a fixpoint and disable advisory cache and daemon"
    pass=$((pass + 1))
else
    echo "  XX  supported self-rebuild may skip its fixpoint or use advisory cache/daemon"
    fail=$((fail + 1))
fi

echo "── native authority: ABI/layout release gate ──"
if [ -x "$tmp/znc-stage2" ]; then
    if ZNC="$tmp/znc-stage2" bash tests/run_abi_layout.sh >"$tmp/abi.log" 2>&1; then
        echo "  ok  ABI/layout suite passed on stage-2 compiler"
        pass=$((pass + 1))
    else
        echo "  XX  ABI/layout suite failed on stage-2 compiler"
        sed -n '1,30p' "$tmp/abi.log"
        fail=$((fail + 1))
    fi
else
    echo "  --  ABI/layout suite skipped because the stage-2 compiler was not produced"
fi

assert_source_stable
echo "  source snapshot unchanged sha256=$source_snapshot"
echo "════ native-authority pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
