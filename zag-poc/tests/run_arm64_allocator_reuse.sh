#!/usr/bin/env bash
# Cross-native ARM64 allocator evidence: exact size-class pointer reuse,
# realloc reclamation, dedicated large unmapping, and bounded maximum RSS.
set -euo pipefail

cd "$(dirname "$0")/.."
host_system=$(uname -s)
host_machine=$(uname -m)
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-arm64-allocator.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

target_args=()
compiler_target_args=()
# Keep this non-empty for Bash 3.2 with `set -u` (the macOS system Bash treats
# expansion of an empty array as an unbound variable).
run_prefix=(env)
case "$host_system:$host_machine" in
    Darwin:arm64)
        target_args=(--target macos-arm64)
        compiler_target_args=(--target macos-arm64)
        ;;
    Linux:aarch64|Linux:arm64)
        target_args=(--target arm64)
        compiler_target_args=(--target arm64)
        ;;
    Linux:x86_64|Linux:amd64)
        target_args=(--target arm64)
        qemu=${QEMU:-qemu-aarch64-static}
        if ! command -v "$qemu" >/dev/null 2>&1; then
            echo "ARM64 allocator reuse: $qemu is required on x86-64 Linux" >&2
            exit 2
        fi
        run_prefix=("$qemu")
        ;;
    *)
        echo "ARM64 allocator reuse: unsupported host $host_system $host_machine" >&2
        exit 2
        ;;
esac

compiler=${ZNC:-}
if [ -z "$compiler" ]; then
    seed=${ZAG_ARM64_ALLOCATOR_SEED:-}
    if [ -z "$seed" ]; then
        for candidate in ./znc-macos-arm64 ./znc-linux-arm64 ./znc; do
            if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
                seed=$candidate
                break
            fi
        done
    fi
    if [ -z "$seed" ] || [ ! -x "$seed" ]; then
        echo 'ARM64 allocator reuse: set ZNC or ZAG_ARM64_ALLOCATOR_SEED' >&2
        exit 2
    fi
    "$seed" selfhost/native/znc.zag "${compiler_target_args[@]}" \
        --no-zagd --no-analyze --no-foreground-cache -o "$work/znc-isolated"
    compiler=$work/znc-isolated
fi

"$compiler" tests/arm64_allocator_reuse.zag "${target_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$work/allocator-reuse"

if [ "$host_system" = Darwin ]; then
    file "$work/allocator-reuse" | grep -q 'Mach-O 64-bit executable arm64'
    codesign --verify --deep --strict "$work/allocator-reuse"
else
    file "$work/allocator-reuse" | grep -q 'ELF 64-bit LSB executable, ARM aarch64'
fi

rss_kind=unavailable
rss_value=0
set +e
if [ -x /usr/bin/time ] && [ "$host_system" = Darwin ]; then
    /usr/bin/time -l "${run_prefix[@]}" "$work/allocator-reuse" \
        >"$work/stdout" 2>"$work/metrics"
    status=$?
    rss_value=$(awk '/maximum resident set size/ { print $1; exit }' "$work/metrics")
    rss_kind=bytes
elif [ -x /usr/bin/time ] && /usr/bin/time -f '%M' true >/dev/null 2>&1; then
    /usr/bin/time -f 'ZAG_MAX_RSS_KIB=%M' "${run_prefix[@]}" \
        "$work/allocator-reuse" >"$work/stdout" 2>"$work/metrics"
    status=$?
    rss_value=$(sed -n 's/^ZAG_MAX_RSS_KIB=//p' "$work/metrics" | tail -n 1)
    rss_kind=kib
else
    "${run_prefix[@]}" "$work/allocator-reuse" \
        >"$work/stdout" 2>"$work/metrics"
    status=$?
fi
set -e

if [ "$status" -ne 42 ]; then
    echo "ARM64 allocator reuse: fixture exited $status" >&2
    sed -n '1,16p' "$work/stdout" >&2
    sed -n '1,24p' "$work/metrics" >&2
    exit 1
fi
if [ -s "$work/stdout" ]; then
    echo 'ARM64 allocator reuse: fixture emitted unexpected stdout' >&2
    sed -n '1,16p' "$work/stdout" >&2
    exit 1
fi

# The fixture touches 384 MiB across sequential dedicated allocations. A
# retained-bump implementation therefore exceeds this generous 192 MiB bound;
# a real unmap implementation stays near one 8 MiB live mapping (plus runner
# overhead, including qemu-user where applicable).
case "$rss_kind" in
    bytes)
        if [ -z "$rss_value" ] || [ "$rss_value" -gt 201326592 ]; then
            echo "ARM64 allocator reuse: maximum RSS ${rss_value:-unknown} bytes exceeds 192 MiB" >&2
            exit 1
        fi
        ;;
    kib)
        if [ -z "$rss_value" ] || [ "$rss_value" -gt 196608 ]; then
            echo "ARM64 allocator reuse: maximum RSS ${rss_value:-unknown} KiB exceeds 192 MiB" >&2
            exit 1
        fi
        ;;
esac

echo "ARM64 allocator reuse: pass pointer-reuse=exact realloc=preserved large-unmap=48 rss-${rss_kind}=${rss_value}"
