#!/usr/bin/env bash
# bootstrap.sh — rebuild the supported Zag v1 compiler seeds from source.
#
# Produces the compiler and its automatic, correctness-independent planner.
# Linux x86-64 retains ./znc; ARM hosts use znc-<platform> so a native build
# never overwrites a seed for another kernel/architecture.
# Compiler source: selfhost/native/znc.zag.
#
# The selected native compiler reads Zag and writes native code, GPU MLIR, or
# WASM directly.
# No path invokes Python, C, Zig, cc, as, ld, or libc.
#
# Like every self-hosted language, you bootstrap from trusted
# seed binaries — you cannot compile from absolutely nothing.
set -e
set -o pipefail
cd "$(dirname "$0")"
. ./tests/portable.sh

bootstrap_host_system=$(uname -s)
bootstrap_host_machine=$(uname -m)
bootstrap_target_args=()
case "$bootstrap_host_system:$bootstrap_host_machine" in
    Darwin:arm64)
        bootstrap_platform=macos-arm64
        bootstrap_target_args=(--target macos-arm64)
        ;;
    Linux:x86_64|Linux:amd64)
        bootstrap_platform=linux-x86_64
        ;;
    Linux:aarch64|Linux:arm64)
        bootstrap_platform=linux-arm64
        bootstrap_target_args=(--target arm64)
        ;;
    *)
        echo "bootstrap: unsupported native host: $bootstrap_host_system $bootstrap_host_machine" >&2
        exit 1
        ;;
esac

# Linux x86-64 keeps the historical ./znc location. Other hosts write a named
# generated compiler so bootstrapping never replaces the tracked Linux seed.
case "$bootstrap_platform" in
    linux-x86_64)
        bootstrap_default_output=./znc
        bootstrap_default_daemon_output=./zagd
        ;;
    *)
        bootstrap_default_output="./znc-$bootstrap_platform"
        bootstrap_default_daemon_output="./zagd-$bootstrap_platform"
        ;;
esac
bootstrap_output=${ZAG_BOOTSTRAP_OUTPUT:-$bootstrap_default_output}
bootstrap_daemon_output=${ZAG_BOOTSTRAP_DAEMON_OUTPUT:-$bootstrap_default_daemon_output}

bootstrap_legacy_seed_compatible() {
    zag_assert_native_executable "$1"
}

if [ -n "${ZAG_BOOTSTRAP_SEED:-}" ]; then
    bootstrap_seed=$ZAG_BOOTSTRAP_SEED
else
    bootstrap_seed=""
    for bootstrap_candidate in \
        "$bootstrap_output" \
        "./seeds/$bootstrap_platform/znc" \
        ./znc; do
        if [ -x "$bootstrap_candidate" ] &&
           bootstrap_legacy_seed_compatible "$bootstrap_candidate"; then
            bootstrap_seed=$bootstrap_candidate
            break
        fi
    done
fi
if [ ! -x "$bootstrap_seed" ]; then
    echo "bootstrap: native seed is missing or not executable: $bootstrap_seed" >&2
    echo "bootstrap: provide a trusted $bootstrap_platform Zag-built seed via ZAG_BOOTSTRAP_SEED." >&2
    exit 1
fi
if ! bootstrap_legacy_seed_compatible "$bootstrap_seed"; then
    echo "bootstrap: seed does not match exact host architecture: $bootstrap_seed" >&2
    exit 1
fi

echo "== native bootstrap: Zag -> $bootstrap_platform (no cc/as/ld/libc) =="
echo "   trusted seed: $bootstrap_seed"
echo "   generated compiler: $bootstrap_output"
echo "   generated planner: $bootstrap_daemon_output"
bootstrap_tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-bootstrap.XXXXXX")
bootstrap_active_pid=""
bootstrap_active_pgid=""
bootstrap_cleanup() {
    if [ -n "$bootstrap_active_pid" ]; then
        zag_terminate_process_tree "$bootstrap_active_pid" "$bootstrap_active_pgid"
        wait "$bootstrap_active_pid" 2>/dev/null || true
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
bootstrap_cgroup=0
case "$bootstrap_swap_limit" in
    ''|*[!0-9]*) echo "bootstrap: invalid swap limit: $bootstrap_swap_limit" >&2; exit 1 ;;
esac
if [ "$bootstrap_host_system" = Linux ] && [ "$bootstrap_guard" != off ] &&
   command -v systemd-run >/dev/null 2>&1 &&
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
    echo "   memory guard: OS cgroup unavailable; continuing with bounded stages and RSS reporting"
fi

