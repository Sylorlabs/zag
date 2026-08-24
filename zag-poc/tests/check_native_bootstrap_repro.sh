#!/usr/bin/env bash
# Prove the native Zag compiler reaches a byte-identical self-hosting fixpoint.
#
# The compiler invocations run with an empty PATH, so no C compiler, assembler,
# linker, shell, or other host executable can be resolved by command lookup.
# The shell is used only to orchestrate and compare completed results.
set -eu
set -o pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$root/selfhost/native/znc.zag"
. "$root/tests/portable.sh"

selfhost_heartbeat=${ZAG_SELFHOST_HEARTBEAT_SECONDS:-30}
case "$selfhost_heartbeat" in
    ''|*[!0-9]*|0) echo "native bootstrap: invalid heartbeat interval: $selfhost_heartbeat" >&2; exit 1;;
esac
selfhost_stage_timeout=${ZAG_SELFHOST_STAGE_TIMEOUT_SECONDS:-3600}
case "$selfhost_stage_timeout" in
    ''|*[!0-9]*|0) echo "native bootstrap: invalid stage timeout: $selfhost_stage_timeout" >&2; exit 1;;
esac

host_system=$(uname -s)
host_machine=$(uname -m)
host_target_args=()
case "$host_system:$host_machine" in
    Darwin:arm64) host_platform=macos-arm64; host_target_args=(--target macos-arm64) ;;
    Linux:x86_64|Linux:amd64) host_platform=linux-x86_64 ;;
    Linux:aarch64|Linux:arm64) host_platform=linux-arm64; host_target_args=(--target arm64) ;;
    *) echo "native bootstrap: unsupported host: $host_system $host_machine" >&2; exit 1 ;;
esac
case "$host_platform" in
    linux-x86_64) current_compiler="$root/znc" ;;
    *) current_compiler="$root/znc-$host_platform" ;;
esac

