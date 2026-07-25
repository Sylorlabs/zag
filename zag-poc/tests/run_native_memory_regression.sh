#!/usr/bin/env bash
# Measure each native self-host stage inside a hard, low-priority cgroup.
#
# The expensive run is deliberately opt-in.  A normal invocation only proves
# that the safety controls are available; it never starts a compiler build.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$root/selfhost/native/znc.zag"
requested_limit_bytes=${ZAG_SELFHOST_MEMORY_MAX_BYTES:-17179869184}
requested_budget_kib=${ZAG_SELFHOST_MEMORY_BUDGET_KIB:-14680064}
swap_limit_bytes=${ZAG_SELFHOST_SWAP_MAX_BYTES:-0}
safety_percent=${ZAG_SELFHOST_PHYSICAL_MEMORY_PERCENT:-60}
reserve_bytes=${ZAG_SELFHOST_MEMORY_RESERVE_BYTES:-2147483648}
timeout_sec=${ZAG_SELFHOST_TIMEOUT_SEC:-1800}
report=${ZAG_SELFHOST_MEMORY_REPORT:-"$root/.zig-cache/selfhost-memory.tsv"}

skip() {
    echo "native memory gate: SKIP: $*" >&2
    exit 77
}

command -v systemd-run >/dev/null 2>&1 || skip "systemd-run is unavailable"
command -v /usr/bin/time >/dev/null 2>&1 || skip "GNU time is unavailable"
systemctl --user is-system-running >/dev/null 2>&1 || skip "the user systemd manager is unavailable"

# A cgroup cap at or above physical RAM does not protect an interactive
# workstation: global reclaim can kill unrelated applications before the
# compiler reaches that cap. Keep the requested 16 GiB ceiling for large CI
# hosts, but clamp the effective cap to a conservative share of this machine.
# This is intentionally fail-fast protection, not permission to consume the
# remaining memory or swap.
case $requested_limit_bytes in *[!0-9]*|'') skip "invalid ZAG_SELFHOST_MEMORY_MAX_BYTES";; esac
case $requested_budget_kib in *[!0-9]*|'') skip "invalid ZAG_SELFHOST_MEMORY_BUDGET_KIB";; esac
case $swap_limit_bytes in *[!0-9]*|'') skip "invalid ZAG_SELFHOST_SWAP_MAX_BYTES";; esac
case $safety_percent in *[!0-9]*|'') skip "invalid ZAG_SELFHOST_PHYSICAL_MEMORY_PERCENT";; esac
case $reserve_bytes in *[!0-9]*|'') skip "invalid ZAG_SELFHOST_MEMORY_RESERVE_BYTES";; esac
[ "$safety_percent" -ge 25 ] && [ "$safety_percent" -le 75 ] ||
    skip "ZAG_SELFHOST_PHYSICAL_MEMORY_PERCENT must be 25..75"
mem_total_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
mem_available_kib=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
case $mem_total_kib in *[!0-9]*|'') skip "could not read physical memory size";; esac
case $mem_available_kib in *[!0-9]*|'') skip "could not read available memory size";; esac
physical_bytes=$((mem_total_kib * 1024))
available_bytes=$((mem_available_kib * 1024))
safe_limit_bytes=$((physical_bytes * safety_percent / 100))
limit_bytes=$requested_limit_bytes
if [ "$limit_bytes" -gt "$safe_limit_bytes" ]; then
    limit_bytes=$safe_limit_bytes
fi
available_limit_bytes=$((available_bytes - reserve_bytes))
if [ "$available_limit_bytes" -lt 1073741824 ]; then
    skip "less than 1 GiB is available after preserving the workstation reserve"
fi
if [ "$limit_bytes" -gt "$available_limit_bytes" ]; then
    limit_bytes=$available_limit_bytes
fi
[ "$limit_bytes" -ge 1073741824 ] ||
    skip "effective compiler memory limit is below 1 GiB"
budget_kib=$requested_budget_kib
effective_limit_kib=$((limit_bytes / 1024))
effective_total_limit_kib=$(((limit_bytes + swap_limit_bytes) / 1024))
safe_budget_kib=$((effective_total_limit_kib * 9 / 10))
if [ "$budget_kib" -gt "$safe_budget_kib" ]; then
    budget_kib=$safe_budget_kib
fi
echo "native memory gate: requested_limit=$requested_limit_bytes effective_limit=$limit_bytes swap_limit=$swap_limit_bytes physical_percent=$safety_percent reserve_bytes=$reserve_bytes budget_kib=$budget_kib"

# earlyoom is a second line of defence for the interactive workstation.  This
# test never stops or reconfigures it.
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet earlyoom; then
    skip "earlyoom is not active; refusing a memory-intensive self-host run"
fi

probe_file=$(mktemp "${TMPDIR:-/tmp}/zag-memory-probe.XXXXXX")
if ! systemd-run --user --quiet --wait --collect --pipe \
    -p Type=exec -p MemoryMax=67108864 -p MemorySwapMax=0 \
    -p CPUWeight=1 -p IOWeight=1 -p Nice=15 \
    /usr/bin/time -f 'peak_rss_kib=%M' -o "$probe_file" /usr/bin/true; then
    unlink "$probe_file"
    skip "the user manager cannot enforce memory controls"
fi
grep -q '^peak_rss_kib=' "$probe_file" || { unlink "$probe_file"; skip "peak RSS measurement failed"; }
unlink "$probe_file"

if [ "${1:-}" = "--probe" ]; then
    echo "native memory gate: supported (no compiler was run)"
    exit 0
fi