bootstrap_compile() {
    echo "   compiler stage: $* (timeout=${bootstrap_stage_timeout}s)"
    if [ "$bootstrap_cgroup" -eq 1 ]; then
        zag_start_isolated systemd-run --user --quiet --wait --collect --pipe \
            -p Type=exec -p "WorkingDirectory=$PWD" \
            -p "MemoryMax=$bootstrap_memory_limit" \
            -p "MemorySwapMax=$bootstrap_swap_limit" \
            -p CPUWeight=1 -p IOWeight=1 -p Nice=10 \
            "$@"
    else
        zag_start_isolated "$@"
    fi
    bootstrap_active_pid=$ZAG_ISOLATED_PID
    bootstrap_active_pgid=$ZAG_ISOLATED_PGID
    local started=$SECONDS
    local next_heartbeat=$((started + bootstrap_heartbeat))
    local timed_out=0
    bootstrap_process_running() {
        local state
        state=$(ps -o stat= -p "$bootstrap_active_pid" 2>/dev/null | awk 'NF { print $1; exit }')
        [ -n "$state" ] && [ "${state#Z}" = "$state" ]
    }
    while bootstrap_process_running; do
        sleep 1
        local elapsed=$((SECONDS - started))
        if [ "$elapsed" -ge "$bootstrap_stage_timeout" ]; then
            echo "bootstrap: compiler stage exceeded ${bootstrap_stage_timeout}s; terminating" >&2
            zag_terminate_process_tree "$bootstrap_active_pid" "$bootstrap_active_pgid"
            timed_out=1
            break
        fi
        if [ "$SECONDS" -ge "$next_heartbeat" ] && bootstrap_process_running; then
            local rss="unavailable"
            local rss_kib
            rss_kib=$(ps -o rss= -p "$bootstrap_active_pid" 2>/dev/null | awk 'NF { print $1; exit }')
            if [ -n "$rss_kib" ]; then
                rss="$rss_kib KiB"
            fi
            echo "   compiler progress: elapsed=${elapsed}s rss=$rss"
            next_heartbeat=$((SECONDS + bootstrap_heartbeat))
        fi
    done
    if wait "$bootstrap_active_pid" && [ "$timed_out" -eq 0 ]; then
        bootstrap_active_pid=""
        bootstrap_active_pgid=""
    else
        local stage_rc=$?
        bootstrap_active_pid=""
        bootstrap_active_pgid=""
        if [ "$timed_out" -eq 1 ]; then
            return 124
        fi
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
    } | zag_sort_nul | while IFS= read -r -d '' bootstrap_source_path; do
        bootstrap_source_digest=$(zag_sha256_file "$bootstrap_source_path") || exit 1
        printf '%s\0%s\0' "$bootstrap_source_digest" "$bootstrap_source_path"
    done | zag_sha256_stream
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
    "${bootstrap_target_args[@]}" --no-analyze --no-foreground-cache --no-zagd
bootstrap_assert_source_stable
bootstrap_compile "$bootstrap_tmp/znc-stage1" selfhost/native/znc.zag \
    -o "$bootstrap_tmp/znc-stage2" "${bootstrap_target_args[@]}" \
    --no-analyze --no-foreground-cache --no-zagd
bootstrap_assert_source_stable
bootstrap_prev="$bootstrap_tmp/znc-stage2"
bootstrap_fixed=""
bootstrap_stage=3
while [ "$bootstrap_stage" -le 6 ]; do
    bootstrap_next="$bootstrap_tmp/znc-stage$bootstrap_stage"
    bootstrap_compile "$bootstrap_prev" selfhost/native/znc.zag \
        -o "$bootstrap_next" "${bootstrap_target_args[@]}" \
        --no-analyze --no-foreground-cache --no-zagd
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
zagd_source=selfhost/zagd_daemon.zag
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    zagd_source=selfhost/zagd_macos_daemon.zag
fi
# Build the daemon from the candidate fixed-point compiler before installing
# either generated artifact. A daemon failure must not leave a new compiler
# silently installed without its matching planner.
bootstrap_compile "$bootstrap_fixed" "$zagd_source" -o "$bootstrap_tmp/zagd" \
    "${bootstrap_target_args[@]}" --no-analyze --no-zagd --no-foreground-cache
chmod +x "$bootstrap_tmp/zagd"
mkdir -p "$(dirname "$bootstrap_output")" "$(dirname "$bootstrap_daemon_output")"
mv -f "$bootstrap_fixed" "$bootstrap_output"
echo "   $bootstrap_output rebuilt itself and reached a byte-identical fixpoint at stage $bootstrap_stage"
mv -f "$bootstrap_tmp/zagd" "$bootstrap_daemon_output"
echo "   $bootstrap_daemon_output built from $zagd_source with the fixed-point compiler"

echo "== done. Supported compiler: $bootstrap_output; automatic planner: $bootstrap_daemon_output =="
echo "   retired bootstrap implementations are available only through Git history."
