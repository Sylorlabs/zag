#!/usr/bin/env bash
# Measure each native self-host stage inside a hard, low-priority cgroup.
#
# The expensive run is deliberately opt-in.  A normal invocation only proves
# that the safety controls are available; it never starts a compiler build.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$root/selfhost/native/znc.zag"
limit_bytes=${ZAG_SELFHOST_MEMORY_MAX_BYTES:-17179869184}
budget_kib=${ZAG_SELFHOST_MEMORY_BUDGET_KIB:-14680064}
timeout_sec=${ZAG_SELFHOST_TIMEOUT_SEC:-1800}
report=${ZAG_SELFHOST_MEMORY_REPORT:-"$root/.zig-cache/selfhost-memory.tsv"}

skip() {
    echo "native memory gate: SKIP: $*" >&2
    exit 77
}

command -v systemd-run >/dev/null 2>&1 || skip "systemd-run is unavailable"
command -v /usr/bin/time >/dev/null 2>&1 || skip "GNU time is unavailable"
systemctl --user is-system-running >/dev/null 2>&1 || skip "the user systemd manager is unavailable"

# earlyoom is a second line of defence for the interactive workstation.  This
# test never stops or reconfigures it.
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet earlyoom; then
    skip "earlyoom is not active; refusing a memory-intensive self-host run"
fi

probe_file=$(mktemp "${TMPDIR:-/tmp}/zag-memory-probe.XXXXXX")
if ! systemd-run --user --quiet --wait --collect \
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
printf 'stage\tpeak_rss_kib\tbudget_kib\tlimit_bytes\n' >"$report"

build_stage() {
    compiler=$1
    output=$2
    label=$3
    metric="$tmp/$label.metric"
    log="$tmp/$label.log"

    echo "native memory gate: running $label (hard limit $limit_bytes bytes)"
    if ! systemd-run --user --quiet --wait --collect \
        -p Type=exec -p "MemoryMax=$limit_bytes" -p MemorySwapMax=0 \
        -p CPUWeight=1 -p IOWeight=1 -p Nice=15 \
        -p "RuntimeMaxSec=$timeout_sec" \
        /usr/bin/time -f '%M' -o "$metric" \
        /usr/bin/env -i "PATH=$tmp/empty-path" "$compiler" "$source_file" \
        -o "$output" --no-analyze --no-zagd >"$log" 2>&1; then
        echo "native memory gate: FAIL: $label exceeded a safety bound or compilation failed" >&2
        sed -n '1,40p' "$log" >&2
        return 1
    fi
    peak=$(sed -n '1p' "$metric")
    case $peak in *[!0-9]*|'') echo "native memory gate: invalid RSS measurement for $label" >&2; return 1;; esac
    printf '%s\t%s\t%s\t%s\n' "$label" "$peak" "$budget_kib" "$limit_bytes" >>"$report"
    if [ "$peak" -gt "$budget_kib" ]; then
        echo "native memory gate: FAIL: $label peak ${peak} KiB exceeds budget ${budget_kib} KiB" >&2
        return 1
    fi
    echo "  ok  $label peak_rss_kib=$peak"
}

build_stage "$seed" "$tmp/znc-stage1" stage1
build_stage "$tmp/znc-stage1" "$tmp/znc-stage2" stage2
build_stage "$tmp/znc-stage2" "$tmp/znc-stage3" stage3

cmp -s "$tmp/znc-stage1" "$tmp/znc-stage2"
cmp -s "$tmp/znc-stage2" "$tmp/znc-stage3"
echo "native memory gate: PASS; report=$report"