if [ "${ZAG_RUN_HEAVY_MEMORY_GATE:-0}" != 1 ]; then
    echo "native memory gate: safety controls available; heavy run not requested"
    echo "set ZAG_RUN_HEAVY_MEMORY_GATE=1 to run three bounded self-host stages"
    exit 0
fi

case ${ZNC_SEED:-} in
    '') seed="$root/znc" ;;
    /*) seed=$ZNC_SEED ;;
    *) seed="$PWD/$ZNC_SEED" ;;
esac
[ -x "$seed" ] || { echo "native memory gate: seed is not executable: $seed" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-native-memory.XXXXXX")
trap 'find "$tmp" -type f -delete 2>/dev/null || true; rmdir "$tmp/empty-path" "$tmp" 2>/dev/null || true' EXIT HUP INT TERM
mkdir "$tmp/empty-path"
mkdir -p "$(dirname -- "$report")"
printf 'stage\tprocess_peak_rss_kib\tcgroup_memory_peak_bytes\tcgroup_swap_peak_bytes\tworking_set_peak_kib\tbudget_kib\tlimit_bytes\tswap_limit_bytes\trequested_limit_bytes\tphysical_percent\treserve_bytes\n' >"$report"

# The transient unit would normally disappear before the coordinator could
# inspect its accounting files. Keep this tiny wrapper alive after the compiler
# exits just long enough to record cgroup-v2 RAM and swap peaks from inside the
# unit. This makes bounded-swap evidence honest: process RSS alone would omit
# pages displaced to swap.
stage_runner="$tmp/stage-runner.sh"
cat >"$stage_runner" <<'EOF'
#!/bin/bash
set +e
compiler=$1
source_file=$2
output=$3
metric=$4
empty_path=$5
/usr/bin/time -f '%M' -o "$metric.process" \
    /usr/bin/env -i "PATH=$empty_path" "$compiler" "$source_file" \
    -o "$output" --no-analyze --no-zagd --no-foreground-cache
status=$?
cgroup_path=
while IFS=: read -r hierarchy controllers path; do
    if [ "$hierarchy" = 0 ]; then cgroup_path=$path; fi
done </proc/self/cgroup
memory_peak=0
swap_peak=0
if [ -n "$cgroup_path" ] && [ -r "/sys/fs/cgroup$cgroup_path/memory.peak" ]; then
    IFS= read -r memory_peak <"/sys/fs/cgroup$cgroup_path/memory.peak"
fi
if [ -n "$cgroup_path" ] && [ -r "/sys/fs/cgroup$cgroup_path/memory.swap.peak" ]; then
    IFS= read -r swap_peak <"/sys/fs/cgroup$cgroup_path/memory.swap.peak"
fi
printf '%s\n%s\n' "$memory_peak" "$swap_peak" >"$metric.cgroup"
exit "$status"
EOF
chmod +x "$stage_runner"

build_stage() {
    compiler=$1
    output=$2
    label=$3
    metric="$tmp/$label.metric"
    log="$tmp/$label.log"

    echo "native memory gate: running $label (hard limit $limit_bytes bytes)"
    if ! systemd-run --user --quiet --wait --collect --pipe \
        -p Type=exec -p "MemoryMax=$limit_bytes" \
        -p "MemorySwapMax=$swap_limit_bytes" \
        -p CPUWeight=1 -p IOWeight=1 -p Nice=15 \
        -p "RuntimeMaxSec=$timeout_sec" \
        "$stage_runner" "$compiler" "$source_file" "$output" "$metric" \
        "$tmp/empty-path" >"$log" 2>&1; then
        echo "native memory gate: FAIL: $label exceeded a safety bound or compilation failed" >&2
        sed -n '1,40p' "$log" >&2
        return 1
    fi
    peak=$(sed -n '1p' "$metric.process")
    memory_peak=$(sed -n '1p' "$metric.cgroup")
    swap_peak=$(sed -n '2p' "$metric.cgroup")
    case $peak in *[!0-9]*|'') echo "native memory gate: invalid RSS measurement for $label" >&2; return 1;; esac
    case $memory_peak in *[!0-9]*|'') echo "native memory gate: invalid cgroup RAM peak for $label" >&2; return 1;; esac
    case $swap_peak in *[!0-9]*|'') echo "native memory gate: invalid cgroup swap peak for $label" >&2; return 1;; esac
    working_set_peak_kib=$(((memory_peak + swap_peak + 1023) / 1024))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$peak" "$memory_peak" "$swap_peak" "$working_set_peak_kib" \
        "$budget_kib" "$limit_bytes" "$swap_limit_bytes" \
        "$requested_limit_bytes" "$safety_percent" "$reserve_bytes" >>"$report"
    if [ "$working_set_peak_kib" -gt "$budget_kib" ]; then
        echo "native memory gate: FAIL: $label RAM+swap peak ${working_set_peak_kib} KiB exceeds budget ${budget_kib} KiB" >&2
        return 1
    fi
    echo "  ok  $label process_peak_rss_kib=$peak cgroup_memory_peak_bytes=$memory_peak cgroup_swap_peak_bytes=$swap_peak working_set_peak_kib=$working_set_peak_kib"
}

build_stage "$seed" "$tmp/znc-stage1" stage1
build_stage "$tmp/znc-stage1" "$tmp/znc-stage2" stage2
build_stage "$tmp/znc-stage2" "$tmp/znc-stage3" stage3

cmp -s "$tmp/znc-stage1" "$tmp/znc-stage2"
cmp -s "$tmp/znc-stage2" "$tmp/znc-stage3"
echo "native memory gate: PASS; report=$report"
