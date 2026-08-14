#!/usr/bin/env bash
# bootstrap.sh — rebuild the supported Zag v1 compiler seeds from source.
#
# Produces the compiler and its automatic, correctness-independent planner:
#   ./znc — native x86-64 compiler with GPU MLIR + WASM backends
#           (selfhost/native/znc.zag)
#
# ./znc reads Zag and writes a static x86-64 ELF, GPU MLIR, or WASM directly.
# No path invokes Python, C, Zig, cc, as, ld, or libc.
#
# Like every self-hosted language, you bootstrap from trusted
# seed binaries — you cannot compile from absolutely nothing.
set -e
set -o pipefail
cd "$(dirname "$0")"

bootstrap_seed=${ZAG_BOOTSTRAP_SEED:-./znc}
if [ ! -x "$bootstrap_seed" ]; then
    echo "bootstrap: native seed is missing or not executable: $bootstrap_seed" >&2
    echo "bootstrap: no non-Zag fallback exists; provide a trusted Zag-built seed." >&2
    exit 1
fi

echo "== native bootstrap: Zag -> x86-64 ELF (no cc/as/ld/libc) =="
echo "   trusted seed: $bootstrap_seed"
bootstrap_tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-bootstrap.XXXXXX")
bootstrap_active_pid=""
bootstrap_cleanup() {
    if [ -n "$bootstrap_active_pid" ]; then
        kill "$bootstrap_active_pid" 2>/dev/null || true
    fi
    rm -rf "$bootstrap_tmp"
}
bootstrap_signal() {
    bootstrap_cleanup
    exit 130
}
trap bootstrap_cleanup EXIT
trap bootstrap_signal HUP INT TERM

# Protect an interactive Linux workstation before starting any compiler stage.
# The guard is optional infrastructure, not a build dependency: hosts without a
# usable user cgroup still take the ordinary pure-Zag path. An explicit byte
# limit is fail-closed, while `ZAG_BOOTSTRAP_MEMORY_GUARD=off` disables the
# automatic 60%-of-RAM / 2-GiB-reserve policy.
bootstrap_memory_limit=${ZAG_BOOTSTRAP_MEMORY_MAX_BYTES:-}
bootstrap_swap_limit=${ZAG_BOOTSTRAP_SWAP_MAX_BYTES:-0}
bootstrap_guard=${ZAG_BOOTSTRAP_MEMORY_GUARD:-auto}
bootstrap_stage_timeout=${ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS:-3600}
case "$bootstrap_stage_timeout" in
    ''|*[!0-9]*|0)
        echo "bootstrap: invalid stage timeout: $bootstrap_stage_timeout" >&2
        exit 1
        ;;
esac
bootstrap_heartbeat=${ZAG_BOOTSTRAP_HEARTBEAT_SECONDS:-30}
case "$bootstrap_heartbeat" in
    ''|*[!0-9]*|0)
        echo "bootstrap: invalid heartbeat interval: $bootstrap_heartbeat" >&2
        exit 1
        ;;
esac
if ! command -v timeout >/dev/null 2>&1; then
    echo "bootstrap: timeout(1) is required for bounded compiler stages" >&2
    exit 1
fi
bootstrap_cgroup=0
case "$bootstrap_swap_limit" in
    ''|*[!0-9]*) echo "bootstrap: invalid swap limit: $bootstrap_swap_limit" >&2; exit 1 ;;
esac
if [ "$bootstrap_guard" != off ] && command -v systemd-run >/dev/null 2>&1 &&
   systemctl --user is-system-running >/dev/null 2>&1; then
    if [ -z "$bootstrap_memory_limit" ]; then
        bootstrap_total_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
        bootstrap_available_kib=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        bootstrap_physical_limit=$((bootstrap_total_kib * 1024 * 60 / 100))
        bootstrap_available_limit=$(((bootstrap_available_kib - 2097152) * 1024))
        bootstrap_memory_limit=$bootstrap_physical_limit
        if [ "$bootstrap_memory_limit" -gt "$bootstrap_available_limit" ]; then
            bootstrap_memory_limit=$bootstrap_available_limit
        fi
    fi
    case "$bootstrap_memory_limit" in
        ''|*[!0-9]*) echo "bootstrap: invalid memory limit: $bootstrap_memory_limit" >&2; exit 1 ;;
    esac
    if [ "$bootstrap_memory_limit" -lt 1073741824 ]; then
        echo "bootstrap: less than 1 GiB remains after the workstation reserve" >&2
        exit 1
    fi
    bootstrap_cgroup=1
    echo "   memory guard: cgroup memory max=$bootstrap_memory_limit bytes, swap max=$bootstrap_swap_limit bytes"
elif [ -n "$bootstrap_memory_limit" ] || [ "$bootstrap_swap_limit" -ne 0 ]; then
    echo "bootstrap: an explicit memory or swap limit requires a usable user systemd manager" >&2
    exit 1
else
    echo "   memory guard: unavailable; continuing without an OS cgroup"
fi