case ${ZNC_SEED:-} in
    '') seed=$current_compiler ;;
    /*) seed=$ZNC_SEED ;;
    *) seed="$PWD/$ZNC_SEED" ;;
esac

cd "$root"

if [ ! -x "$seed" ]; then
    echo "native bootstrap: seed is not executable: $seed" >&2
    echo "native bootstrap: run bootstrap.sh first or set ZNC_SEED to the current fixed-point compiler" >&2
    exit 1
fi
if ! zag_assert_native_executable "$seed"; then
    echo "native bootstrap: compiler does not match exact host architecture: $seed" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-native-bootstrap.XXXXXX")
stage_pid=""
stage_pgid=""
cleanup() {
    if [ -n "$stage_pid" ]; then
        zag_terminate_process_tree "$stage_pid" "$stage_pgid"
        wait "$stage_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
signal_cleanup() {
    cleanup
    exit 130
}
trap cleanup EXIT
trap signal_cleanup HUP INT TERM
mkdir "$tmp/empty-path"

# A multi-generation comparison is meaningful only for one immutable source
# snapshot. The shared development checkout may be active while this expensive
# gate runs, so bind the proof to every Zag source path and byte under the
# compiler/runtime roots. A change fails explicitly instead of being reported
# as compiler nondeterminism.
source_fingerprint() {
    {
        find selfhost std -type f -name '*.zag' -print0
        printf '%s\0' zag.mod
    } | zag_sort_nul | while IFS= read -r -d '' source_path; do
        source_digest=$(zag_sha256_file "$source_path") || exit 1
        printf '%s\0%s\0' "$source_digest" "$source_path"
    done | zag_sha256_stream
}
source_snapshot=$(source_fingerprint)
echo "  source snapshot sha256=$source_snapshot"

assert_source_stable() {
    label=$1
    current=$(source_fingerprint)
    if [ "$current" != "$source_snapshot" ]; then
        echo "  XX  source tree changed during $label; reproducibility proof is invalid" >&2
        echo "      before=$source_snapshot" >&2
        echo "      after =$current" >&2
        exit 1
    fi
}

# Keep the independent fixpoint proof safe on an interactive Linux host too.
# This duplicates bootstrap.sh's optional OS envelope deliberately: the test
# runs with an empty compiler PATH and must not depend on the bootstrap script
# to perform any of its three generations.
guard_limit=${ZAG_SELFHOST_MEMORY_MAX_BYTES:-}
guard_swap=${ZAG_SELFHOST_SWAP_MAX_BYTES:-0}
guard_enabled=0
case "$guard_swap" in ''|*[!0-9]*) echo "native bootstrap: invalid swap guard" >&2; exit 1;; esac
if [ "$host_system" = Linux ] && command -v systemd-run >/dev/null 2>&1 &&
   systemctl --user is-system-running >/dev/null 2>&1; then
    if [ -z "$guard_limit" ]; then
        total_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
        available_kib=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        physical_limit=$((total_kib * 1024 * 60 / 100))
        available_limit=$(((available_kib - 2097152) * 1024))
        guard_limit=$physical_limit
        if [ "$guard_limit" -gt "$available_limit" ]; then guard_limit=$available_limit; fi
    fi
    case "$guard_limit" in ''|*[!0-9]*) echo "native bootstrap: invalid memory guard" >&2; exit 1;; esac
    if [ "$guard_limit" -lt 1073741824 ]; then
        echo "native bootstrap: refusing to run with less than 1 GiB after the workstation reserve" >&2
        exit 1
    fi
    guard_enabled=1
    echo "  memory guard: cgroup memory max=$guard_limit bytes, swap max=$guard_swap bytes"
elif [ -n "$guard_limit" ] || [ "$guard_swap" -ne 0 ]; then
    echo "native bootstrap: explicit memory or swap limit requires a user systemd manager" >&2
    exit 1
fi

run_stage_compiler() {
    compiler=$1
    output=$2
    if [ "$guard_enabled" -eq 1 ]; then
        systemd-run --user --quiet --wait --collect --pipe \
            -p Type=exec -p "WorkingDirectory=$root" \
            -p "MemoryMax=$guard_limit" -p "MemorySwapMax=$guard_swap" \
            -p CPUWeight=1 -p IOWeight=1 -p Nice=10 \
            /usr/bin/env -i "PATH=$tmp/empty-path" "$compiler" "$source_file" \
            -o "$output" "${host_target_args[@]}" \
            --no-analyze --no-zagd --no-foreground-cache
    else
        /usr/bin/env "PATH=$tmp/empty-path" "$compiler" "$source_file" -o "$output" \
            "${host_target_args[@]}" --no-analyze --no-zagd --no-foreground-cache
    fi
}

build_stage() {
    compiler=$1
    output=$2
    label=$3
    log="$tmp/$label.log"

    # Reproducibility is a code-generation property. Keep the advisory analyzer
    # and correctness-independent daemon out of the fixpoint measurement.
    zag_start_isolated run_stage_compiler "$compiler" "$output" >"$log" 2>&1
    stage_pid=$ZAG_ISOLATED_PID
    stage_pgid=$ZAG_ISOLATED_PGID
    stage_started=$SECONDS
    stage_next_heartbeat=$((stage_started + selfhost_heartbeat))
    stage_timed_out=0
    stage_process_running() {
        stage_state=$(ps -o stat= -p "$stage_pid" 2>/dev/null | awk 'NF { print $1; exit }')
        [ -n "$stage_state" ] && [ "${stage_state#Z}" = "$stage_state" ]
    }
    while stage_process_running; do
        sleep 1
        stage_elapsed=$((SECONDS - stage_started))
        if [ "$stage_elapsed" -ge "$selfhost_stage_timeout" ]; then
            echo "  XX  $label timed out after ${selfhost_stage_timeout}s" >&2
            zag_terminate_process_tree "$stage_pid" "$stage_pgid"
            stage_timed_out=1
            break
        fi
        if [ "$SECONDS" -ge "$stage_next_heartbeat" ] && stage_process_running; then
            stage_rss="unavailable"
            stage_rss_kib=$(ps -o rss= -p "$stage_pid" 2>/dev/null | awk 'NF { print $1; exit }')
            if [ -n "$stage_rss_kib" ]; then
                stage_rss="$stage_rss_kib KiB"
            fi
            echo "  progress $label: elapsed=${stage_elapsed}s rss=$stage_rss"
            stage_next_heartbeat=$((SECONDS + selfhost_heartbeat))
        fi
    done
    if wait "$stage_pid" && [ "$stage_timed_out" -eq 0 ]; then
        :
    else
        stage_pid=""
        stage_pgid=""
        echo "  XX  $label failed" >&2
        sed -n '1,40p' "$log" >&2
        exit 1
    fi
    stage_pid=""
    stage_pgid=""
    if [ ! -x "$output" ]; then
        echo "  XX  $label did not produce an executable" >&2
        exit 1
    fi
    echo "  ok  $label"
}

same_bytes() {
    left=$1
    right=$2
    label=$3

    if cmp -s "$left" "$right"; then
        echo "  ok  $label"
        return
    fi

    echo "  XX  $label" >&2
    left_digest=$(zag_sha256_file "$left") || exit 1
    right_digest=$(zag_sha256_file "$right") || exit 1
    echo "      $left_digest  $left" >&2
    echo "      $right_digest  $right" >&2
    exit 1
}

echo "── native bootstrap reproducibility (Zag → $host_platform, empty PATH) ──"
build_stage "$seed" "$tmp/znc-stage1" "seed builds stage 1"
assert_source_stable "stage 1"
build_stage "$tmp/znc-stage1" "$tmp/znc-stage2" "stage 1 builds stage 2"
assert_source_stable "stage 2"
build_stage "$tmp/znc-stage2" "$tmp/znc-stage3" "stage 2 builds stage 3"
assert_source_stable "stage 3"

same_bytes "$seed" "$tmp/znc-stage1" "input seed matches its source rebuild"
same_bytes "$tmp/znc-stage1" "$tmp/znc-stage2" "stage 1 equals stage 2 byte-for-byte"
same_bytes "$tmp/znc-stage2" "$tmp/znc-stage3" "stage 2 equals stage 3 byte-for-byte"

digest=$(zag_sha256_file "$tmp/znc-stage3")
echo "  sha256  $digest"
assert_source_stable "final report"
echo "  source snapshot unchanged sha256=$source_snapshot"
echo "════ native bootstrap reproducible: pass=6 fail=0 ════"
