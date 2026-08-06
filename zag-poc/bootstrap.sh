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
cd "$(dirname "$0")"

if [ ! -x ./znc ]; then
    echo "bootstrap: native seed ./znc is missing; restore the committed seed." >&2
    echo "bootstrap: no non-Zag fallback exists; restore the committed znc seed." >&2
    exit 1
fi

echo "== native bootstrap: Zag -> x86-64 ELF (no cc/as/ld/libc) =="
bootstrap_tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-bootstrap.XXXXXX")
trap 'rm -rf "$bootstrap_tmp"' EXIT HUP INT TERM

# Protect an interactive Linux workstation before starting any compiler stage.
# The guard is optional infrastructure, not a build dependency: hosts without a
# usable user cgroup still take the ordinary pure-Zag path. An explicit byte
# limit is fail-closed, while `ZAG_BOOTSTRAP_MEMORY_GUARD=off` disables the
# automatic 60%-of-RAM / 2-GiB-reserve policy.
bootstrap_memory_limit=${ZAG_BOOTSTRAP_MEMORY_MAX_BYTES:-}
bootstrap_swap_limit=${ZAG_BOOTSTRAP_SWAP_MAX_BYTES:-0}
bootstrap_guard=${ZAG_BOOTSTRAP_MEMORY_GUARD:-auto}
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
    if [ "$bootstrap_cgroup" -eq 1 ]; then
        systemd-run --user --quiet --wait --collect --pipe \
            -p Type=exec -p "WorkingDirectory=$PWD" \
            -p "MemoryMax=$bootstrap_memory_limit" \
            -p "MemorySwapMax=$bootstrap_swap_limit" \
            -p CPUWeight=1 -p IOWeight=1 -p Nice=10 \
            "$@"
    else
        "$@"
    fi
}

# A backend edit changes the compiler that performs the next rebuild. Build at
# least through two generated compilers, then continue for a bounded number of
# generations until two successive outputs are byte-identical. Semantic fixes
# can legitimately take an extra generation when the compiler source itself
# contains the construct being repaired. The bound keeps nondeterminism and
# non-converging miscompilations fail-closed.
bootstrap_compile ./znc selfhost/native/znc.zag -o "$bootstrap_tmp/znc-stage1" \
    --no-analyze --no-foreground-cache --no-zagd
bootstrap_compile "$bootstrap_tmp/znc-stage1" selfhost/native/znc.zag \
    -o "$bootstrap_tmp/znc-stage2" --no-analyze --no-foreground-cache --no-zagd
bootstrap_prev="$bootstrap_tmp/znc-stage2"
bootstrap_fixed=""
bootstrap_stage=3
while [ "$bootstrap_stage" -le 6 ]; do
    bootstrap_next="$bootstrap_tmp/znc-stage$bootstrap_stage"
    bootstrap_compile "$bootstrap_prev" selfhost/native/znc.zag \
        -o "$bootstrap_next" --no-analyze --no-foreground-cache --no-zagd
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
mv -f "$bootstrap_fixed" znc
echo "   ./znc rebuilt itself and reached a byte-identical fixpoint at stage $bootstrap_stage"

bootstrap_compile ./znc selfhost/zagd_daemon.zag -o "$bootstrap_tmp/zagd" \
    --no-analyze --no-zagd --no-foreground-cache
chmod +x "$bootstrap_tmp/zagd"
mv -f "$bootstrap_tmp/zagd" zagd
echo "   ./zagd built from selfhost/zagd_daemon.zag with the fixed-point compiler"

echo "== done. Supported compiler: ./znc; automatic planner: ./zagd =="
echo "   retired bootstrap implementations are available only through Git history."