bootstrap_compile() {
    echo "   compiler stage: $* (timeout=${bootstrap_stage_timeout}s)"
    if [ "$bootstrap_cgroup" -eq 1 ]; then
        timeout --foreground --kill-after=30s "$bootstrap_stage_timeout" \
        systemd-run --user --quiet --wait --collect --pipe \
            -p Type=exec -p "WorkingDirectory=$PWD" \
            -p "MemoryMax=$bootstrap_memory_limit" \
            -p "MemorySwapMax=$bootstrap_swap_limit" \
            -p CPUWeight=1 -p IOWeight=1 -p Nice=10 \
            "$@" &
    else
        timeout --foreground --kill-after=30s "$bootstrap_stage_timeout" "$@" &
    fi
    bootstrap_active_pid=$!
    local started=$SECONDS
    bootstrap_process_running() {
        [ -r "/proc/$bootstrap_active_pid/stat" ] || return 1
        local state
        state=$(awk '{ print $3; exit }' "/proc/$bootstrap_active_pid/stat")
        [ "$state" != Z ]
    }
    while bootstrap_process_running; do
        sleep "$bootstrap_heartbeat"
        if bootstrap_process_running; then
            local rss="unavailable"
            if [ -r "/proc/$bootstrap_active_pid/status" ]; then
                rss=$(awk '/^VmRSS:/ { print $2 " KiB"; exit }' \
                    "/proc/$bootstrap_active_pid/status")
            fi
            echo "   compiler progress: elapsed=$((SECONDS - started))s rss=$rss"
        fi
    done
    if wait "$bootstrap_active_pid"; then
        bootstrap_active_pid=""
    else
        stage_rc=$?
        bootstrap_active_pid=""
        return "$stage_rc"
    fi
}

# A fixed-point comparison is meaningful only when every generation compiles
# the same source graph. Editors and parallel agents may legitimately change
# the checkout while a long bootstrap is running; detect that race explicitly
# instead of reporting it as compiler nondeterminism. This hashes source bytes
# only at the tooling boundary and does not participate in compilation.
bootstrap_source_fingerprint() {
    {
        printf '%s\0' zag.mod
        find selfhost std -type f -name '*.zag' -print0
    } | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{ print $1 }'
}

bootstrap_source_start=$(bootstrap_source_fingerprint)
bootstrap_assert_source_stable() {
    bootstrap_source_now=$(bootstrap_source_fingerprint)
    if [ "$bootstrap_source_now" != "$bootstrap_source_start" ]; then
        echo "bootstrap: source changed during bootstrap; discard mixed-snapshot stages and rerun" >&2
        exit 1
    fi
}

# A backend edit changes the compiler that performs the next rebuild. Build at
# least through two generated compilers, then continue for a bounded number of
# generations until two successive outputs are byte-identical. Semantic fixes
# can legitimately take an extra generation when the compiler source itself
# contains the construct being repaired. The bound keeps nondeterminism and
# non-converging miscompilations fail-closed.
bootstrap_compile "$bootstrap_seed" selfhost/native/znc.zag -o "$bootstrap_tmp/znc-stage1" \
    --no-analyze --no-foreground-cache --no-zagd
bootstrap_assert_source_stable
bootstrap_compile "$bootstrap_tmp/znc-stage1" selfhost/native/znc.zag \
    -o "$bootstrap_tmp/znc-stage2" --no-analyze --no-foreground-cache --no-zagd
bootstrap_assert_source_stable
bootstrap_prev="$bootstrap_tmp/znc-stage2"
bootstrap_fixed=""
bootstrap_stage=3
while [ "$bootstrap_stage" -le 6 ]; do
    bootstrap_next="$bootstrap_tmp/znc-stage$bootstrap_stage"
    bootstrap_compile "$bootstrap_prev" selfhost/native/znc.zag \
        -o "$bootstrap_next" --no-analyze --no-foreground-cache --no-zagd
    bootstrap_assert_source_stable
    if cmp -s "$bootstrap_prev" "$bootstrap_next"; then
        bootstrap_fixed="$bootstrap_next"
        break
    fi
    echo "   stage $((bootstrap_stage - 1)) and stage $bootstrap_stage differ; continuing toward fixpoint"
    bootstrap_prev="$bootstrap_next"
    bootstrap_stage=$((bootstrap_stage + 1))
done
if [ -z "$bootstrap_fixed" ]; then
    echo "bootstrap: self-hosting did not reach a byte-identical fixpoint" >&2
    exit 1
fi
# Build the daemon from the candidate fixed-point compiler before installing
# either generated artifact. A daemon failure must not leave a new compiler
# silently installed without its matching planner.
bootstrap_compile "$bootstrap_fixed" selfhost/zagd_daemon.zag -o "$bootstrap_tmp/zagd" \
    --no-analyze --no-zagd --no-foreground-cache
chmod +x "$bootstrap_tmp/zagd"
mv -f "$bootstrap_fixed" znc
echo "   ./znc rebuilt itself and reached a byte-identical fixpoint at stage $bootstrap_stage"
mv -f "$bootstrap_tmp/zagd" zagd
echo "   ./zagd built from selfhost/zagd_daemon.zag with the fixed-point compiler"

echo "== done. Supported compiler: ./znc; automatic planner: ./zagd =="
echo "   retired bootstrap implementations are available only through Git history."
